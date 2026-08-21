# Builder for hookshot's "mark the management DM as an admin room" oneshot.
#
# Split out of hookshot.nix (like dm-provision.nix) so the VM check
# (parts/checks/hookshot) can drive the REAL script against a real homeserver
# without standing up sops, the GitHub App, or the bridge itself:
#
#   systemd.services."matrix-hookshot-adminroom" =
#     (import ./hookshot-adminroom.nix { inherit pkgs config; }) {
#       bot = "hookshot"; asTokenPath = …; bridgeService = "matrix-hookshot.service"; …
#     };
#
# It does two things, both by masquerading as the bridge bot with the appservice
# token, and both idempotent:
#
#   1. ADMIN-ROOM MARKER. Works around a conduwuit/tuwunel gap: the homeserver
#      doesn't stamp `is_direct` onto DM invite m.room.member events, so hookshot
#      never recognises the DM as an *admin room* — the only place `github login`
#      / `github notifications toggle` exist. Hookshot designates an admin room by
#      the bot's room account-data `uk.half-shot.matrix-hookshot.github.room`
#      carrying an admin_user (normally written from the is_direct invite,
#      Bridge.ts), so we write it ourselves and restart hookshot once so it loads
#      the room on startup (setUpAdminRoom).
#
#   2. NOTIFICATION STREAM POSITION. Works around upstream #965 — see the comment
#      on the seed below. Without it the personal-notification watcher can never
#      start, so `github login` + `notifications toggle` both "succeed" and
#      nothing ever arrives.
#
# Both markers live on the homeserver, so a `matrix-reset` wipes them with it and
# this unit re-applies them against the freshly provisioned DM.
{
  pkgs,
  config,
}:

{
  bot,
  # Human label for the room this instance manages (unit description only).
  label ? "management DM",
  # Whether THIS room carries the personal GitHub notification feed:
  #   true   assert it on   — the declarative equivalent of `github notifications toggle`
  #   false  assert it off  — so exactly one admin room owns the feed
  #   null   leave it alone — don't manage the toggle at all
  # Hookshot keys its watcher on userId:type, so two admin rooms with the feed on
  # means the last one loaded wins. Exactly one room should be `true`.
  notifications ? null,
  # Marker file holding the room id (written by whatever provisions the room).
  dmMarker,
  # Appservice as_token, loaded as a credential (never on the command line).
  asTokenPath,
  # Bridge unit to restart once, so it loads the room as an admin room.
  bridgeService,
  # DM provisioner unit; we can only mark a DM that exists.
  dmService,
  # Extra ordering. INVARIANT: every oneshot that restarts the bridge must be
  # chained after the previous one. They are all isDm, so `matrix-reset` starts the
  # whole set in ONE systemd transaction, and concurrent restarts of a unit the
  # transaction also orders on is the shape that deadlocks. The chain today is
  # adminroom -> notifications-adminroom -> github-token -> infra-alerts-room; a new
  # bridge-restarting unit belongs on the end of it.
  extraAfter ? [ ],
  stateDirectory ? "matrix-hookshot-adminroom",
}:
let
  g = config.services.matrix-tuwunel.settings.global;
  domain = g.server_name;
  homeserverUrl = "http://${builtins.head g.address}:${toString (builtins.head g.port)}";
  adminLocalpart = config.custom.profiles.matrix.adminLocalpart;

  # "" | "true" | "false" — see the `notifications` arg above.
  notificationsArg =
    if notifications == null then "" else (if notifications then "true" else "false");

  adminRoomType = "uk.half-shot.matrix-hookshot.github.room";
  notifStateType = "uk.half-shot.matrix-hookshot.github.notif_state";

  script = pkgs.writeShellScript "matrix-hookshot-adminroom" ''
    set -eu
    url="${homeserverUrl}"
    bot="@${bot}:${domain}"
    me="@${adminLocalpart}:${domain}"
    as_token="$(cat "$CREDENTIALS_DIRECTORY/as_token")"

    [ -s "${dmMarker}" ] || { echo "hookshot-adminroom: no DM marker yet, nothing to do"; exit 0; }
    rid="$(cat "${dmMarker}")"
    botenc="$(${pkgs.jq}/bin/jq -rn --arg b "$bot" '$b|@uri')"
    ridenc="$(${pkgs.jq}/bin/jq -rn --arg r "$rid" '$r|@uri')"
    auth=(-H "Authorization: Bearer $as_token")
    # Masquerade as the appservice bot for the account-data + membership reads.
    q="user_id=$botenc"

    for _ in $(seq 1 30); do
      ${pkgs.curl}/bin/curl -sf "$url/_matrix/client/versions" >/dev/null && break
      sleep 2
    done

    # The bot's room account-data only sticks once it has joined the DM.
    for _ in $(seq 1 30); do
      joined="$(${pkgs.curl}/bin/curl -s "''${auth[@]}" \
        "$url/_matrix/client/v3/rooms/$ridenc/joined_members?$q" \
        | ${pkgs.jq}/bin/jq -r --arg b "$bot" '.joined // {} | has($b)' 2>/dev/null || echo false)"
      [ "$joined" = "true" ] && break
      sleep 2
    done

    # Reconcile the admin-room account data with what we declare. Read-modify-write
    # so hookshot's own keys (github.notifications.participating, …) survive, and
    # so `notifications` can assert the toggle that `github notifications toggle`
    # would otherwise set by hand — the account data is the only thing that command
    # writes, so writing it here is the same act, minus the typing.
    changed=0
    cur="$(${pkgs.curl}/bin/curl -s "''${auth[@]}" \
      "$url/_matrix/client/v3/user/$botenc/rooms/$ridenc/account_data/${adminRoomType}?$q" \
      | ${pkgs.jq}/bin/jq -c 'if type == "object" and has("errcode") then {} else . end' 2>/dev/null || echo "{}")"
    [ -n "$cur" ] || cur="{}"
    want="$(${pkgs.jq}/bin/jq -nc --argjson c "$cur" --arg u "$me" --arg n "${notificationsArg}" '
      ($c + {admin_user: $u})
      | if $n == "" then . else .github.notifications.enabled = ($n == "true") end
    ')"
    if [ "$(${pkgs.jq}/bin/jq -Sc . <<<"$cur")" != "$(${pkgs.jq}/bin/jq -Sc . <<<"$want")" ]; then
      ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
        "$url/_matrix/client/v3/user/$botenc/rooms/$ridenc/account_data/${adminRoomType}?$q" \
        -H 'content-type: application/json' -d "$want" >/dev/null
      changed=1
      echo "hookshot-adminroom: wrote admin-room state for $rid -> $want"
    fi

    # Seed hookshot's notification stream position — upstream #965. `github
    # notifications toggle` hands UserNotificationWatcher.addUser a `since` read
    # from this account data, which defaults to 0 on a room that has never polled.
    # addUser then does `data.since || existing?.since`, so that legitimate 0 reads
    # as absent and it throws "`since` value missing from data payload". Only the
    # watcher itself ever writes notif_state, so it can never start: a deadlock
    # that survives every restart (and every matrix-reset, which wipes this with
    # the homeserver). Seed it with "now" in ms when unset — which is also the
    # position we want, i.e. notifications from here on, not the whole backlog.
    #
    # Deliberately BEFORE the restart-once bookkeeping below: a room that is
    # already "activated" still needs the seed, so an existing deployment heals on
    # its next run instead of only after the next matrix-reset.
    cursince="$(${pkgs.curl}/bin/curl -s "''${auth[@]}" \
      "$url/_matrix/client/v3/user/$botenc/rooms/$ridenc/account_data/${notifStateType}?$q" \
      | ${pkgs.jq}/bin/jq -r '.since // 0' 2>/dev/null || echo 0)"
    case "$cursince" in
      "" | *[!0-9]*) cursince=0 ;;
    esac
    if [ "$cursince" -eq 0 ]; then
      if ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
        "$url/_matrix/client/v3/user/$botenc/rooms/$ridenc/account_data/${notifStateType}?$q" \
        -H 'content-type: application/json' \
        -d "$(${pkgs.jq}/bin/jq -nc --argjson s "$(date +%s)000" '{since:$s}')" >/dev/null; then
        changed=1
        echo "hookshot-adminroom: seeded notif-since for $rid"
      else
        echo "hookshot-adminroom: failed to seed notif-since (non-fatal)" >&2
      fi
    else
      echo "hookshot-adminroom: notif-since already at $cursince for $rid"
    fi

    # Hookshot only *loads* an admin room from this account-data on startup (the
    # is_direct invite path is what tuwunel breaks), so the marker existing isn't
    # enough — hookshot must have (re)started since it was set. Restart once per
    # room id, tracked in our (persisted) state, so a marker set after hookshot's
    # last start still takes effect, without restarting on every boot/deploy.
    # ...and equally, anything we *did* write this run only takes effect after a
    # restart: hookshot reads this account data at startup, and an external PUT is
    # invisible to a running bridge (only its own bot-command path emits in-process).
    act="$STATE_DIRECTORY/activated"
    if [ "$changed" -eq 0 ] && [ "$(cat "$act" 2>/dev/null || true)" = "$rid" ]; then
      echo "hookshot-adminroom: $rid already active as an admin room"
      exit 0
    fi
    echo "hookshot-adminroom: restarting hookshot to load admin room $rid"
    ${pkgs.systemd}/bin/systemctl restart ${bridgeService}
    printf '%s' "$rid" > "$act"
  '';
in
{
  description = "Mark the @${bot} ${label} as a hookshot admin room";
  after = [
    bridgeService
    dmService
  ]
  ++ extraAfter;
  wants = [
    bridgeService
    dmService
  ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    # Records the room id we've restarted the bridge for, so we restart only when
    # the admin room is new — survives reboots (persisted by the caller).
    StateDirectory = stateDirectory;
    StateDirectoryMode = "0700";
    LoadCredential = [ "as_token:${asTokenPath}" ];
    ExecStart = script;
  };
}

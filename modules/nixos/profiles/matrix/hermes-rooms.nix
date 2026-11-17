# The hermes bot's Matrix account and the per-job rooms an agent job delivers into
# (palimpsest ADR-0041; property#2).
#
# WHAT THIS IS FOR. An agent job's output is only half a channel: the other half is
# being able to ANSWER it — "what's the service charge on the Nunhead one?" — which
# means the job has to land somewhere hermes is listening, not on a dashboard page
# someone has to go and look at. That needs three things the fleet did not have: an
# account for the bot, a room per job, and the bot joined to both that room and to
# #infra-alerts (where its failures go).
#
# WHY A REGULAR ACCOUNT AND NOT AN APPSERVICE. hermes is a Matrix CLIENT — it syncs,
# it reads replies, it holds a session. It is not a bridge and has no registration to
# install. So it registers like the admin does (registration-token UIA flow, exactly
# `registerAdmin` in default.nix) and logs in with a password from sops. rk1b holds
# the same password and the adapter logs in with it there; nothing has to carry an
# access token between the two hosts.
#
# WHY THIS UNIT JOINS THE BOT ITSELF, rather than leaving it to hermes's auto-join.
# The gateway does accept invites from authorized users, but that makes "is the
# channel working?" depend on the gateway being up, its allowlist being right, and a
# sync having happened — three ways for a deploy to go green over a room the bot is
# not in. The password is right here, so the join is done synchronously and FAILS THE
# UNIT if it does not take.
#
# NO POWER-LEVEL PROMOTION, unlike infra-alerts.nix. That one promotes @hookshot
# because the bridge writes its connection as a STATE event (state_default 50). hermes
# only ever sends m.room.message, which events_default puts at 0 — the level an
# invited member already joins at. The promotion PUT is also the one call a room
# version can reject (v12 forbids naming the creator in `users`), so not needing it is
# worth saying out loud.
#
# ⚠ ROOM IDS ARE NOT IN THIS REPO, AND DELIBERATELY. A room id is minted by the
# homeserver and dies with a `matrix-reset`; an ALIAS cannot stand in for it, because
# the hermes Matrix adapter never resolves one (it hands the string straight to
# `send_message_event(RoomID(chat_id))`, i.e. `PUT /rooms/{id}/send/...`, which takes
# an id only). So the id is persisted in this unit's StateDirectory, which is the
# source of truth, and a job is pointed at it with
# `hermes cron update <id> --deliver matrix:<room id>` — jobs live in jobs.json and
# are imperative anyway (docs/agents/agent-jobs.md). Pinning the id as a sops value
# would bake a build-time constant that a reset silently invalidates: the exact
# failure infra-alerts.nix was refactored away from.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.matrix.hermesRooms;

  domain = config.services.matrix-tuwunel.settings.global.server_name;
  adminLocalpart = config.custom.profiles.matrix.adminLocalpart;
  homeserverUrl = "http://${builtins.head config.services.matrix-tuwunel.settings.global.address}:${toString (builtins.head config.services.matrix-tuwunel.settings.global.port)}";

  stateDir = "matrix-hermes-rooms";

  # Room name/topic are OPTIONS and must never reach the shell as interpolated text:
  # a topic containing backticks or $(...) would be executed as root at deploy time
  # (hookshot-notifications-room.nix learned this the hard way). The whole room table
  # is built as JSON in Nix and read back with jq.
  roomsJson = builtins.toJSON (
    lib.mapAttrsToList (key: r: {
      inherit key;
      inherit (r) name topic;
    }) cfg.rooms
  );

  # The rooms this module does not create but the bot must still be in — #infra-alerts
  # above all, which is where --failure-deliver points. Their ids arrive in files
  # written by whichever unit owns them.
  joinFilesJson = builtins.toJSON cfg.joinRoomIdFiles;

  bot = "@${cfg.botLocalpart}:${domain}";

  script = pkgs.writeShellScript "matrix-hermes-rooms" ''
    set -eu
    url="${homeserverUrl}"
    bot="${bot}"
    me="@${adminLocalpart}:${domain}"
    pass="$(cat "$CREDENTIALS_DIRECTORY/admin_password")"
    botpass="$(cat "$CREDENTIALS_DIRECTORY/hermes_password")"
    regtoken="$(cat "$CREDENTIALS_DIRECTORY/registration_token")"
    curl() { ${pkgs.curl}/bin/curl -s "$@"; }
    jq() { ${pkgs.jq}/bin/jq "$@"; }
    meenc="$(jq -rn --arg m "$me" '$m|@uri')"

    for _ in $(seq 1 30); do
      curl -f "$url/_matrix/client/versions" >/dev/null && break
      sleep 2
    done

    # ── 1. The account, idempotently ──────────────────────────────────────────────
    # Same two-step UIA flow as tuwunel-register-admin: an existing account answers
    # M_USER_IN_USE with no session, which is the idempotence.
    session="$(curl -X POST "$url/_matrix/client/v3/register" -H 'content-type: application/json' \
      -d "$(jq -nc --arg u "${cfg.botLocalpart}" --arg p "$botpass" \
        '{username:$u,password:$p,inhibit_login:true}')" \
      | jq -r '.session // empty')"
    if [ -z "$session" ]; then
      echo "hermes-rooms: account ${cfg.botLocalpart} already exists"
    else
      code="$(curl -o /dev/null -w '%{http_code}' -X POST "$url/_matrix/client/v3/register" \
        -H 'content-type: application/json' \
        -d "$(jq -nc --arg u "${cfg.botLocalpart}" --arg p "$botpass" --arg t "$regtoken" --arg s "$session" \
          '{username:$u,password:$p,inhibit_login:true,auth:{type:"m.login.registration_token",token:$t,session:$s}}')")"
      [ "$code" = "200" ] || { echo "hermes-rooms: registering ${cfg.botLocalpart} -> HTTP $code" >&2; exit 1; }
      echo "hermes-rooms: registered $bot"
    fi

    # ── 2. Two logins: the admin creates rooms, the bot joins them ────────────────
    # Rooms are created via admin password-login because the appservice `?user_id=`
    # masquerade cannot createRoom on tuwunel (see infra-alerts.nix) — and we have no
    # appservice here anyway. Replies are kept so a failure can show the homeserver's
    # errcode, and printed only when there is no access_token.
    resp="$(curl -X POST "$url/_matrix/client/v3/login" -H 'content-type: application/json' \
      -d "$(jq -nc --arg u "${adminLocalpart}" --arg p "$pass" \
        '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')")"
    at="$(jq -r '.access_token // empty' <<<"$resp" 2>/dev/null || true)"
    [ -n "$at" ] || { echo "hermes-rooms: admin login failed: $resp" >&2; exit 1; }
    auth=(-H "Authorization: Bearer $at")

    # device_id is PINNED. Without it every deploy mints a fresh device on the bot
    # account, and a list of forty "rk1b" devices is both noise and, once E2EE is on,
    # forty unverified sessions to chase.
    resp="$(curl -X POST "$url/_matrix/client/v3/login" -H 'content-type: application/json' \
      -d "$(jq -nc --arg u "${cfg.botLocalpart}" --arg p "$botpass" \
        '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p,device_id:"room-provisioner"}')")"
    bat="$(jq -r '.access_token // empty' <<<"$resp" 2>/dev/null || true)"
    [ -n "$bat" ] || { echo "hermes-rooms: bot login failed: $resp" >&2; exit 1; }
    botauth=(-H "Authorization: Bearer $bat")

    # Cosmetic, best-effort, and idempotent enough: a bare @hermes reads as a ghost.
    curl -f -o /dev/null "''${botauth[@]}" -X PUT "$url/_matrix/client/v3/profile/$(jq -rn --arg b "$bot" '$b|@uri')/displayname" \
      -H 'content-type: application/json' \
      -d "$(jq -nc --arg n ${lib.escapeShellArg cfg.botDisplayName} '{displayname:$n}')" \
      || echo "hermes-rooms: display name not set (non-fatal)" >&2

    # A room id is only usable if the homeserver still HAS the room. A marker outlives
    # the room it names — that is precisely what a matrix-reset leaves behind — and
    # trusting one blindly is how #infra-alerts spent four weeks posting into a 404.
    room_exists() {
      [ -n "$1" ] || return 1
      curl -o /dev/null -w '%{http_code}' "''${auth[@]}" \
        "$url/_matrix/client/v3/rooms/$(jq -rn --arg r "$1" '$r|@uri')/joined_members" \
        | grep -qx 200
    }

    # Invite (admin) then join (bot), then VERIFY. Both calls are best-effort on their
    # own — an invite 403s when already sent — but a bot that is not in the room cannot
    # be delivered to at all, so the membership is what gets asserted.
    ensure_joined() { # room-id ridenc
      ismember="$(curl "''${auth[@]}" "$url/_matrix/client/v3/rooms/$2/joined_members" \
        | jq -r --arg b "$bot" '(.joined // {}) | has($b)' 2>/dev/null || echo false)"
      if [ "$ismember" != "true" ]; then
        curl "''${auth[@]}" -X POST "$url/_matrix/client/v3/rooms/$2/invite" \
          -H 'content-type: application/json' -d "$(jq -nc --arg b "$bot" '{user_id:$b}')" >/dev/null || true
        curl "''${botauth[@]}" -X POST "$url/_matrix/client/v3/join/$2" \
          -H 'content-type: application/json' -d '{}' >/dev/null || true
        ismember="$(curl "''${auth[@]}" "$url/_matrix/client/v3/rooms/$2/joined_members" \
          | jq -r --arg b "$bot" '(.joined // {}) | has($b)' 2>/dev/null || echo false)"
        [ "$ismember" = "true" ] || { echo "hermes-rooms: $bot is not a member of $1" >&2; exit 1; }
        echo "hermes-rooms: $bot joined $1"
      fi
    }

    # ── 3. One room per declared job ──────────────────────────────────────────────
    rooms=${lib.escapeShellArg roomsJson}
    n="$(jq 'length' <<<"$rooms")"
    i=0
    while [ "$i" -lt "$n" ]; do
      key="$(jq -r ".[$i].key" <<<"$rooms")"
      name="$(jq -r ".[$i].name" <<<"$rooms")"
      topic="$(jq -r ".[$i].topic" <<<"$rooms")"
      i=$((i + 1))
      marker="$STATE_DIRECTORY/$key.room-id"

      rid=""
      if [ -s "$marker" ] && room_exists "$(cat "$marker")"; then
        rid="$(cat "$marker")"
      elif [ -s "$marker" ]; then
        echo "hermes-rooms: the recorded room for $key is gone (wiped homeserver?) — creating a new one"
      fi

      if [ -z "$rid" ]; then
        # No power_level_content_override: from room version 12 the creator holds
        # implicit infinite power and MUST NOT appear in `users`, which gets the whole
        # createRoom rejected with M_INVALID_PARAM. Nothing here needs it anyway — see
        # the header.
        resp="$(curl "''${auth[@]}" -X POST "$url/_matrix/client/v3/createRoom" \
          -H 'content-type: application/json' \
          -d "$(jq -nc --arg b "$bot" --arg n "$name" --arg t "$topic" \
            '{name:$n,topic:$t,preset:"private_chat",invite:[$b]}')")"
        rid="$(jq -r '.room_id // empty' <<<"$resp" 2>/dev/null || true)"
        [ -n "$rid" ] || { echo "hermes-rooms: createRoom for $key failed: $resp" >&2; exit 1; }
        printf '%s' "$rid" > "$marker"; chmod 644 "$marker"
        echo "hermes-rooms: created $key -> $rid"
      fi
      ridenc="$(jq -rn --arg r "$rid" '$r|@uri')"

      ensure_joined "$rid" "$ridenc"

      # Keep name + topic current on an EXISTING room too, so an edited option lands on
      # deploy rather than only at creation. Plain room state, idempotent PUTs.
      curl -f "''${auth[@]}" -X PUT "$url/_matrix/client/v3/rooms/$ridenc/state/m.room.name" \
        -H 'content-type: application/json' -d "$(jq -nc --arg n "$name" '{name:$n}')" >/dev/null \
        || echo "hermes-rooms: name update failed for $key (non-fatal)" >&2
      curl -f "''${auth[@]}" -X PUT "$url/_matrix/client/v3/rooms/$ridenc/state/m.room.topic" \
        -H 'content-type: application/json' -d "$(jq -nc --arg t "$topic" '{topic:$t}')" >/dev/null \
        || echo "hermes-rooms: topic update failed for $key (non-fatal)" >&2

      # Favourite it for the operator, same as the management DMs. Idempotent.
      curl -f "''${auth[@]}" -X PUT \
        "$url/_matrix/client/v3/user/$meenc/rooms/$ridenc/tags/m.favourite" \
        -H 'content-type: application/json' -d '{"order":0.05}' >/dev/null || true

      echo "hermes-rooms: $key ready in $rid"
    done

    # ── 4. Rooms owned elsewhere (#infra-alerts) ──────────────────────────────────
    # Their unit may not have run yet on a fresh homeserver, so a missing or dead id is
    # a warning rather than a failure: the next start picks it up. What is NOT tolerated
    # is a readable id that the bot then fails to join — ensure_joined exits on that.
    files=${lib.escapeShellArg joinFilesJson}
    n="$(jq 'length' <<<"$files")"
    i=0
    while [ "$i" -lt "$n" ]; do
      f="$(jq -r ".[$i]" <<<"$files")"
      i=$((i + 1))
      [ -s "$f" ] || { echo "hermes-rooms: $f not written yet — skipping" >&2; continue; }
      rid="$(cat "$f")"
      if ! room_exists "$rid"; then
        echo "hermes-rooms: $f names a room the homeserver does not have — skipping" >&2
        continue
      fi
      ensure_joined "$rid" "$(jq -rn --arg r "$rid" '$r|@uri')"
    done
  '';
in
{
  options.custom.profiles.matrix.hermesRooms = {
    enable = lib.mkEnableOption ''
      the hermes bot's Matrix account and the per-job rooms an agent job delivers
      into (ADR-0041). The account is registered with the shared registration token
      and its password is the sops secret `hermes_bot_password`, which rk1b reads
      from the same file to log the gateway in
    '';

    botLocalpart = lib.mkOption {
      type = lib.types.str;
      default = "hermes";
      description = "Localpart of the agent's Matrix account.";
    };

    botDisplayName = lib.mkOption {
      type = lib.types.str;
      default = "Hermes";
      description = "Display name set on the bot account (best-effort, re-applied each start).";
    };

    rooms = lib.mkOption {
      default = { };
      description = ''
        One room per agent job, keyed by the job's name. The key is also the marker
        filename, so `rooms.property-watch` records its id in
        `/var/lib/${stateDir}/property-watch.room-id` — which is where you read the id
        to point a job at it with `hermes cron update <id> --deliver matrix:<room id>`.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Room name.";
            };
            topic = lib.mkOption {
              type = lib.types.str;
              description = "Room topic.";
            };
          };
        }
      );
    };

    joinRoomIdFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/var/lib/matrix-infra-alerts/room-id" ];
      description = ''
        Files holding ids of rooms this module does NOT create but the bot must be in
        — #infra-alerts above all, which is where a job's `--failure-deliver` points.
        A file that is missing, or that names a room the homeserver no longer has, is
        skipped with a warning; an id that is readable and live must join or the unit
        fails.
      '';
    };

    roomIdDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/${stateDir}";
      readOnly = true;
      description = "Directory holding the server-assigned room ids, one `<job>.room-id` per room.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.matrix-hermes-rooms = {
      description = "Ensure the hermes bot account and its per-job rooms exist";
      # Not start-rate-limited: see the rationale on the shared admin-room constructor
      # in hookshot-adminroom.nix. An idempotent oneshot that `matrix-reset` restarts
      # alongside the rest of the family must not be refused for restarting "too often".
      startLimitIntervalSec = 0;

      # After register-admin so `grant_admin_to_first_user` has already landed on the
      # operator's account rather than on this bot.
      after = [
        "tuwunel.service"
        "tuwunel-register-admin.service"
      ];
      requires = [ "tuwunel.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # 0755: the ids are not secret and an operator reads them to point a job at a
        # room (`cat /var/lib/${stateDir}/<job>.room-id`).
        StateDirectory = stateDir;
        StateDirectoryMode = "0755";
        LoadCredential = [
          "admin_password:${config.sops.secrets.matrix_admin_password.path}"
          "registration_token:${config.sops.secrets.registration_token.path}"
          "hermes_password:${config.sops.secrets.hermes_bot_password.path}"
        ];
        ExecStart = script;
      };
    };

    # Contribute to `matrix-reset`: the rooms live on the homeserver, so their id
    # markers must be wiped with it — otherwise a job would keep delivering to a room
    # the wipe deleted. isDm so it runs in the post-bridge phase.
    custom.profiles.matrix.resetState = [
      {
        service = "matrix-hermes-rooms.service";
        isDm = true;
        paths = [ "/var/lib/${stateDir}" ];
        postResetNote = "re-point the hermes cron jobs: hermes cron update <job> --deliver matrix:<new room id> (ids are in /var/lib/${stateDir})";
      }
    ];

    # Explicit owner/mode: impermanence otherwise guesses root:root 0755 (and says so,
    # loudly, on first deploy), and systemd will NOT then tighten an already-mounted
    # directory to its StateDirectoryMode.
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = "/var/lib/${stateDir}";
          user = "root";
          group = "root";
          mode = "0755";
        }
      ];
    };
  };
}

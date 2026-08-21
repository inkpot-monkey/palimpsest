# A dedicated room for the personal GitHub notification feed, instead of the
# @hookshot management DM.
#
# Hookshot has no "post notifications to room X" setting: the feed always lands in
# the admin room where it was enabled (`onAdminRoomSettingsChanged` pushes
# `roomId: adminRoom.roomId`). But an "admin room" is just a room whose bot room
# account-data `uk.half-shot.matrix-hookshot.github.room` names an admin_user —
# and on tuwunel that marker is already the ONLY way a room becomes one, since the
# homeserver never stamps `is_direct` (see hookshot-adminroom.nix). So pointing
# that same marker at a named room is all "a different room" takes.
#
# This provisions the room; hookshot-adminroom.nix then marks it, seeds its
# notification stream position, and asserts the feed ON here (and OFF in the DM,
# so exactly one admin room owns the single per-user watcher). What stays manual
# is `github login` — per-user OAuth, irreducibly interactive.
#
# Unlike #infra-alerts (ADR-0019) this needs no two-phase roomId pinning: nothing
# is emitted into hookshot's build-time config, so the server-assigned id can just
# be persisted in the unit's StateDirectory and read back on later runs.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.matrix.hookshot.notificationsRoom;
  hookshotCfg = config.custom.profiles.matrix.hookshot;

  domain = config.services.matrix-tuwunel.settings.global.server_name;
  adminLocalpart = config.custom.profiles.matrix.adminLocalpart;
  homeserverUrl = "http://${builtins.head config.services.matrix-tuwunel.settings.global.address}:${toString (builtins.head config.services.matrix-tuwunel.settings.global.port)}";

  stateDir = "matrix-hookshot-notifications-room";

  # Room name/topic are OPTIONS, so they must never reach the shell as interpolated
  # text: a topic containing backticks or $(...) would otherwise be executed as root
  # at deploy time (it was — the default topic's `github login` ran as a command and
  # emptied itself). Build the createRoom body as JSON in Nix and hand it to jq via
  # --argjson, and escapeShellArg everything else, exactly as dm-provision.nix does.
  createExtra = builtins.toJSON { inherit (cfg) name topic; };

  # Create the room (once), keep @hookshot joined, and favourite it. Rooms are
  # created via admin password-login: the appservice `?user_id=` masquerade can't
  # createRoom on tuwunel (see infra-alerts.nix), so the operator's own account
  # creates it and is therefore already joined — no invite to accept.
  #
  # No notify push-rule here, unlike #infra-alerts: that one exists because
  # hookshot posts generic-webhook payloads as m.notice, which the default
  # .m.rule.suppress_notices override silences. GitHub notifications go out as
  # m.text (NotificationsProcessor), so ordinary room notification settings apply.
  roomScript = pkgs.writeShellScript "matrix-hookshot-notifications-room" ''
    set -eu
    url="${homeserverUrl}"
    bot="@hookshot:${domain}"
    me="@${adminLocalpart}:${domain}"
    marker="$STATE_DIRECTORY/room-id"
    pass="$(cat "$CREDENTIALS_DIRECTORY/admin_password")"
    astoken="$(cat "$CREDENTIALS_DIRECTORY/as_token")"
    curl() { ${pkgs.curl}/bin/curl -s "$@"; }
    jq() { ${pkgs.jq}/bin/jq "$@"; }
    uid="$(jq -rn --arg u "$bot" '$u|@uri')"
    meenc="$(jq -rn --arg m "$me" '$m|@uri')"

    for _ in $(seq 1 30); do
      curl -f "$url/_matrix/client/versions" >/dev/null && break
      sleep 2
    done

    at="$(curl -X POST "$url/_matrix/client/v3/login" -H 'content-type: application/json' \
      -d "$(jq -nc --arg u "${adminLocalpart}" --arg p "$pass" \
        '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')" \
      | jq -r '.access_token // empty')"
    [ -n "$at" ] || { echo "hookshot-notifications-room: admin login failed" >&2; exit 1; }
    auth=(-H "Authorization: Bearer $at")

    if [ -s "$marker" ]; then
      rid="$(cat "$marker")"
    else
      rid="$(curl "''${auth[@]}" -X POST "$url/_matrix/client/v3/createRoom" \
        -H 'content-type: application/json' \
        -d "$(jq -nc --arg b "$bot" --argjson extra ${lib.escapeShellArg createExtra} \
          '$extra + {preset:"private_chat",invite:[$b]}')" \
        | jq -r '.room_id // empty')"
      [ -n "$rid" ] || { echo "hookshot-notifications-room: createRoom failed" >&2; exit 1; }
      printf '%s' "$rid" > "$marker"
      chmod 644 "$marker"
      echo "hookshot-notifications-room: created room -> $rid"
    fi
    ridenc="$(jq -rn --arg r "$rid" '$r|@uri')"

    # Ensure @hookshot is a joined member: invite (as admin) then join (appservice
    # token). Marking a room as an admin room only sticks once the bot is in it.
    ismember="$(curl "''${auth[@]}" "$url/_matrix/client/v3/rooms/$ridenc/joined_members" \
      | jq -r --arg b "$bot" '(.joined // {}) | has($b)' 2>/dev/null || echo false)"
    if [ "$ismember" != "true" ]; then
      curl "''${auth[@]}" -X POST "$url/_matrix/client/v3/rooms/$ridenc/invite" \
        -H 'content-type: application/json' -d "$(jq -nc --arg b "$bot" '{user_id:$b}')" >/dev/null || true
      curl -H "Authorization: Bearer $astoken" \
        -X POST "$url/_matrix/client/v3/rooms/$ridenc/join?user_id=$uid" >/dev/null || true
      echo "hookshot-notifications-room: @hookshot invited + joined $rid"
    fi

    # Keep name + topic current on an EXISTING room too, so an edited option lands
    # on deploy rather than only at creation — and so a room created by an earlier,
    # broken render of this script heals itself. Plain room state, idempotent PUTs.
    curl -f "''${auth[@]}" -X PUT \
      "$url/_matrix/client/v3/rooms/$ridenc/state/m.room.name" \
      -H 'content-type: application/json' \
      -d "$(jq -nc --arg n ${lib.escapeShellArg cfg.name} '{name:$n}')" >/dev/null \
      && echo "hookshot-notifications-room: name ensured" \
      || echo "hookshot-notifications-room: name update failed (non-fatal)" >&2
    curl -f "''${auth[@]}" -X PUT \
      "$url/_matrix/client/v3/rooms/$ridenc/state/m.room.topic" \
      -H 'content-type: application/json' \
      -d "$(jq -nc --arg t ${lib.escapeShellArg cfg.topic} '{topic:$t}')" >/dev/null \
      && echo "hookshot-notifications-room: topic ensured" \
      || echo "hookshot-notifications-room: topic update failed (non-fatal)" >&2

    # Favourite it, same as the management DMs (dm-provision.nix). Idempotent.
    curl -f "''${auth[@]}" -X PUT \
      "$url/_matrix/client/v3/user/$meenc/rooms/$ridenc/tags/m.favourite" \
      -H 'content-type: application/json' -d '{"order":0.05}' >/dev/null || true

    echo "hookshot-notifications-room: ready in $rid"
  '';
in
{
  options.custom.profiles.matrix.hookshot.notificationsRoom = {
    enable = lib.mkEnableOption ''
      a dedicated room for the personal GitHub notification feed instead of the
      @hookshot management DM. The room is created, marked as a hookshot admin
      room and has the feed asserted ON; the DM keeps its admin-room powers
      (`help`, `github login`, `feed …`) with the feed asserted OFF, so exactly
      one room owns the single per-user notification watcher. `github login` stays
      manual — it is per-user OAuth
    '';

    name = lib.mkOption {
      type = lib.types.str;
      default = "GitHub Notifications";
      description = "Room name.";
    };

    topic = lib.mkOption {
      type = lib.types.str;
      default = "Your GitHub notification feed, bridged by hookshot. Run `github login` in the Hookshot admin DM if it goes quiet.";
      description = "Room topic.";
    };

    roomIdFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/${stateDir}/room-id";
      readOnly = true;
      description = ''
        File holding the server-assigned room id, written by the room oneshot and
        read by the admin-room oneshot that marks it.
      '';
    };
  };

  config = lib.mkIf (hookshotCfg.enable && cfg.enable) {
    assertions = [
      {
        assertion = hookshotCfg.enable;
        message = "custom.profiles.matrix.hookshot.notificationsRoom.enable requires custom.profiles.matrix.hookshot.enable.";
      }
    ];

    systemd.services.matrix-hookshot-notifications-room = {
      description = "Ensure the GitHub notifications room exists and @hookshot has joined";
      after = [
        "tuwunel.service"
        "tuwunel-register-admin.service"
      ];
      requires = [ "tuwunel.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # 0755 so the Hookshot Space oneshot (a DynamicUser) can read room-id.
        StateDirectory = stateDir;
        StateDirectoryMode = "0755";
        LoadCredential = [
          "admin_password:${config.sops.secrets.matrix_admin_password.path}"
          "as_token:${config.sops.secrets.hookshot_as_token.path}"
        ];
        ExecStart = roomScript;
      };
    };

    # Contribute to `matrix-reset`: the room lives on the homeserver, so its id
    # marker must be wiped with it or we'd point at a room that no longer exists.
    custom.profiles.matrix.resetState = [
      {
        service = "matrix-hookshot-notifications-room.service";
        isDm = true;
        paths = [ "/var/lib/${stateDir}" ];
      }
    ];

    # Same persistence lifetime as the homeserver + the DM markers.
    # Declared explicitly rather than as a bare path: impermanence otherwise creates
    # the source dir with a guessed root:root 0755 (it says so, loudly, on first
    # deploy) and systemd will NOT then tighten an already-mounted directory to its
    # StateDirectoryMode. 0755 is what this one wants anyway — the Hookshot Space
    # oneshot is a DynamicUser and has to read room-id out of it.
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

# #infra-alerts room + a hookshot generic-webhook connection for fleet uptime
# alerts (ADR-0019).
#
# The room is created via admin password-login: the `?user_id=` appservice
# masquerade cannot createRoom on tuwunel. The bot is invited as admin and joins
# with the appservice token.
#
# The connection is DYNAMIC, not static, so nothing needs the roomId at build
# time and the room survives a `matrix-reset` on its own. A static connection is
# the only kind that lets us choose the hookId — but only because there
# `stateKey == hookId`, and a dynamic connection reaches the same place: hookshot
# resolves a dynamic hook's id from a `hookId -> stateKey` map in the bot's room
# account data (GenericHook.js: getHookId), so writing that map ourselves with our
# own hookId makes `…/webhook/<hookId>` just as deterministic. Same trick the
# retired aionui provisioner used (ADR-0017). We keep `stateKey == hookId` so the
# room state is byte-identical to what the static connection produced, which is
# what lets an existing room be adopted with no state churn and no window where
# hookshot sees a hook it cannot resolve.
#
# Order matters when writing: the account-data map FIRST, then the state event.
# Hookshot loads the state event and immediately looks up its hookId; with no map
# yet and the state written by one of its own users it throws outright rather than
# minting one ("Refusing to generate a hookId as it's owned by us").
#
{
  config,
  lib,
  pkgs,
  self,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.matrix.infraAlerts;
  hookshotCfg = config.custom.profiles.matrix.hookshot;

  domain = config.services.matrix-tuwunel.settings.global.server_name;
  adminLocalpart = config.custom.profiles.matrix.adminLocalpart;
  matrixSecrets = self.lib.getSecretFile "matrix";
  user = "matrix-hookshot";
  webhookPort = settings.services.public.hookshot.port;

  homeserverUrl = "http://${builtins.head config.services.matrix-tuwunel.settings.global.address}:${toString (builtins.head config.services.matrix-tuwunel.settings.global.port)}";

  connectionType = "uk.half-shot.matrix-hookshot.generic.hook";
  connectionName = "infra-alerts";

  # Ensure the room exists, @hookshot has JOINED it (a connection only activates
  # for a room the bot is in), and the generic-hook connection is present — then
  # restart hookshot once so it loads it. Runs as root to allow that restart,
  # mirroring matrix-hookshot-adminroom.
  #
  # The room id lives in a persisted marker, not in config: that is what lets a
  # matrix-reset wipe it and this unit recreate the room, instead of leaving a
  # build-time pin aimed at a room the wipe deleted.
  roomScript = pkgs.writeShellScript "matrix-infra-alerts-room" ''
    set -eu
    url="${homeserverUrl}"
    bot="@hookshot:${domain}"
    adopt="${cfg.roomId}"
    marker="$STATE_DIRECTORY/room-id"
    pass="$(cat "$CREDENTIALS_DIRECTORY/admin_password")"
    astoken="$(cat "$CREDENTIALS_DIRECTORY/as_token")"
    hookid="$(cat "$CREDENTIALS_DIRECTORY/hook_id")"
    curl() { ${pkgs.curl}/bin/curl -s "$@"; }
    jq() { ${pkgs.jq}/bin/jq "$@"; }
    uid="$(jq -rn --arg u "$bot" '$u|@uri')"
    asauth=(-H "Authorization: Bearer $astoken")

    for _ in $(seq 1 30); do
      curl -f "$url/_matrix/client/versions" >/dev/null && break
      sleep 2
    done

    at="$(curl -X POST "$url/_matrix/client/v3/login" -H 'content-type: application/json' \
      -d "$(jq -nc --arg u "${adminLocalpart}" --arg p "$pass" \
        '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')" \
      | jq -r '.access_token // empty')"
    [ -n "$at" ] || { echo "infra-alerts: admin login failed" >&2; exit 1; }
    auth=(-H "Authorization: Bearer $at")

    # Marker first, then the legacy pin (adopted once, so an existing room keeps
    # its history), then create.
    # A room id is only usable if the homeserver still has the room. Both the
    # marker and the legacy pin can outlive the room they name — that is exactly
    # what a matrix-reset does — and the old code trusted the pin blindly, so
    # alerts posted into a room that no longer existed and every `|| true` here
    # reported success. Validate, then fall through to creating a fresh one.
    room_exists() {
      [ -n "$1" ] || return 1
      curl -o /dev/null -w '%{http_code}' "''${auth[@]}" \
        "$url/_matrix/client/v3/rooms/$(jq -rn --arg r "$1" '$r|@uri')/joined_members" \
        | grep -qx 200
    }

    rid=""
    if [ -s "$marker" ] && room_exists "$(cat "$marker")"; then
      rid="$(cat "$marker")"
    elif [ -n "$adopt" ] && room_exists "$adopt"; then
      rid="$adopt"
      printf '%s' "$rid" > "$marker"; chmod 644 "$marker"
      echo "infra-alerts: adopted pre-existing room $rid — infraAlerts.roomId can now be dropped"
    fi

    if [ -z "$rid" ]; then
      if [ -s "$marker" ]; then
        echo "infra-alerts: the recorded room is gone (wiped homeserver?) — creating a new one"
      fi
      rid="$(curl "''${auth[@]}" -X POST "$url/_matrix/client/v3/createRoom" \
        -H 'content-type: application/json' \
        -d "$(jq -nc --arg b "$bot" \
          '{name:"Infra Alerts",topic:"Fleet uptime alerts (ADR-0019)",preset:"private_chat",invite:[$b]}')" \
        | jq -r '.room_id // empty')"
      [ -n "$rid" ] || { echo "infra-alerts: createRoom failed" >&2; exit 1; }
      printf '%s' "$rid" > "$marker"; chmod 644 "$marker"
      echo "infra-alerts: created room $rid"
    fi
    ridenc="$(jq -rn --arg r "$rid" '$r|@uri')"
    changed=0

    # Ensure @hookshot is a joined member: invite (admin, idempotent) then join
    # (appservice token).
    ismember="$(curl "''${auth[@]}" "$url/_matrix/client/v3/rooms/$ridenc/joined_members" \
      | jq -r --arg b "$bot" '(.joined // {}) | has($b)' 2>/dev/null || echo false)"
    if [ "$ismember" != "true" ]; then
      curl "''${auth[@]}" -X POST "$url/_matrix/client/v3/rooms/$ridenc/invite" \
        -H 'content-type: application/json' -d "$(jq -nc --arg b "$bot" '{user_id:$b}')" >/dev/null || true
      curl -H "Authorization: Bearer $astoken" \
        -X POST "$url/_matrix/client/v3/rooms/$ridenc/join?user_id=$uid" >/dev/null || true
      echo "infra-alerts: @hookshot invited + joined $rid"
      changed=1
    fi

    # 1. The hookId -> stateKey map, in the BOT's room account data. Written before
    #    the state event: hookshot resolves a dynamic hook's id from this map the
    #    moment it sees the state, and finding no entry for state one of its own
    #    users wrote, it throws rather than minting an id. Merged, not replaced, so
    #    any other generic hook in this room survives.
    curdata="$(curl "''${asauth[@]}" \
      "$url/_matrix/client/v3/user/$uid/rooms/$ridenc/account_data/${connectionType}?user_id=$uid" \
      | jq -c 'if type == "object" and has("errcode") then {} else . end' 2>/dev/null || echo "{}")"
    [ -n "$curdata" ] || curdata="{}"
    want="$(jq -nc --argjson c "$curdata" --arg h "$hookid" '$c + {($h): $h}')"
    if [ "$(jq -Sc . <<<"$curdata")" != "$(jq -Sc . <<<"$want")" ]; then
      curl -f "''${asauth[@]}" -X PUT \
        "$url/_matrix/client/v3/user/$uid/rooms/$ridenc/account_data/${connectionType}?user_id=$uid" \
        -H 'content-type: application/json' -d "$want" >/dev/null
      echo "infra-alerts: wrote the hookId map"
      changed=1
    fi

    # 2. The connection itself. stateKey == hookId, exactly as the static form
    #    produced, so adopting a room needs no state churn.
    curstate="$(curl "''${asauth[@]}" \
      "$url/_matrix/client/v3/rooms/$ridenc/state/${connectionType}/$hookid?user_id=$uid" \
      | jq -r '.name // empty' 2>/dev/null || echo "")"
    if [ "$curstate" != "${connectionName}" ]; then
      curl -f "''${asauth[@]}" -X PUT \
        "$url/_matrix/client/v3/rooms/$ridenc/state/${connectionType}/$hookid?user_id=$uid" \
        -H 'content-type: application/json' \
        -d "$(jq -nc --arg n "${connectionName}" '{name:$n}')" >/dev/null
      echo "infra-alerts: wrote the generic-hook connection"
      changed=1
    fi

    # Hookshot loads connections at startup, so anything written above only takes
    # effect after a restart. Restart at most once per room id.
    act="$STATE_DIRECTORY/restarted-for"
    if [ "$changed" -eq 1 ] || [ "$(cat "$act" 2>/dev/null || true)" != "$rid" ]; then
      ${pkgs.systemd}/bin/systemctl restart matrix-hookshot.service
      printf '%s' "$rid" > "$act"
      echo "infra-alerts: restarted hookshot to load the connection"
    fi

    # Make alerts NOTIFY (not just appear). Hookshot posts as m.notice, which
    # Matrix's default .m.rule.suppress_notices override rule silences — and that
    # outranks any per-room "all messages" setting. A *user-defined* override rule
    # outranks the server defaults, so add one that notifies-with-sound for this
    # room. We act on the admin account, which is the operator's own Element
    # account (adminLocalpart), so this sets the operator's push preference.
    # Idempotent PUT; declarative equivalent of toggling it by hand in a client.
    curl "''${auth[@]}" -X PUT \
      "$url/_matrix/client/v3/pushrules/global/override/infra-alerts-notify" \
      -H 'content-type: application/json' \
      -d "$(jq -nc --arg r "$rid" \
        '{conditions:[{kind:"event_match",key:"room_id",pattern:$r}],actions:["notify",{set_tweak:"sound",value:"default"}]}')" \
      >/dev/null && echo "infra-alerts: notify push-rule ensured" \
      || echo "infra-alerts: push-rule PUT failed (alerts will render but not notify)" >&2

    # Publish the loopback webhook URL for the on-host (kelpy) unit-state check.
    printf '%s' "http://127.0.0.1:${toString webhookPort}/webhook/$hookid" \
      > "$STATE_DIRECTORY/webhook_url"
    chmod 644 "$STATE_DIRECTORY/webhook_url"
    echo "infra-alerts: ready in $rid"
  '';
in
{
  options.custom.profiles.matrix.infraAlerts = {
    enable = lib.mkEnableOption ''
      the #infra-alerts room + a static hookshot generic-webhook connection for
      fleet uptime alerts (ADR-0019). Requires custom.profiles.matrix.hookshot.enable.
      The webhook id is the sops secret `infra_alerts_hook_id`, shared with the
      hosts that post (the kelpy unit-state check and the rk1b Gatus probe).
    '';

    roomId = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "!abcdef:palebluebytes.space";
      description = ''
        ADOPTION ONLY. Leave "" — the room is created on first run and its id
        persisted in `roomIdFile`, which is the source of truth. Set this once to
        take over a room created before the connection became dynamic (it is
        copied into the marker and then never read again). It is no longer needed
        at build time, so a `matrix-reset` no longer strands a pinned id pointing
        at a room the wipe deleted.
      '';
    };

    roomIdFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/matrix-infra-alerts/room-id";
      readOnly = true;
      description = ''
        File holding the server-assigned room id. Written by the room oneshot and
        read by the Hookshot Space oneshot, which files this room under the Space.
      '';
    };

    webhookUrlFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/matrix-infra-alerts/webhook_url";
      readOnly = true;
      description = "File holding the loopback webhook URL (written by the room oneshot).";
    };

    publicWebhookBase = lib.mkOption {
      type = lib.types.str;
      default = "https://hookshot.${settings.primaryDomain}/webhook";
      readOnly = true;
      description = "Public webhook base; off-host posters append /<hookId>.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = hookshotCfg.enable;
        message = "custom.profiles.matrix.infraAlerts.enable requires custom.profiles.matrix.hookshot.enable.";
      }
    ];

    # Shared webhook id (= stateKey of the static connection; also used by the
    # kelpy unit-state check + the rk1b Gatus probe). owner = hookshot so the
    # sops placeholder resolves in hookshot's config template.
    sops.secrets.infra_alerts_hook_id = {
      sopsFile = matrixSecrets;
      owner = user;
    };

    # Runs as root (no User=) so it can restart hookshot, mirroring
    # matrix-hookshot-adminroom. after+wants (not before/requires): it restarts
    # hookshot, so it must be ordered after it, not before.
    systemd.services.matrix-infra-alerts-room = {
      description = "Ensure #infra-alerts exists + @hookshot joined; load the webhook";
      # Ordered after every other oneshot that restarts the bridge. All of them are
      # isDm, so `matrix-reset` starts the whole set in ONE systemd transaction, and
      # concurrent restarts of a unit the transaction also orders on is the shape
      # that deadlocks — it would hang the reset with no obvious culprit.
      after = [
        "matrix-hookshot.service"
        "tuwunel.service"
        "tuwunel-register-admin.service"
        "matrix-hookshot-adminroom.service"
      ]
      ++ lib.optional hookshotCfg.notificationsRoom.enable "matrix-hookshot-notifications-adminroom.service"
      ++ lib.optional hookshotCfg.personalToken.enable "matrix-hookshot-github-token.service";
      wants = [ "matrix-hookshot.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "matrix-infra-alerts";
        StateDirectoryMode = "0755";
        LoadCredential = [
          "admin_password:${config.sops.secrets.matrix_admin_password.path}"
          "as_token:${config.sops.secrets.hookshot_as_token.path}"
          "hook_id:${config.sops.secrets.infra_alerts_hook_id.path}"
        ];
        ExecStart = roomScript;
      };
    };

    # Contribute to `matrix-reset`. Without this the room went with the homeserver
    # while its id stayed pinned in config, so alerts posted into a room that no
    # longer existed — and every curl here being `|| true` meant the oneshot still
    # reported success. isDm so it runs in the post-bridge phase, after the bridge
    # is back up to receive the invite.
    custom.profiles.matrix.resetState = [
      {
        service = "matrix-infra-alerts-room.service";
        isDm = true;
        paths = [ "/var/lib/matrix-infra-alerts" ];
      }
    ];

    # Explicit owner/mode: impermanence otherwise guesses root:root 0755 (and says
    # so on first deploy), and systemd will not tighten an already-mounted dir. 0755
    # is what this one wants anyway — the Space oneshot is a DynamicUser and has to
    # read room-id out of it.
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = "/var/lib/matrix-infra-alerts";
          user = "root";
          group = "root";
          mode = "0755";
        }
      ];
    };
  };
}

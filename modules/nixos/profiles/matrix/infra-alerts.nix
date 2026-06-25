# #infra-alerts room + a STATIC hookshot generic-webhook connection for fleet
# uptime alerts (ADR-0026).
#
# Why static (not the dynamic bot-command / masquerade path): only a *static*
# connection in hookshot's config.yml lets us choose the hookId — there
# `stateKey == hookId`, so the webhook URL is deterministic and equals our shared
# sops secret `infra_alerts_hook_id`. A dynamic connection makes hookshot mint its
# own UUID (stored in the bot's account-data), which we'd then have to discover.
# (Research: matrix-hookshot docs / GenericHook.ts — the `?user_id=` appservice
# masquerade also doesn't work for createRoom on tuwunel, which is why the room is
# created via admin password-login, mirroring the working hookshot Space oneshot.)
#
# Bootstrap is two-phase, because a static connection needs the server-assigned
# roomId (stable once created):
#   1. Deploy with roomId = "" → the room oneshot creates #infra-alerts and logs
#      its id (also written to $STATE_DIRECTORY/room-id).
#   2. Pin that id into `custom.profiles.matrix.infraAlerts.roomId` and redeploy →
#      hookshot.nix emits the static connection and serves /webhook/<hookId>.
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

  # Create/reuse the #infra-alerts room as the admin (password-login — the proven
  # path; the appservice masquerade can't createRoom on tuwunel), invite @hookshot,
  # persist + log the roomId for pinning, and publish the loopback webhook URL the
  # on-host unit-state check reads.
  roomScript = pkgs.writeShellScript "matrix-infra-alerts-room" ''
    set -eu
    url="${homeserverUrl}"
    bot="@hookshot:${domain}"
    marker="$STATE_DIRECTORY/room-id"
    pass="$(cat "$CREDENTIALS_DIRECTORY/admin_password")"
    hookid="$(cat "$CREDENTIALS_DIRECTORY/hook_id")"
    curl() { ${pkgs.curl}/bin/curl -s "$@"; }
    jq() { ${pkgs.jq}/bin/jq "$@"; }

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

    if [ -s "$marker" ]; then
      rid="$(cat "$marker")"
    else
      rid="$(curl "''${auth[@]}" -X POST "$url/_matrix/client/v3/createRoom" \
        -H 'content-type: application/json' \
        -d "$(jq -nc --arg b "$bot" \
          '{name:"Infra Alerts",topic:"Fleet uptime alerts (ADR-0026)",preset:"private_chat",invite:[$b]}')" \
        | jq -r '.room_id // empty')"
      [ -n "$rid" ] || { echo "infra-alerts: createRoom failed" >&2; exit 1; }
      printf '%s' "$rid" > "$marker"
      echo "infra-alerts: created room $rid"
    fi

    # Publish the loopback webhook URL for the on-host (kelpy) unit-state check.
    printf '%s' "http://127.0.0.1:${toString webhookPort}/webhook/$hookid" \
      > "$STATE_DIRECTORY/webhook_url"
    chmod 640 "$STATE_DIRECTORY/webhook_url"

    echo "infra-alerts: room id = $rid"
    echo "infra-alerts: pin it into custom.profiles.matrix.infraAlerts.roomId, then redeploy."
  '';
in
{
  options.custom.profiles.matrix.infraAlerts = {
    enable = lib.mkEnableOption ''
      the #infra-alerts room + a static hookshot generic-webhook connection for
      fleet uptime alerts (ADR-0026). Requires custom.profiles.matrix.hookshot.enable.
      The webhook id is the sops secret `infra_alerts_hook_id`, shared with the
      hosts that post (the kelpy unit-state check and the rk1b Gatus probe).
    '';

    roomId = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "!abcdef:palebluebytes.space";
      description = ''
        The #infra-alerts room id. Leave "" on first deploy; the room oneshot
        creates the room and logs its id. Pin that id here and redeploy to emit
        the static hookshot connection (it is needed at config-build time).
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

    systemd.services.matrix-infra-alerts-room = {
      description = "Create the #infra-alerts room for hookshot uptime alerts";
      after = [
        "tuwunel.service"
        "tuwunel-register-admin.service"
      ];
      requires = [ "tuwunel.service" ];
      wantedBy = [ "multi-user.target" ];
      before = [ "matrix-hookshot.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        Group = user;
        StateDirectory = "matrix-infra-alerts";
        StateDirectoryMode = "0750";
        LoadCredential = [
          "admin_password:${config.sops.secrets.matrix_admin_password.path}"
          "hook_id:${config.sops.secrets.infra_alerts_hook_id.path}"
        ];
        ExecStart = roomScript;
      };
    };
  };
}

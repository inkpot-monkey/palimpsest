# Declarative provisioning of the #infra-alerts room + a hookshot generic-webhook
# connection for fleet uptime alerts (ADR-0026). Modelled on the (removed) aionui
# provisioner [a5dc437] and the hookshot Space oneshot.
#
# The difference from the aionui case: this webhook is consumed CROSS-HOST — the
# on-host unit-state check on kelpy AND the Gatus probe on rk1b both post to it —
# so the hookId is a SHARED sops secret (`infra_alerts_hook_id`) both hosts derive
# the URL from, rather than a kelpy-local self-generated file. kelpy posts to the
# loopback listener; rk1b posts to the public Caddy URL.
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

  homeserverUrl = "http://${builtins.head config.services.matrix-tuwunel.settings.global.address}:${toString (builtins.head config.services.matrix-tuwunel.settings.global.port)}";
  webhookPort = settings.services.public.hookshot.port;

  # Connection account-data / state type hookshot uses for generic webhooks.
  hookType = "uk.half-shot.matrix-hookshot.generic.hook";

  provisionScript = pkgs.writeShellScript "matrix-infra-alerts-provision" ''
    set -eu
    url="${homeserverUrl}"
    dom="${domain}"
    bot="@hookshot:$dom"
    invite="@${adminLocalpart}:$dom"
    as_token="$(cat "$CREDENTIALS_DIRECTORY/as_token")"
    hookid="$(cat "$CREDENTIALS_DIRECTORY/hook_id")"
    uid="$(${pkgs.jq}/bin/jq -rn --arg u "$bot" '$u|@uri')"
    curl() { ${pkgs.curl}/bin/curl -s -H "Authorization: Bearer $as_token" "$@"; }
    jq() { ${pkgs.jq}/bin/jq "$@"; }

    # Wait for the homeserver C-S API.
    for _ in $(seq 1 30); do
      curl -f "$url/_matrix/client/versions" >/dev/null && break
      sleep 2
    done

    # Resolve the alerts room alias, creating it (as the bot) if absent. Idempotent.
    aliasenc="$(jq -rn --arg a "#infra-alerts:$dom" '$a|@uri')"
    rid="$(curl "$url/_matrix/client/v3/directory/room/$aliasenc" | jq -r '.room_id // empty')"
    if [ -z "$rid" ]; then
      rid="$(curl -X POST "$url/_matrix/client/v3/createRoom?user_id=$uid" \
        -H 'content-type: application/json' \
        -d "$(jq -nc --arg inv "$invite" \
          '{room_alias_name:"infra-alerts",name:"Infra Alerts",topic:"Fleet uptime alerts (ADR-0026)",preset:"private_chat",invite:[$inv]}')" \
        | jq -r '.room_id // empty')"
    fi
    [ -n "$rid" ] || { echo "could not resolve/create #infra-alerts" >&2; exit 1; }
    ridenc="$(jq -rn --arg r "$rid" '$r|@uri')"

    # Pre-seed the hookId in the bot's room account-data (merge, don't clobber
    # other hooks), THEN write the connection state event so hookshot looks the
    # id up rather than minting its own — this is what makes the URL deterministic.
    existing="$(curl "$url/_matrix/client/v3/user/$uid/rooms/$ridenc/account_data/${hookType}")"
    merged="$(printf '%s' "$existing" | jq -c --arg h "$hookid" \
      '(if type=="object" then . else {} end) + {($h):"infra-alerts"}')"
    curl -f -X PUT "$url/_matrix/client/v3/user/$uid/rooms/$ridenc/account_data/${hookType}" \
      -H 'content-type: application/json' -d "$merged" >/dev/null
    curl -f -X PUT "$url/_matrix/client/v3/rooms/$ridenc/state/${hookType}/infra-alerts?user_id=$uid" \
      -H 'content-type: application/json' -d '{"name":"infra-alerts"}' >/dev/null

    # Publish the loopback webhook URL for the on-host (kelpy) unit-state check.
    printf '%s' "http://127.0.0.1:${toString webhookPort}/webhook/$hookid" \
      > "$STATE_DIRECTORY/webhook_url"
    chmod 640 "$STATE_DIRECTORY/webhook_url"
    echo "infra-alerts hookshot connection provisioned in $rid"
  '';
in
{
  options.custom.profiles.matrix.infraAlerts = {
    enable = lib.mkEnableOption ''
      the #infra-alerts room + hookshot generic-webhook connection for fleet
      uptime alerts (ADR-0026). Requires custom.profiles.matrix.hookshot.enable.
      The webhook id is the sops secret `infra_alerts_hook_id`, shared with the
      hosts that post (the kelpy unit-state check and the rk1b Gatus probe)
    '';

    # Loopback URL the on-host (kelpy) unit-state check posts to. The file is
    # written by the provisioner; this is the path consumers read.
    webhookUrlFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/matrix-infra-alerts/webhook_url";
      readOnly = true;
      description = "File holding the loopback webhook URL (written by the provisioner).";
    };

    # Public webhook base for OFF-host posters (rk1b Gatus): they append the
    # secret hookId (read from the shared sops secret) at runtime.
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
        message = "custom.profiles.matrix.infraAlerts.enable requires custom.profiles.matrix.hookshot.enable (it provisions a hookshot connection).";
      }
    ];

    sops.secrets.infra_alerts_hook_id = {
      sopsFile = matrixSecrets;
      owner = user;
    };

    systemd.services.matrix-infra-alerts-provision = {
      description = "Provision the #infra-alerts matrix-hookshot generic-webhook connection";
      after = [
        "matrix-hookshot.service"
        "tuwunel.service"
        "tuwunel-register-admin.service"
      ];
      requires = [ "matrix-hookshot.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        Group = user;
        StateDirectory = "matrix-infra-alerts";
        StateDirectoryMode = "0750";
        LoadCredential = [
          "as_token:${config.sops.secrets.hookshot_as_token.path}"
          "hook_id:${config.sops.secrets.infra_alerts_hook_id.path}"
        ];
        ExecStart = provisionScript;
      };
    };
  };
}

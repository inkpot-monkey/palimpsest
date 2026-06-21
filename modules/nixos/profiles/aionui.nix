{
  config,
  lib,
  inputs,
  settings,
  pkgs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.aionui;
  claude-code = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;

  # The local homeserver's name (see modules/nixos/profiles/matrix: server_name).
  matrixServer = "matrix.${config.networking.domain}";
  matrixPort = settings.services.public.matrix.port;
  hookshotWebhookPort = settings.services.public.hookshot.port;
  notifierStateDir = "/var/lib/aionui-notifier";

  # Declaratively register the aionui alerts room + a hookshot generic-webhook
  # connection, so the notifier needs no manual `webhook` bot command. We act as
  # the hookshot appservice bot (as_token): ensure the room exists, then write
  # the connection. A generic hook's webhook id is OUR choice when we pre-seed
  # the bot's room account-data hookId mapping (mirrors how hookshot stores it),
  # so the URL is deterministic; we persist the id and publish the URL for the
  # notifier to read. Idempotent and re-runnable. See ADR-0024.
  provisionScript = pkgs.writeShellScript "aionui-hookshot-provision" ''
    set -eu
    url="http://127.0.0.1:${toString matrixPort}"
    dom="${matrixServer}"
    bot="@hookshot:$dom"
    invite="@${config.custom.profiles.matrix.adminLocalpart}:$dom"
    adtype="uk.half-shot.matrix-hookshot.generic.hook"
    as_token="$(cat "$CREDENTIALS_DIRECTORY/hookshot_as_token")"
    uid="$(${pkgs.jq}/bin/jq -rn --arg u "$bot" '$u|@uri')"
    curl() { ${pkgs.curl}/bin/curl -s -H "Authorization: Bearer $as_token" "$@"; }
    jq() { ${pkgs.jq}/bin/jq "$@"; }

    for _ in $(seq 1 30); do
      curl -f "$url/_matrix/client/versions" >/dev/null && break
      sleep 2
    done

    # Stable, secret hookId (the webhook URL is a capability) — persisted.
    hidfile="${notifierStateDir}/hookshot_hook_id"
    if [ -s "$hidfile" ]; then
      hookid="$(cat "$hidfile")"
    else
      hookid="$(cat /proc/sys/kernel/random/uuid)"
      printf '%s' "$hookid" > "$hidfile"
      chmod 600 "$hidfile"
    fi

    # Resolve the alerts room alias, creating it (as the bot) if absent.
    aliasenc="$(jq -rn --arg a "#aionui-alerts:$dom" '$a|@uri')"
    rid="$(curl "$url/_matrix/client/v3/directory/room/$aliasenc" | jq -r '.room_id // empty')"
    if [ -z "$rid" ]; then
      rid="$(curl -X POST "$url/_matrix/client/v3/createRoom?user_id=$uid" \
        -H 'content-type: application/json' \
        -d "$(jq -nc --arg inv "$invite" \
          '{room_alias_name:"aionui-alerts",name:"AionUi alerts",preset:"private_chat",invite:[$inv]}')" \
        | jq -r '.room_id // empty')"
    fi
    [ -n "$rid" ] || { echo "could not resolve/create the alerts room" >&2; exit 1; }
    ridenc="$(jq -rn --arg r "$rid" '$r|@uri')"

    # Pre-seed the hookId in the bot's room account data (merge, don't clobber
    # any other hooks), THEN write the connection state event so hookshot looks
    # the id up rather than minting its own.
    existing="$(curl "$url/_matrix/client/v3/user/$uid/rooms/$ridenc/account_data/$adtype")"
    merged="$(printf '%s' "$existing" | jq -c --arg h "$hookid" \
      '(if type=="object" then . else {} end) + {($h):"aionui"}')"
    curl -f -X PUT "$url/_matrix/client/v3/user/$uid/rooms/$ridenc/account_data/$adtype" \
      -H 'content-type: application/json' -d "$merged" >/dev/null
    curl -f -X PUT "$url/_matrix/client/v3/rooms/$ridenc/state/$adtype/aionui?user_id=$uid" \
      -H 'content-type: application/json' -d '{"name":"aionui"}' >/dev/null

    # Publish the webhook URL for the notifier (loopback to the webhooks listener).
    printf '%s' "http://127.0.0.1:${toString hookshotWebhookPort}/webhook/$hookid" \
      > "${notifierStateDir}/hookshot_webhook_url"
    chmod 640 "${notifierStateDir}/hookshot_webhook_url"
    echo "aionui hookshot connection provisioned in $rid"
  '';
in
{
  options.custom.profiles.aionui = {
    enable = lib.mkEnableOption "AionUi WebUI server (phone-accessible Claude Code frontend)";

    notifications = {
      enable = lib.mkEnableOption ''
        AionUi -> Matrix notifier. Posts agent events through a matrix-hookshot
        generic webhook — hookshot owns the Matrix side. Fully declarative: a
        provisioning service creates the #aionui-alerts room and the hookshot
        connection (no manual `webhook` bot command), so no extra secret is
        needed. Requires custom.profiles.matrix.hookshot.enable.
      '';
    };
  };

  imports = [
    self.nixosModules.aionui
    self.nixosModules.aionui-notifier
  ];

  config = lib.mkIf cfg.enable {
    services.aionui = {
      enable = true;
      package = pkgs.aionui;
      inherit (settings.services.private.aionui) port;

      # Run as the interactive user so AionUi reuses its `claude login`
      # credentials (~/.claude) and can work inside ~/code project checkouts.
      user = "inkpotmonkey";
      group = "users"; # inkpotmonkey's primary group (no per-user group exists)
      createUser = false;

      # Make the agent CLIs + their tooling discoverable to the backend.
      agentPackages = [
        claude-code
        pkgs.git
        pkgs.gh # so the agent can `gh pr create`
        pkgs.nodejs
      ];

      # Authenticate `gh` (and thus `gh pr create`) headlessly with the same token
      # git uses for HTTPS push. The raw github_token secret isn't KEY=VALUE, so
      # it's rendered to an env file via the sops template defined below.
      environmentFile = config.sops.templates."aionui-gh-env".path;
    };

    # GH_TOKEN for the agent's `gh`, rendered from the system github_token secret
    # (declared in modules/nixos/profiles/nixConfig.nix from profiles/github.yaml).
    sops.templates."aionui-gh-env" = {
      content = "GH_TOKEN=${config.sops.placeholder.github_token}\n";
      owner = config.services.aionui.user;
      inherit (config.services.aionui) group;
    };

    # Matrix notifier (opt-in). Fully declarative via hookshot: the provisioning
    # oneshot (below) reuses the hookshot appservice as_token to create the room
    # + connection and writes the webhook URL the notifier reads. No notifier
    # secret of its own.
    assertions = [
      {
        assertion = cfg.notifications.enable -> config.custom.profiles.matrix.hookshot.enable;
        message = "custom.profiles.aionui.notifications.enable requires custom.profiles.matrix.hookshot.enable (it provisions a hookshot connection).";
      }
    ];

    systemd.services.aionui-hookshot-provision = lib.mkIf cfg.notifications.enable {
      description = "Provision the aionui matrix-hookshot generic-webhook connection";
      after = [
        "matrix-hookshot.service"
        "tuwunel.service"
        "tuwunel-register-admin.service"
      ];
      requires = [ "matrix-hookshot.service" ];
      wantedBy = [ "multi-user.target" ];
      # Best-effort ordering: the notifier idles until the URL file appears, so a
      # transient provisioning failure doesn't block it (no requires both ways).
      before = [ "aionui-notifier.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = config.services.aionui-notifier.user;
        Group = config.services.aionui-notifier.group;
        StateDirectory = "aionui-notifier";
        StateDirectoryMode = "0750";
        LoadCredential = [ "hookshot_as_token:${config.sops.secrets.hookshot_as_token.path}" ];
        ExecStart = provisionScript;
      };
    };

    services.aionui-notifier = lib.mkIf cfg.notifications.enable {
      enable = true;
      webhookUrlFile = "${notifierStateDir}/hookshot_webhook_url";
      aionuiUrl = "http://127.0.0.1:${toString settings.services.private.aionui.port}";
    };

    # Persisted dirs must be created owned by their service users (a bare string
    # would make them root-owned, which the non-root services can't write to).
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = "/var/lib/aionui";
          inherit (config.services.aionui) user group;
          mode = "0750";
        }
      ]
      ++ lib.optional cfg.notifications.enable {
        directory = "/var/lib/aionui-notifier";
        inherit (config.services.aionui-notifier) user group;
        mode = "0750";
      };
    };
  };
}

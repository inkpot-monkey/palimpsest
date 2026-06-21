{
  config,
  lib,
  pkgs,
  self,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.matrix;
  domain = "matrix.palebluebytes.space";
  address = "127.0.0.1";
  matrixPort = settings.services.public.matrix.port;

  matrixSecrets = self.lib.getSecretFile "matrix";

  # GitHub profile picture, pinned by content hash so the avatar is reproducible
  # (https://github.com/inkpot-monkey.png — 460x460 PNG). Uploaded once to the
  # homeserver media repo and set as the admin avatar by registerAdmin below.
  adminAvatar = pkgs.fetchurl {
    url = "https://github.com/inkpot-monkey.png";
    hash = "sha256-8pj6GjyU1qBZuDckMIhPEN8AKLxR6meHbAm3v7LKHgY=";
  };

  # Populate tuwunel's appservice_dir from the loaded credentials at start.
  # Runs as the service user (which can read $CREDENTIALS_DIRECTORY and write the
  # RuntimeDirectory), copying only *-registration.yaml so the registration_token
  # credential is excluded from the directory tuwunel parses as appservices.
  tuwunelPreStart = pkgs.writeShellScript "tuwunel-prestart" ''
    set -eu
    install -d -m 0750 /run/tuwunel/appservices
    shopt -s nullglob
    for f in "$CREDENTIALS_DIRECTORY"/*-registration.yaml; do
      install -m 0400 "$f" /run/tuwunel/appservices/
    done
    # tuwunel's local media provider does not create its own root directory, so
    # uploads fail with ENOENT until it exists. Create it under the (persisted)
    # state directory.
    install -d -m 0700 /var/lib/tuwunel/media
  '';

  # Idempotently register the admin Matrix account via the shared registration
  # token (UIA token flow, the same one the aionui notifier self-registers with).
  # Ordered before other account-creating services so `grant_admin_to_first_user`
  # makes this the homeserver admin.
  registerAdmin = pkgs.writeShellScript "tuwunel-register-admin" ''
    set -eu
    url="http://${address}:${toString matrixPort}"
    pass="$(cat "$CREDENTIALS_DIRECTORY/admin_password")"
    token="$(cat "$CREDENTIALS_DIRECTORY/registration_token")"

    for _ in $(seq 1 30); do
      ${pkgs.curl}/bin/curl -sf "$url/_matrix/client/versions" >/dev/null && break
      sleep 2
    done

    # Step 1: initiate registration to obtain a UIA session. If the account
    # already exists the server answers M_USER_IN_USE with no session.
    session="$(${pkgs.curl}/bin/curl -s -X POST "$url/_matrix/client/v3/register" \
      -H 'content-type: application/json' \
      -d "$(${pkgs.jq}/bin/jq -nc --arg u "${cfg.adminLocalpart}" --arg p "$pass" \
        '{username:$u,password:$p,inhibit_login:true}')" \
      | ${pkgs.jq}/bin/jq -r '.session // empty')"

    if [ -z "$session" ]; then
      echo "admin account ${cfg.adminLocalpart} already exists"
    else
      # Step 2: complete registration with the token.
      code="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' -X POST "$url/_matrix/client/v3/register" \
        -H 'content-type: application/json' \
        -d "$(${pkgs.jq}/bin/jq -nc --arg u "${cfg.adminLocalpart}" --arg p "$pass" --arg t "$token" --arg s "$session" \
          '{username:$u,password:$p,inhibit_login:true,auth:{type:"m.login.registration_token",token:$t,session:$s}}')")"
      echo "admin registration HTTP $code"
      [ "$code" = "200" ]
    fi
    ${lib.optionalString (cfg.adminDisplayName != "") ''

      # Enforce the admin display name (declarative): log in for a token, then
      # set the profile. Best-effort — never fail the unit over a cosmetic name.
      at="$(${pkgs.curl}/bin/curl -s -X POST "$url/_matrix/client/v3/login" \
        -H 'content-type: application/json' \
        -d "$(${pkgs.jq}/bin/jq -nc --arg u "${cfg.adminLocalpart}" --arg p "$pass" \
          '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')" \
        | ${pkgs.jq}/bin/jq -r '.access_token // empty')"
      if [ -n "$at" ]; then
        ${pkgs.curl}/bin/curl -sf -o /dev/null -X PUT \
          "$url/_matrix/client/v3/profile/@${cfg.adminLocalpart}:${domain}/displayname" \
          -H "authorization: Bearer $at" -H 'content-type: application/json' \
          -d "$(${pkgs.jq}/bin/jq -nc --arg n "${cfg.adminDisplayName}" '{displayname:$n}')" \
          && echo "admin display name set to ${cfg.adminDisplayName}" \
          || echo "WARN: failed to set admin display name" >&2

        # Set the avatar only when currently unset: uploads here are not
        # content-addressed, so re-uploading every restart would mint a fresh
        # mxc and churn a profile-change event each time. One-shot is enough.
        cur="$(${pkgs.curl}/bin/curl -s \
          "$url/_matrix/client/v3/profile/@${cfg.adminLocalpart}:${domain}/avatar_url" \
          -H "authorization: Bearer $at" | ${pkgs.jq}/bin/jq -r '.avatar_url // empty')"
        if [ -z "$cur" ]; then
          mxc="$(${pkgs.curl}/bin/curl -s -X POST \
            "$url/_matrix/media/v3/upload?filename=avatar.png" \
            -H "authorization: Bearer $at" -H 'content-type: image/png' \
            --data-binary "@${adminAvatar}" \
            | ${pkgs.jq}/bin/jq -r '.content_uri // empty')"
          if [ -n "$mxc" ]; then
            ${pkgs.curl}/bin/curl -sf -o /dev/null -X PUT \
              "$url/_matrix/client/v3/profile/@${cfg.adminLocalpart}:${domain}/avatar_url" \
              -H "authorization: Bearer $at" -H 'content-type: application/json' \
              -d "$(${pkgs.jq}/bin/jq -nc --arg u "$mxc" '{avatar_url:$u}')" \
              && echo "admin avatar set to $mxc" \
              || echo "WARN: failed to set admin avatar" >&2
          else
            echo "WARN: avatar upload returned no content_uri" >&2
          fi
        fi
      else
        echo "WARN: could not log in to set admin display name" >&2
      fi
    ''}
  '';

  # Auto-create the "management"/"admin" DM between the admin user and each bridge
  # bot that asks for one (managementDms below), so they're present after a deploy
  # instead of needing a manual "start chat". The interactive auth INSIDE the room
  # (e.g. hookshot `github login`, WhatsApp QR) is still done by hand.
  #
  # Idempotency is a PERSISTED per-bot marker in StateDirectory, NOT a re-read of
  # m.direct: tuwunel doesn't reliably return global account data across runs, so
  # the old m.direct check spawned a fresh DM on every deploy. The m.direct write
  # is kept best-effort (so clients render the room as a DM). The marker dir is
  # persisted (below) so reboots don't re-create either.
  provisionDms = pkgs.writeShellScript "matrix-provision-dms" ''
    set -eu
    url="http://${address}:${toString matrixPort}"
    me="@${cfg.adminLocalpart}:${domain}"
    bots="${lib.concatStringsSep " " (map (lp: "@${lp}:${domain}") cfg.managementDms)}"
    state="$STATE_DIRECTORY"
    marker() { printf '%s/dm-%s' "$state" "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')"; }

    # Only bots without a marker need provisioning — skip the login entirely if none.
    pending=""
    for bot in $bots; do
      [ -s "$(marker "$bot")" ] || pending="$pending $bot"
    done
    [ -n "$pending" ] || { echo "dm-provision: all management DMs already created"; exit 0; }

    for _ in $(seq 1 30); do
      ${pkgs.curl}/bin/curl -sf "$url/_matrix/client/versions" >/dev/null && break
      sleep 2
    done

    pass="$(cat "$CREDENTIALS_DIRECTORY/admin_password")"
    at="$(${pkgs.curl}/bin/curl -s -X POST "$url/_matrix/client/v3/login" \
      -H 'content-type: application/json' \
      -d "$(${pkgs.jq}/bin/jq -nc --arg u "${cfg.adminLocalpart}" --arg p "$pass" \
        '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')" \
      | ${pkgs.jq}/bin/jq -r '.access_token // empty')"
    [ -n "$at" ] || { echo "dm-provision: admin login failed" >&2; exit 1; }
    auth=(-H "Authorization: Bearer $at")
    meenc="$(${pkgs.jq}/bin/jq -rn --arg m "$me" '$m|@uri')"

    # Seed m.direct from whatever the server returns (best-effort; merged into below).
    direct="$(${pkgs.curl}/bin/curl -s "''${auth[@]}" \
      "$url/_matrix/client/v3/user/$meenc/account_data/m.direct" \
      | ${pkgs.jq}/bin/jq -c 'if (type=="object" and (has("errcode")|not)) then . else {} end' \
        2>/dev/null || echo '{}')"

    changed=0
    for bot in $pending; do
      rid="$(${pkgs.curl}/bin/curl -s "''${auth[@]}" -X POST "$url/_matrix/client/v3/createRoom" \
        -H 'content-type: application/json' \
        -d "$(${pkgs.jq}/bin/jq -nc --arg b "$bot" \
          '{is_direct:true,invite:[$b],preset:"trusted_private_chat"}')" \
        | ${pkgs.jq}/bin/jq -r '.room_id // empty')"
      [ -n "$rid" ] || { echo "dm-provision: createRoom for $bot failed" >&2; continue; }
      printf '%s' "$rid" > "$(marker "$bot")"
      direct="$(printf '%s' "$direct" | ${pkgs.jq}/bin/jq -c --arg b "$bot" --arg r "$rid" \
        '.[$b] = ((.[$b] // []) + [$r])')"
      changed=1
      echo "dm-provision: created DM with $bot -> $rid"
    done

    if [ "$changed" = 1 ]; then
      ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
        "$url/_matrix/client/v3/user/$meenc/account_data/m.direct" \
        -H 'content-type: application/json' -d "$direct" >/dev/null || true
      echo "dm-provision: m.direct updated"
    fi
  '';
in
{
  imports = [
    ./mautrix-whatsapp.nix
    ./jmap-bridge.nix
    ./hookshot.nix
  ];

  options.custom.profiles.matrix = {
    enable = lib.mkEnableOption "Matrix homeserver (tuwunel) configuration";

    adminLocalpart = lib.mkOption {
      type = lib.types.str;
      default = "inkpotmonkey";
      description = "Localpart of the Matrix account granted homeserver admin.";
    };

    adminDisplayName = lib.mkOption {
      type = lib.types.str;
      default = "inkpotmonkey";
      description = ''
        Display name to set on the admin account, enforced on every (re)start
        of the register-admin service. Set to "" to leave the display name
        unmanaged (Matrix then defaults it to the localpart). Because it is
        re-applied each start, changing it in a client is reset on the next
        restart.
      '';
    };

    # Bridge modules contribute their appservice registration here; tuwunel's
    # service wiring (below) consumes the lot generically, so adding a bridge
    # never touches this file. The attr name becomes the credential basename
    # (`<name>-registration.yaml`), which tuwunelPreStart globs into appservice_dir.
    appservices = lib.mkOption {
      internal = true;
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.registrationPath = lib.mkOption {
            type = lib.types.path;
            description = "Path to the bridge's sops-rendered registration.yaml.";
          };
        }
      );
      description = "Appservice registrations contributed by enabled bridge modules.";
    };

    # Bridge modules add their bot's localpart here to have a management/admin DM
    # auto-created with the admin user on deploy (see provisionDms above).
    managementDms = lib.mkOption {
      internal = true;
      default = [ ];
      type = lib.types.listOf lib.types.str;
      description = "Bridge bot localparts to auto-create an admin/management DM with.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Via the contract aggregator (the sole writer of permittedInsecurePackages), so
    # this merges with any other permit on the host instead of clobbering it.
    custom.insecurePackages = [ "olm-3.2.16" ];

    # ----------------------------------------------------------------------------
    # Secret Management (SOPS)
    # ----------------------------------------------------------------------------
    sops.defaultSopsFormat = "yaml";

    sops.secrets.registration_token = {
      sopsFile = matrixSecrets;
    };
    sops.secrets.matrix_admin_password = {
      sopsFile = matrixSecrets;
    };

    # ----------------------------------------------------------------------------
    # tuwunel (Matrix homeserver, conduwuit lineage)
    # ----------------------------------------------------------------------------
    services.matrix-tuwunel = {
      enable = true;
      settings.global = {
        server_name = domain;
        address = [ address ];
        port = [ matrixPort ];

        allow_federation = true;
        trusted_servers = [
          "matrix.org"
          "nixos.org"
          "libera.chat"
        ];

        # Closed registration except via the shared token; the first account
        # created becomes admin.
        allow_registration = true;
        registration_token_file = "/run/credentials/tuwunel.service/registration_token";
        grant_admin_to_first_user = true;

        # Bridges register declaratively from this directory (populated from
        # systemd credentials by setupAppservices below).
        appservice_dir = "/run/tuwunel/appservices/";
      };
    };

    systemd.services.tuwunel = {
      serviceConfig = {
        # tuwunel loads bridge registrations declaratively from `appservice_dir`
        # (unlike Conduit's #admins-room dance). They arrive as systemd credentials
        # and are copied into the dir by tuwunelPreStart, so the secret tokens never
        # land in a world-readable path.
        LoadCredential = [
          "registration_token:${config.sops.secrets.registration_token.path}"
        ]
        ++ lib.mapAttrsToList (name: a: "${name}-registration.yaml:${a.registrationPath}") cfg.appservices;
        ExecStartPre = [ tuwunelPreStart ];
      };
      restartTriggers = [
        config.sops.secrets.registration_token.path
      ]
      ++ lib.mapAttrsToList (_name: a: a.registrationPath) cfg.appservices;
    };

    # Declaratively create the admin account once tuwunel is up.
    systemd.services.tuwunel-register-admin = {
      description = "Register the admin Matrix account on tuwunel";
      after = [ "tuwunel.service" ];
      requires = [ "tuwunel.service" ];
      wantedBy = [ "multi-user.target" ];
      # Register before other account-creating services so this account wins
      # grant_admin_to_first_user.
      before = [ "aionui-notifier.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        DynamicUser = true;
        LoadCredential = [
          "registration_token:${config.sops.secrets.registration_token.path}"
          "admin_password:${config.sops.secrets.matrix_admin_password.path}"
        ];
        ExecStart = registerAdmin;
      };
    };

    # Auto-create management/admin DMs with bridge bots (opt-in per bridge via
    # custom.profiles.matrix.managementDms). Runs after the admin exists and the
    # bridges are up so the invited bots are present to auto-join.
    systemd.services.matrix-dm-provision = lib.mkIf (cfg.managementDms != [ ]) {
      description = "Auto-create management DMs between the admin and bridge bots";
      after = [
        "tuwunel.service"
        "tuwunel-register-admin.service"
        "matrix-hookshot.service"
        "mautrix-whatsapp.service"
      ];
      requires = [
        "tuwunel.service"
        "tuwunel-register-admin.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        DynamicUser = true;
        # Persisted (see environment.persistence below) marker dir — the source of
        # truth for "this bot's DM already exists", so re-runs don't duplicate it.
        StateDirectory = "matrix-dm-provision";
        StateDirectoryMode = "0700";
        LoadCredential = [ "admin_password:${config.sops.secrets.matrix_admin_password.path}" ];
        ExecStart = provisionDms;
      };
    };

    # ----------------------------------------------------------------------------
    # Caddy Reverse Proxy
    # ----------------------------------------------------------------------------
    services.caddy.virtualHosts."${domain}" = {
      hostName = domain;
      extraConfig = lib.mkBefore (
        ''
          # Matrix server discovery (Fed)
          handle /.well-known/matrix/server {
            header Content-Type "application/json"
            header Access-Control-Allow-Origin "*"
            respond `{"m.server":"${domain}:443"}`
          }

          # Matrix client discovery
          handle /.well-known/matrix/client {
            header Content-Type "application/json"
            header Access-Control-Allow-Origin "*"
            respond `{"m.homeserver":{"base_url":"https://${domain}"}}`
          }
        ''
        + ''
          import cloudflare_tls
          handle {
            reverse_proxy ${address}:${toString matrixPort}
          }
        ''
      );
    };

    # Enforce secure permissions on /var/lib/private to satisfy DynamicUser
    # requirements (the jmap bridge runs as a DynamicUser).
    systemd.tmpfiles.rules = [
      "z /var/lib/private 0700 root root -"
      "z /persistent/var/lib/private 0700 root root -"
    ];

    # Persist the dm-provision markers so reboots (impermanence) don't drop the
    # "DM already created" state and re-spawn duplicate management DMs.
    environment.persistence."/persistent" =
      lib.mkIf (config.custom.profiles.impermanence.enable && cfg.managementDms != [ ])
        {
          directories = [ "/var/lib/private/matrix-dm-provision" ];
        };
  };
}

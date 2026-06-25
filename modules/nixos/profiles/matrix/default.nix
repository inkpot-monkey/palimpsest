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
  # token (UIA token flow). Other account-creating services (e.g. claude-relay-
  # register) order themselves AFTER this so `grant_admin_to_first_user` makes this
  # account the homeserver admin.
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

        # Favourite the homeserver admin room so it's easy to find. m.favourite is
        # personal account data (works regardless of power level). Best-effort.
        meenc="$(${pkgs.jq}/bin/jq -rn --arg m "@${cfg.adminLocalpart}:${domain}" '$m|@uri')"
        aliasenc="$(${pkgs.jq}/bin/jq -rn --arg a "#admins:${domain}" '$a|@uri')"
        adminroom="$(${pkgs.curl}/bin/curl -s \
          "$url/_matrix/client/v3/directory/room/$aliasenc" \
          -H "authorization: Bearer $at" | ${pkgs.jq}/bin/jq -r '.room_id // empty')"
        if [ -n "$adminroom" ]; then
          roomenc="$(${pkgs.jq}/bin/jq -rn --arg r "$adminroom" '$r|@uri')"
          ${pkgs.curl}/bin/curl -sf -o /dev/null -X PUT \
            "$url/_matrix/client/v3/user/$meenc/rooms/$roomenc/tags/m.favourite" \
            -H "authorization: Bearer $at" -H 'content-type: application/json' -d '{"order":0.1}' \
            && echo "admin room favourited ($adminroom)" \
            || echo "WARN: failed to favourite admin room" >&2
        else
          echo "WARN: could not resolve #admins room to favourite" >&2
        fi
      else
        echo "WARN: could not log in to set admin display name" >&2
      fi
    ''}
  '';

  # Per-bridge management DMs now live in each bridge module (see dm-provision.nix
  # and the `matrix-dm-<bot>` service each bridge declares). This file only owns
  # the homeserver, the admin account, and the cross-bridge `matrix-reset` helper.

  # `matrix-reset` — wipe the homeserver + every bridge's state + the DM markers
  # and bring the stack back up clean, for quick from-scratch testing. Each bridge
  # contributes its units/paths via custom.profiles.matrix.resetState, so this
  # never needs editing when a bridge is added. Replaces the hand-rolled
  # `ssh kelpy "sudo bash -c 'systemctl stop … && rm -rf …'"` one-liner, and
  # crucially clears the DM markers in lockstep with the homeserver (the bind-mount
  # markers can't be `rm`'d, only emptied) so DMs are actually recreated.
  bridgeUnits = map (e: e.service) (lib.filter (e: !e.isDm) cfg.resetState);
  dmUnits = map (e: e.service) (lib.filter (e: e.isDm) cfg.resetState);
  # /var/lib/private/tuwunel is the homeserver's (DynamicUser) state dir.
  wipePaths = lib.unique (
    lib.concatMap (e: e.paths) cfg.resetState ++ [ "/var/lib/private/tuwunel" ]
  );
  # Per-bridge reminders of state a from-scratch wipe destroys that only a human
  # can restore (re-pair WhatsApp, re-add hookshot connections, …). Printed at the
  # end of the run so the aftermath is never a surprise.
  resetNotes = map (e: e.postResetNote) (lib.filter (e: e.postResetNote != null) cfg.resetState);
  # For selective reset (`matrix-reset <bridge>`): one "service:::space-joined-paths"
  # token per resetState entry, so the script can stop/wipe/restart just the matches.
  resetEntryStrings = map (
    e:
    "${e.service}:::${lib.concatStringsSep " " e.paths}:::${lib.concatStringsSep " " e.roomMemberPrefixes}"
  ) cfg.resetState;

  matrixReset = pkgs.writeShellApplication {
    name = "matrix-reset";
    runtimeInputs = [
      pkgs.systemd
      pkgs.coreutils
      pkgs.findutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      if [ "''${1:-}" = "-h" ] || [ "''${1:-}" = "--help" ]; then
        echo "Usage: matrix-reset [BRIDGE]"
        echo "  (no arg)  Full from-scratch reset: wipe the homeserver + every bridge"
        echo "            + DM markers and bring the whole stack back up clean."
        echo "  BRIDGE    Reset ONLY the matching bridge(s): stop, wipe their local"
        echo "            state, restart -- leaving the homeserver + other bridges up."
        echo "            Matches resetState service names by substring, e.g."
        echo "            'matrix-reset jmap', 'matrix-reset hookshot'."
        echo "            NOTE: wipes the bridge's LOCAL state only; rooms it created"
        echo "            on the homeserver are NOT removed (use a full reset)."
        exit 0
      fi

      if [ "$(id -u)" -ne 0 ]; then
        echo "matrix-reset: must run as root (try: sudo matrix-reset)" >&2
        exit 1
      fi

      # --- Selective reset: `matrix-reset <bridge>` wipes + restarts just that
      # bridge, without touching the homeserver or the other bridges. ---
      if [ "$#" -gt 0 ]; then
        pat="$1"
        entries=(${lib.escapeShellArgs resetEntryStrings})
        svcs=()
        wipes=()
        prefixes=()
        for entry in "''${entries[@]}"; do
          svc="''${entry%%:::*}"
          rest="''${entry#*:::}"
          epaths="''${rest%%:::*}"
          eprefixes="''${rest#*:::}"
          case "$svc" in
            *"$pat"*)
              svcs+=("$svc")
              read -ra ep <<< "$epaths"
              wipes+=("''${ep[@]}")
              read -ra epre <<< "$eprefixes"
              prefixes+=("''${epre[@]}")
              ;;
          esac
        done
        if [ "''${#svcs[@]}" -eq 0 ]; then
          echo "matrix-reset: no bridge matches '$pat'. Known services:" >&2
          for entry in "''${entries[@]}"; do echo "  ''${entry%%:::*}" >&2; done
          exit 1
        fi
        echo "matrix-reset: resetting ''${svcs[*]} (homeserver + other bridges untouched)..."
        systemctl stop "''${svcs[@]}" || true
        for d in "''${wipes[@]}"; do
          if [ -d "$d" ]; then
            find "$d" -mindepth 1 -delete 2>/dev/null || true
            echo "  wiped $d"
          fi
        done
        # restart (not start): re-runs the RemainAfterExit oneshots too; After=
        # ordering (bridge before its DM) is honoured by systemd.
        systemctl restart "''${svcs[@]}" || true

        # Remove old test rooms: as the admin, leave+forget every room containing a
        # member that matches one of the bridge's ghost prefixes — so they vanish
        # from the client. (tuwunel has no room-delete API, so the server-side shell
        # lingers until a full reset, but it's gone from your view.)
        if [ "''${#prefixes[@]}" -gt 0 ]; then
          url="http://${address}:${toString matrixPort}"
          pass="$(cat ${config.sops.secrets.matrix_admin_password.path} 2>/dev/null || true)"
          at=""
          [ -n "$pass" ] && at="$(curl -s -X POST "$url/_matrix/client/v3/login" \
            -H 'content-type: application/json' \
            -d "$(jq -nc --arg u "${cfg.adminLocalpart}" --arg p "$pass" \
              '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')" \
            | jq -r '.access_token // empty')"
          if [ -z "$at" ]; then
            echo "matrix-reset: admin login failed; skipping old-room cleanup" >&2
          else
            echo "matrix-reset: removing old rooms (members matching: ''${prefixes[*]})..."
            removed=0
            mapfile -t rooms < <(curl -s "$url/_matrix/client/v3/joined_rooms" \
              -H "authorization: Bearer $at" | jq -r '.joined_rooms[]?')
            for room in "''${rooms[@]}"; do
              renc="$(jq -rn --arg r "$room" '$r|@uri')"
              members="$(curl -s "$url/_matrix/client/v3/rooms/$renc/joined_members" \
                -H "authorization: Bearer $at" | jq -r '.joined // {} | keys[]')"
              for pre in "''${prefixes[@]}"; do
                if printf '%s\n' "$members" | grep -qF "$pre"; then
                  curl -sf -o /dev/null -X POST "$url/_matrix/client/v3/rooms/$renc/leave" \
                    -H "authorization: Bearer $at" -H 'content-type: application/json' -d '{}' || true
                  curl -sf -o /dev/null -X POST "$url/_matrix/client/v3/rooms/$renc/forget" \
                    -H "authorization: Bearer $at" -H 'content-type: application/json' -d '{}' || true
                  removed=$((removed + 1))
                  break
                fi
              done
            done
            echo "matrix-reset: left+forgot $removed old room(s)."
          fi
        fi

        echo "matrix-reset: done — '$pat' wiped + restarted."
        exit 0
      fi

      bridges=(${lib.escapeShellArgs bridgeUnits})
      dms=(${lib.escapeShellArgs dmUnits})
      paths=(${lib.escapeShellArgs wipePaths})

      echo "matrix-reset: stopping stack..."
      systemctl stop "''${dms[@]}" "''${bridges[@]}" \
        tuwunel-register-admin.service tuwunel.service || true

      echo "matrix-reset: wiping homeserver + bridge + DM-marker state..."
      for d in "''${paths[@]}"; do
        if [ -d "$d" ]; then
          # Contents only: persisted dirs are bind-mounts whose mountpoint can't be removed.
          find "$d" -mindepth 1 -delete 2>/dev/null || true
          echo "  wiped $d"
        fi
      done

      echo "matrix-reset: starting homeserver..."
      systemctl start tuwunel.service
      systemctl start tuwunel-register-admin.service

      echo "matrix-reset: starting bridges..."
      [ "''${#bridges[@]}" -gt 0 ] && systemctl start "''${bridges[@]}"

      # Let the bridges' appservice links come up before inviting the bots, so the
      # bots receive and auto-join the DM invites instead of losing the startup race.
      sleep 15

      echo "matrix-reset: provisioning management DMs..."
      # restart (not start): the DM oneshots are RemainAfterExit and may still be
      # "active (exited)" from boot, which makes `start` a no-op.
      [ "''${#dms[@]}" -gt 0 ] && { systemctl restart "''${dms[@]}" || true; }

      echo "matrix-reset: done."

      notes=(${lib.escapeShellArgs resetNotes})
      if [ "''${#notes[@]}" -gt 0 ]; then
        echo
        echo "matrix-reset: a from-scratch wipe cleared state only you can restore:"
        for n in "''${notes[@]}"; do
          echo "  - $n"
        done
      fi
    '';
  };
in
{
  imports = [
    ./mautrix-whatsapp.nix
    ./jmap-bridge.nix
    ./hookshot.nix
    ./infra-alerts.nix
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

    # Bridge modules describe their resettable units and state dirs here; the
    # `matrix-reset` helper aggregates the lot, so adding a bridge never touches
    # this file. DM provisioner oneshots set isDm = true so reset restarts them
    # AFTER the bridges are back up.
    resetState = lib.mkOption {
      internal = true;
      default = [ ];
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            service = lib.mkOption {
              type = lib.types.str;
              description = "systemd unit to stop and (re)start on reset.";
            };
            isDm = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "DM provisioner oneshots: restarted after the bridges, with a delay.";
            };
            paths = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Directories whose contents are wiped on reset.";
            };
            postResetNote = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                One-line reminder of state the wipe destroys that only a human can
                restore (e.g. "re-pair WhatsApp: open the @whatsapp DM and run
                login"). Printed at the end of a `matrix-reset` run.
              '';
            };
            roomMemberPrefixes = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "@_jmap_" ];
              description = ''
                MXID prefixes identifying this bridge's ghost/bot users. On a
                SELECTIVE reset (`matrix-reset <bridge>`), the admin leaves+forgets
                every room containing such a member, so old test rooms disappear
                from the client. (A full reset wipes the homeserver outright, so it
                needs none of this.)
              '';
            };
          };
        }
      );
      description = "Per-bridge resettable units/paths aggregated into the matrix-reset helper.";
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

    # `matrix-reset` (root): wipe the homeserver + all bridge state + DM markers
    # and bring the stack back up clean. Quick from-scratch testing without the
    # error-prone manual `systemctl stop … && rm -rf …` one-liner.
    environment.systemPackages = [ matrixReset ];

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
      # Shared advisory lock so the per-bridge DM provisioners serialize their
      # read-modify-write of the single @admin m.direct account data (dm-provision.nix).
      "f /run/matrix-dm-mdirect.lock 0666 root root -"
    ];

    # Persist the homeserver state across impermanence reboots. Without this,
    # tuwunel comes up empty every boot (all rooms/accounts/m.direct gone) while
    # the persisted bridge logins + DM markers survive — exactly the desync that
    # leaves the management DMs unrecreated. Per-bridge state and the DM markers
    # are persisted alongside, by each bridge module (same lifetime as here).
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [ "/var/lib/private/tuwunel" ];
    };
  };
}

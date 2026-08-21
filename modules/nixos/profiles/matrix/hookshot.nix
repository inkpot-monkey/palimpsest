{
  config,
  lib,
  pkgs,
  self,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.matrix.hookshot;
  domain = config.services.matrix-tuwunel.settings.global.server_name;
  adminLocalpart = config.custom.profiles.matrix.adminLocalpart;
  matrixSecrets = self.lib.getSecretFile "matrix";

  user = "matrix-hookshot";
  stateDir = "/var/lib/matrix-hookshot";

  # Homeserver client-server API (loopback; tuwunel binds here — see matrix/default.nix).
  homeserverUrl = "http://${builtins.head config.services.matrix-tuwunel.settings.global.address}:${toString (builtins.head config.services.matrix-tuwunel.settings.global.port)}";

  # Appservice port the homeserver dials (loopback only — must match the `url`
  # in the registration below). Not a public service, so it stays out of settings.nix.
  appservicePort = 9993;

  # Public webhook/oauth listener. GitHub + generic POSTs and the OAuth callback
  # land here via Caddy (hookshot.<domain> → 127.0.0.1:webhookPort). Driven by
  # settings.nix so the proxy + DNS pick it up automatically.
  webhookPort = settings.services.public.hookshot.port;
  publicUrl = "https://hookshot.${config.networking.domain}";

  # Builder for this bridge's own management-DM auto-provisioner (split out of the
  # central matrix-dm-provision so each bridge owns its auto-join wiring).
  mkDmService = import ./dm-provision.nix { inherit pkgs config; };

  # Bot avatar. The upstream logo.png is only 64x69, so as a Matrix avatar it
  # pixelates and gets cropped (looks amateur). Element can't render an SVG avatar,
  # so we rasterise the upstream logo.svg at high resolution and centre it (with
  # padding) on a 512x512 white square — crisp and properly proportioned. Hookshot
  # uploads this file path idempotently on each start (BotUsersManager.ensureProfile),
  # re-uploading when the bytes change, so it self-heals after a matrix-reset.
  hookshotLogoSvg = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/matrix-org/matrix-hookshot/${config.services.matrix-hookshot.package.version}/logo.svg";
    hash = "sha256-ElWb31h0n7O3dmP3hhN3IZPhmAaUG+i6gfa3Htg6z2I=";
  };
  hookshotAvatar =
    pkgs.runCommand "hookshot-avatar.png"
      {
        nativeBuildInputs = [
          pkgs.resvg
          pkgs.imagemagick
        ];
      }
      ''
        resvg --width 400 ${hookshotLogoSvg} logo.png
        magick -size 512x512 xc:white logo.png -gravity center -composite "$out"
      '';

  # Create a "Hookshot" Matrix Space grouping the @hookshot rooms, as @inkpotmonkey
  # (so the operator is the creator + already joined — no invite to accept). Sets
  # the space avatar to the hookshot logo, files the @hookshot management DM under
  # it, and favourites it. Idempotent: the space id is persisted; on a matrix-reset
  # the marker is wiped and it's recreated. All plain C-S API (no e2ee needed —
  # space membership is state, not message content).
  hookshotSpace = pkgs.writeShellScript "matrix-hookshot-space" ''
    set -eu
    url="${homeserverUrl}"
    me="@${adminLocalpart}:${domain}"
    bot="@hookshot:${domain}"
    marker="$STATE_DIRECTORY/space-created"
    meenc="$(${pkgs.jq}/bin/jq -rn --arg m "$me" '$m|@uri')"

    for _ in $(seq 1 30); do
      ${pkgs.curl}/bin/curl -sf "$url/_matrix/client/versions" >/dev/null && break
      sleep 2
    done

    pass="$(cat "$CREDENTIALS_DIRECTORY/admin_password")"
    at="$(${pkgs.curl}/bin/curl -s -X POST "$url/_matrix/client/v3/login" \
      -H 'content-type: application/json' \
      -d "$(${pkgs.jq}/bin/jq -nc --arg u "${adminLocalpart}" --arg p "$pass" \
        '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')" \
      | ${pkgs.jq}/bin/jq -r '.access_token // empty')"
    [ -n "$at" ] || { echo "hookshot-space: admin login failed" >&2; exit 1; }
    auth=(-H "Authorization: Bearer $at")

    # Create or reuse the Space.
    if [ -s "$marker" ]; then
      space="$(cat "$marker")"
    else
      space="$(${pkgs.curl}/bin/curl -s "''${auth[@]}" -X POST "$url/_matrix/client/v3/createRoom" \
        -H 'content-type: application/json' \
        -d '{"name":"Hookshot","topic":"GitHub / webhooks / feeds — hookshot rooms","preset":"private_chat","creation_content":{"type":"m.space"}}' \
        | ${pkgs.jq}/bin/jq -r '.room_id // empty')"
      [ -n "$space" ] || { echo "hookshot-space: createRoom failed" >&2; exit 1; }
      printf '%s' "$space" > "$marker"
      echo "hookshot-space: created Space -> $space"
    fi
    spaceenc="$(${pkgs.jq}/bin/jq -rn --arg r "$space" '$r|@uri')"

    # Avatar: upload + set, only when unset (uploads aren't content-addressed).
    curav="$(${pkgs.curl}/bin/curl -s "''${auth[@]}" \
      "$url/_matrix/client/v3/rooms/$spaceenc/state/m.room.avatar" \
      | ${pkgs.jq}/bin/jq -r '.url // empty' 2>/dev/null || echo "")"
    if [ -z "$curav" ]; then
      mxc="$(${pkgs.curl}/bin/curl -s "''${auth[@]}" -X POST \
        "$url/_matrix/media/v3/upload?filename=hookshot.png" \
        -H 'content-type: image/png' --data-binary "@${hookshotAvatar}" \
        | ${pkgs.jq}/bin/jq -r '.content_uri // empty')"
      [ -n "$mxc" ] && ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
        "$url/_matrix/client/v3/rooms/$spaceenc/state/m.room.avatar" \
        -H 'content-type: application/json' -d "$(${pkgs.jq}/bin/jq -nc --arg u "$mxc" '{url:$u}')" >/dev/null \
        && echo "hookshot-space: avatar set" || echo "hookshot-space: avatar set failed (non-fatal)" >&2
    fi

    # Favourite the Space (personal account data; idempotent).
    ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
      "$url/_matrix/client/v3/user/$meenc/rooms/$spaceenc/tags/m.favourite" \
      -H 'content-type: application/json' -d '{"order":0.05}' >/dev/null || true

    # File the @hookshot management DM under the Space (child + parent), found via
    # m.direct so we don't read another service's private state dir.
    dm="$(${pkgs.curl}/bin/curl -s "''${auth[@]}" \
      "$url/_matrix/client/v3/user/$meenc/account_data/m.direct" \
      | ${pkgs.jq}/bin/jq -r --arg b "$bot" '.[$b][0] // empty' 2>/dev/null || echo "")"
    if [ -n "$dm" ]; then
      dmenc="$(${pkgs.jq}/bin/jq -rn --arg r "$dm" '$r|@uri')"
      via="$(${pkgs.jq}/bin/jq -nc --arg d "${domain}" '{via:[$d]}')"
      ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
        "$url/_matrix/client/v3/rooms/$spaceenc/state/m.space.child/$dmenc" \
        -H 'content-type: application/json' -d "$via" >/dev/null || true
      ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
        "$url/_matrix/client/v3/rooms/$dmenc/state/m.space.parent/$spaceenc" \
        -H 'content-type: application/json' \
        -d "$(${pkgs.jq}/bin/jq -nc --arg d "${domain}" '{via:[$d],canonical:true}')" >/dev/null || true
      echo "hookshot-space: filed @hookshot DM under the Space"
    fi
    ${lib.optionalString
      (
        config.custom.profiles.matrix.infraAlerts.enable
        && config.custom.profiles.matrix.infraAlerts.roomId != ""
      )
      ''
        # File #infra-alerts under the Space (child + parent). Its roomId is pinned
        # in config and the admin created the room, so it can set m.space.parent there.
        infra="${config.custom.profiles.matrix.infraAlerts.roomId}"
        infraenc="$(${pkgs.jq}/bin/jq -rn --arg r "$infra" '$r|@uri')"
        ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
          "$url/_matrix/client/v3/rooms/$spaceenc/state/m.space.child/$infraenc" \
          -H 'content-type: application/json' -d "$(${pkgs.jq}/bin/jq -nc --arg d "${domain}" '{via:[$d]}')" >/dev/null || true
        ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
          "$url/_matrix/client/v3/rooms/$infraenc/state/m.space.parent/$spaceenc" \
          -H 'content-type: application/json' \
          -d "$(${pkgs.jq}/bin/jq -nc --arg d "${domain}" '{via:[$d],canonical:true}')" >/dev/null || true
        echo "hookshot-space: filed #infra-alerts under the Space"
      ''
    }
    ${lib.optionalString notificationsRoom.enable ''
      # File the GitHub Notifications room under the Space too. Its id is
      # server-assigned, so it comes from the room oneshot's marker (0644 in a
      # 0755 StateDirectory precisely so this DynamicUser oneshot can read it).
      if [ -s "${notificationsRoom.roomIdFile}" ]; then
        notif="$(cat "${notificationsRoom.roomIdFile}")"
        notifenc="$(${pkgs.jq}/bin/jq -rn --arg r "$notif" '$r|@uri')"
        ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
          "$url/_matrix/client/v3/rooms/$spaceenc/state/m.space.child/$notifenc" \
          -H 'content-type: application/json' -d "$(${pkgs.jq}/bin/jq -nc --arg d "${domain}" '{via:[$d]}')" >/dev/null || true
        ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
          "$url/_matrix/client/v3/rooms/$notifenc/state/m.space.parent/$spaceenc" \
          -H 'content-type: application/json' \
          -d "$(${pkgs.jq}/bin/jq -nc --arg d "${domain}" '{via:[$d],canonical:true}')" >/dev/null || true
        echo "hookshot-space: filed the notifications room under the Space"
      fi
    ''}
  '';

  # The DM provisioner's marker (its StateDirectory), read by the admin-room
  # oneshot to learn which room to mark.
  dmMarker = "/var/lib/private/matrix-dm-hookshot/dm-created";
  adminRoomStateDir = "matrix-hookshot-adminroom";
  inherit (cfg) notificationsRoom;
  notificationsAdminRoomStateDir = "matrix-hookshot-notifications-adminroom";

  # Builder for the admin-room marker + notification-stream seed (split out so the
  # VM check can drive the real script — see hookshot-adminroom.nix).
  mkAdminRoomService = import ./hookshot-adminroom.nix { inherit pkgs config; };
in
{
  options.custom.profiles.matrix.hookshot = {
    enable = lib.mkEnableOption ''
      matrix-hookshot — GitHub (personal notifications + repo events), generic
      inbound webhooks, and RSS/Atom feeds bridged into Matrix
    '';
  };

  config = lib.mkIf cfg.enable {
    # Dedicated hardened service account (not root, unlike the nixpkgs module
    # default). A static system user — not DynamicUser — so sops can chown the
    # rendered config/registration/key to it (a DynamicUser's uid is unknown at
    # activation, the classic sops + DynamicUser clash).
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      home = stateDir;
      createHome = false;
      description = "matrix-hookshot service user";
    };
    users.groups.${user} = { };

    # --- Secrets (all in the matrix profile secrets file) ---
    # as/hs tokens are the appservice's Matrix credentials; the rest describe the
    # one-time-created GitHub App (id/key/webhook secret/OAuth client). You add
    # the values to secrets/profiles/matrix.yaml after creating the App — see the
    # ADR / module README for the exact GitHub App setup.
    sops.secrets =
      lib.genAttrs
        [
          "hookshot_as_token"
          "hookshot_hs_token"
          "hookshot_github_app_id"
          "hookshot_github_private_key"
          "hookshot_github_webhook_secret"
          "hookshot_github_oauth_client_id"
          "hookshot_github_oauth_client_secret"
        ]
        (_: {
          sopsFile = matrixSecrets;
          owner = user;
          restartUnits = [ "matrix-hookshot.service" ];
        });

    # --- config.yml (rendered via sops, NOT services.matrix-hookshot.settings) ---
    # The nixpkgs module renders `settings` into a world-readable Nix store file,
    # but hookshot keeps the webhook secret and OAuth client_secret INLINE (only
    # the App key takes a path). So we template the whole config and override
    # ExecStart to consume it — the same secret-handling stance as the jmap and
    # whatsapp registrations.
    sops.templates."hookshot-config.yml" = {
      owner = user;
      restartUnits = [ "matrix-hookshot.service" ];
      content = ''
        bridge:
          domain: ${domain}
          url: ${homeserverUrl}
          mediaUrl: https://${domain}
          port: ${toString appservicePort}
          bindAddress: 127.0.0.1
        bot:
          displayname: Hookshot
          avatar: ${hookshotAvatar}
        passFile: ${stateDir}/passkey.pem
        logging:
          level: info
        listeners:
          - port: ${toString webhookPort}
            bindAddress: 127.0.0.1
            resources:
              - webhooks
        github:
          auth:
            id: ${config.sops.placeholder.hookshot_github_app_id}
            privateKeyFile: ${config.sops.secrets.hookshot_github_private_key.path}
          webhook:
            secret: ${config.sops.placeholder.hookshot_github_webhook_secret}
          oauth:
            client_id: ${config.sops.placeholder.hookshot_github_oauth_client_id}
            client_secret: ${config.sops.placeholder.hookshot_github_oauth_client_secret}
            redirect_uri: ${publicUrl}/oauth
        generic:
          enabled: true
          urlPrefix: ${publicUrl}/webhook/
          userIdPrefix: _webhooks_
          allowJsTransformationFunctions: true
          waitForComplete: false
        feeds:
          enabled: true
          pollIntervalSeconds: 600
        permissions:
          - actor: "@${adminLocalpart}:${domain}"
            services:
              - service: "*"
                level: admin
        ${lib.optionalString
          (
            config.custom.profiles.matrix.infraAlerts.enable
            && config.custom.profiles.matrix.infraAlerts.roomId != ""
          )
          ''
            connections:
              - connectionType: uk.half-shot.matrix-hookshot.generic.hook
                stateKey: ${config.sops.placeholder.infra_alerts_hook_id}
                roomId: "${config.custom.profiles.matrix.infraAlerts.roomId}"
                state:
                  name: infra-alerts
          ''
        }
      '';
    };

    # --- Appservice registration (sops-rendered; shared verbatim with tuwunel) ---
    # hookshot reads as/hs tokens + namespaces here; tuwunel loads the identical
    # file from appservice_dir. Ghost prefixes: _github_ (GitHub authors) and
    # _webhooks_ (generic-hook senders). The `hookshot` sender_localpart is
    # implicitly granted by tuwunel even though it sits outside the namespaces.
    sops.templates."hookshot-registration.yaml" = {
      owner = user;
      restartUnits = [
        "matrix-hookshot.service"
        "tuwunel.service"
      ];
      content = ''
        id: hookshot
        url: http://127.0.0.1:${toString appservicePort}
        as_token: ${config.sops.placeholder.hookshot_as_token}
        hs_token: ${config.sops.placeholder.hookshot_hs_token}
        sender_localpart: hookshot
        rate_limited: false
        namespaces:
          users:
            - exclusive: true
              regex: '@_github_.*'
            - exclusive: true
              regex: '@_webhooks_.*'
          aliases: []
          rooms: []
      '';
    };

    services.matrix-hookshot = {
      enable = true;
      registrationFile = config.sops.templates."hookshot-registration.yaml".path;
      serviceDependencies = [ "tuwunel.service" ];
      # passFile lives under the (persisted) StateDirectory; the module's preStart
      # generates it on first run. Everything else in `settings` is unused — we
      # drive the real config via the sops template + ExecStart override below.
      settings.passFile = "${stateDir}/passkey.pem";
    };

    systemd.services.matrix-hookshot.serviceConfig = {
      ExecStart = lib.mkForce (
        "${config.services.matrix-hookshot.package}/bin/matrix-hookshot "
        + "${config.sops.templates."hookshot-config.yml".path} "
        + "${config.sops.templates."hookshot-registration.yaml".path}"
      );

      User = user;
      Group = user;
      StateDirectory = "matrix-hookshot";
      StateDirectoryMode = "0750";

      # Internet-facing → harden tightly. Only needs the network and its state dir.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ stateDir ];
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      LockPersonality = true;
    };

    # Contribute the registration to tuwunel's appservice_dir wiring — see the
    # generic `appservices` consumer in matrix/default.nix.
    custom.profiles.matrix.appservices.hookshot.registrationPath =
      config.sops.templates."hookshot-registration.yaml".path;

    # Auto-create the @hookshot admin DM (where `github login` etc. are run). The
    # bridge bot auto-joins the invite. Ordered after the bridge so its appservice
    # link is up to receive the invite.
    systemd.services."matrix-dm-hookshot" = mkDmService {
      bot = "hookshot";
      afterUnit = "matrix-hookshot.service";
      name = "Hookshot admin";
      topic = "Hookshot admin room — `!hookshot help` for commands; `github login` then `github notifications toggle` to bridge your GitHub notifications here.";
    };

    # Mark that DM as a hookshot admin room and seed its notification stream
    # position (see hookshot-adminroom.nix), after the DM exists and the bot has
    # joined. Runs as root so it can read the DM-provisioner's (DynamicUser)
    # marker and restart hookshot to pick the room up.
    systemd.services."matrix-hookshot-adminroom" = mkAdminRoomService {
      bot = "hookshot";
      inherit dmMarker;
      asTokenPath = config.sops.secrets.hookshot_as_token.path;
      bridgeService = "matrix-hookshot.service";
      dmService = "matrix-dm-hookshot.service";
      stateDirectory = adminRoomStateDir;
      # The DM keeps its admin-room powers either way; it only surrenders the
      # notification feed when a dedicated room claims it. `false` asserts the
      # feed OFF (so the single per-user watcher can't land here); `null` leaves
      # the toggle unmanaged, so the DM stays the feed's home as it always was.
      notifications = if notificationsRoom.enable then false else null;
    };

    # The dedicated notifications room (hookshot-notifications-room.nix) is marked
    # by the SAME builder, pointed at that room's persisted id instead of the DM
    # marker — and it is the one instance that asserts the feed ON.
    systemd.services."matrix-hookshot-notifications-adminroom" =
      lib.mkIf notificationsRoom.enable
        (mkAdminRoomService {
          bot = "hookshot";
          label = "notifications room";
          notifications = true;
          dmMarker = notificationsRoom.roomIdFile;
          asTokenPath = config.sops.secrets.hookshot_as_token.path;
          bridgeService = "matrix-hookshot.service";
          dmService = "matrix-hookshot-notifications-room.service";
          # Both instances restart the bridge; serialise them.
          extraAfter = [ "matrix-hookshot-adminroom.service" ];
          stateDirectory = notificationsAdminRoomStateDir;
        });

    # Create a "Hookshot" Space grouping the @hookshot rooms (see hookshotSpace).
    # Runs as @inkpotmonkey (admin token), after the DM exists so m.direct resolves.
    systemd.services."matrix-hookshot-space" = {
      description = "Create the Hookshot Matrix Space and file the @hookshot DM under it";
      after = [
        "tuwunel.service"
        "tuwunel-register-admin.service"
        "matrix-dm-hookshot.service"
      ]
      # Order after the #infra-alerts room exists + admin is joined, so the
      # m.space.parent state event below can be set in it.
      ++ lib.optional config.custom.profiles.matrix.infraAlerts.enable "matrix-infra-alerts-room.service"
      # ...and after the notifications room, so its id marker exists to file it.
      ++ lib.optional notificationsRoom.enable "matrix-hookshot-notifications-room.service";
      requires = [ "tuwunel.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        DynamicUser = true;
        StateDirectory = "matrix-hookshot-space";
        StateDirectoryMode = "0700";
        LoadCredential = [ "admin_password:${config.sops.secrets.matrix_admin_password.path}" ];
        ExecStart = hookshotSpace;
      };
    };

    # Contribute to `matrix-reset`: the bridge service + its DM provisioner, and
    # the state dirs wiped for a from-scratch start (OAuth/passkey, and the marker).
    custom.profiles.matrix.resetState = [
      {
        service = "matrix-hookshot.service";
        paths = [ stateDir ];
        # What a wipe actually leaves for the operator. NOT `github login`: the
        # notification feed's credential is stored from sops by
        # matrix-hookshot-github-token, and `github login` mints an App token,
        # which GET /notifications rejects outright — so the feed reprovisions
        # itself completely. Only the bot-command-driven connections are lost,
        # because those live in room state that went with the homeserver.
        postResetNote =
          "re-add any hookshot webhook/feed connections (send 'help' in the @hookshot DM — they are room state and were wiped)"
          + lib.optionalString notificationsRoom.enable "; the GitHub notification feed needs nothing — room, markers, stream position and credential are all reprovisioned"
          + ". `github login` is only needed for the repo/project commands, and only if the GitHub App is installed somewhere";
      }
      {
        service = "matrix-dm-hookshot.service";
        isDm = true;
        paths = [ "/var/lib/private/matrix-dm-hookshot" ];
      }
      {
        # Re-mark the (freshly re-provisioned) DM as an admin room after a wipe;
        # isDm so it runs in the post-bridge phase, ordered after matrix-dm-hookshot
        # by its After=. Restarts hookshot itself when it (re)writes the marker.
        service = "matrix-hookshot-adminroom.service";
        isDm = true;
        paths = [ "/var/lib/${adminRoomStateDir}" ];
      }
      {
        # Recreate the Hookshot Space after a wipe (its room id, like the DM, is
        # gone with the homeserver). isDm so it runs after matrix-dm-hookshot.
        service = "matrix-hookshot-space.service";
        isDm = true;
        paths = [ "/var/lib/private/matrix-hookshot-space" ];
      }
    ]
    ++ lib.optional notificationsRoom.enable {
      # The notifications room's own restart-once marker, on the same lifetime as
      # the room id it is keyed on (that id is wiped by the room module's entry).
      service = "matrix-hookshot-notifications-adminroom.service";
      isDm = true;
      paths = [ "/var/lib/${notificationsAdminRoomStateDir}" ];
    };

    # --- Persistence ---
    # passkey.pem encrypts the stored GitHub/OAuth tokens; lose it and every
    # logged-in connection must be re-authed. Persist the whole state dir. The DM
    # marker is persisted in lockstep with the homeserver (default.nix).
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = stateDir;
          inherit user;
          group = user;
          mode = "0750";
        }
        "/var/lib/private/matrix-dm-hookshot"
        # The admin-room "activated" marker — same lifetime as the DM marker so a
        # matrix-reset (new DM id) re-triggers the one-time hookshot restart.
        "/var/lib/${adminRoomStateDir}"
        # The Hookshot Space id marker — persisted so the Space isn't recreated
        # every boot; wiped with the homeserver on matrix-reset.
        "/var/lib/private/matrix-hookshot-space"
      ]
      ++ lib.optional notificationsRoom.enable {
        # Explicit, not a bare path: impermanence would otherwise create the source
        # dir root:root 0755 (warning on first deploy) and systemd won't tighten an
        # already-mounted dir to its 0700 StateDirectoryMode.
        directory = "/var/lib/${notificationsAdminRoomStateDir}";
        user = "root";
        group = "root";
        mode = "0700";
      };
    };
  };
}

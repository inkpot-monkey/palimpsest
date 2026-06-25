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
  '';

  # Work around a conduwuit/tuwunel gap: the homeserver doesn't stamp `is_direct`
  # onto DM invite m.room.member events, so hookshot never recognises the @hookshot
  # DM as an *admin room* — the only place `github login` / `github notifications
  # toggle` (personal-notification feed) etc. exist. Hookshot designates an admin
  # room by the bot's room account-data `uk.half-shot.matrix-hookshot.github.room`
  # carrying an admin_user (normally written from the is_direct invite, Bridge.ts).
  # We write it ourselves by masquerading as the bot with the appservice token,
  # then restart hookshot so it loads the room as an admin room on startup
  # (setUpAdminRoom). Idempotent: only writes + restarts when not already marked.
  adminRoomType = "uk.half-shot.matrix-hookshot.github.room";
  dmMarker = "/var/lib/private/matrix-dm-hookshot/dm-created";
  markAdminRoom = pkgs.writeShellScript "matrix-hookshot-adminroom" ''
    set -eu
    url="${homeserverUrl}"
    bot="@hookshot:${domain}"
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

    # Ensure the admin-room marker exists (idempotent write).
    cur="$(${pkgs.curl}/bin/curl -s "''${auth[@]}" \
      "$url/_matrix/client/v3/user/$botenc/rooms/$ridenc/account_data/${adminRoomType}?$q" \
      | ${pkgs.jq}/bin/jq -r '.admin_user // empty' 2>/dev/null || echo "")"
    if [ "$cur" != "$me" ]; then
      ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
        "$url/_matrix/client/v3/user/$botenc/rooms/$ridenc/account_data/${adminRoomType}?$q" \
        -H 'content-type: application/json' \
        -d "$(${pkgs.jq}/bin/jq -nc --arg u "$me" '{admin_user:$u}')"
      echo "hookshot-adminroom: wrote admin marker for $rid"
    fi

    # Hookshot only *loads* an admin room from this account-data on startup (the
    # is_direct invite path is what tuwunel breaks), so the marker existing isn't
    # enough — hookshot must have (re)started since it was set. Restart once per
    # room id, tracked in our (persisted) state, so a marker set after hookshot's
    # last start still takes effect, without restarting on every boot/deploy.
    act="$STATE_DIRECTORY/activated"
    if [ "$(cat "$act" 2>/dev/null || true)" = "$rid" ]; then
      echo "hookshot-adminroom: $rid already active as an admin room"
      exit 0
    fi
    echo "hookshot-adminroom: restarting hookshot to load admin room $rid"
    ${pkgs.systemd}/bin/systemctl restart matrix-hookshot.service
    printf '%s' "$rid" > "$act"
  '';
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

    # Mark that DM as a hookshot admin room (see markAdminRoom — works around the
    # tuwunel is_direct gap), after the DM exists and the bot has joined. Runs as
    # root so it can read the DM-provisioner's (DynamicUser) marker and restart
    # hookshot to pick the room up.
    systemd.services."matrix-hookshot-adminroom" = {
      description = "Mark the @hookshot management DM as a hookshot admin room";
      after = [
        "matrix-hookshot.service"
        "matrix-dm-hookshot.service"
      ];
      wants = [
        "matrix-hookshot.service"
        "matrix-dm-hookshot.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Records the room id we've restarted hookshot for, so we restart only when
        # the admin room is new — survives reboots (persisted below).
        StateDirectory = "matrix-hookshot-adminroom";
        StateDirectoryMode = "0700";
        LoadCredential = [ "as_token:${config.sops.secrets.hookshot_as_token.path}" ];
        ExecStart = markAdminRoom;
      };
    };

    # Create a "Hookshot" Space grouping the @hookshot rooms (see hookshotSpace).
    # Runs as @inkpotmonkey (admin token), after the DM exists so m.direct resolves.
    systemd.services."matrix-hookshot-space" = {
      description = "Create the Hookshot Matrix Space and file the @hookshot DM under it";
      after = [
        "tuwunel.service"
        "tuwunel-register-admin.service"
        "matrix-dm-hookshot.service"
      ];
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
        postResetNote = "re-add hookshot connections in the @hookshot DM (send '!hookshot help'; GitHub/webhook/feed subscriptions are stored as room state and were wiped)";
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
        paths = [ "/var/lib/matrix-hookshot-adminroom" ];
      }
      {
        # Recreate the Hookshot Space after a wipe (its room id, like the DM, is
        # gone with the homeserver). isDm so it runs after matrix-dm-hookshot.
        service = "matrix-hookshot-space.service";
        isDm = true;
        paths = [ "/var/lib/private/matrix-hookshot-space" ];
      }
    ];

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
        "/var/lib/matrix-hookshot-adminroom"
        # The Hookshot Space id marker — persisted so the Space isn't recreated
        # every boot; wiped with the homeserver on matrix-reset.
        "/var/lib/private/matrix-hookshot-space"
      ];
    };
  };
}

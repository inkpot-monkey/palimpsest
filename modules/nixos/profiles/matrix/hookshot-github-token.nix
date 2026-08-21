# Store the GitHub personal access token for the notification feed declaratively,
# instead of typing it into a Matrix room.
#
# WHY A PAT AT ALL. `github login` mints a GitHub *App* user-to-server token, and
# `GET /notifications` does not accept those — it "only supports authentication
# using a personal access token (classic)" with the `notifications` or `repo`
# scope (https://docs.github.com/en/rest/activity/notifications). An App token
# gets `Resource not accessible by integration` forever, and no App permission
# changes that; hookshot doesn't even request an OAuth scope, because for an App
# it would be meaningless. Hookshot's answer is the `github setpersonaltoken`
# admin command — which means pasting a credential into a room whose history is
# unencrypted. This module does the same write from sops instead.
#
# WHAT IT WRITES. `github setpersonaltoken` ends in UserTokenStore.storeUserToken,
# which sets the bot's GLOBAL account data
# `uk.half-shot.matrix-hookshot.github.password-store:<mxid>` to
#   { encrypted: [<base64 RSA-PKCS#1v15 of each 128-byte chunk>],
#     keyId: <md5 hex of passkey.pem>, algorithm: "rsa-pkcs1v15" }
# (src/tokens/mod.rs: MAX_TOKEN_PART_SIZE = 128, Pkcs1v15Encrypt, base64ct
# standard+padded; src/format_util.rs: hash_id = md5 hex). We reproduce exactly
# that with openssl, so hookshot reads it back through its own code path with no
# patching. Depending on that internal shape is the same tradeoff ADR-0017 already
# accepts for the generic-webhook provisioner.
#
# A running bridge only reads this at startup (the in-process `onNewToken` event is
# what the bot command relies on), so a write restarts hookshot once — the same
# rule as the admin-room state in hookshot-adminroom.nix.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  hookshotCfg = config.custom.profiles.matrix.hookshot;
  cfg = hookshotCfg.personalToken;

  domain = config.services.matrix-tuwunel.settings.global.server_name;
  adminLocalpart = config.custom.profiles.matrix.adminLocalpart;
  homeserverUrl = "http://${builtins.head config.services.matrix-tuwunel.settings.global.address}:${toString (builtins.head config.services.matrix-tuwunel.settings.global.port)}";

  stateDir = "matrix-hookshot-github-token";
  passFile = "/var/lib/matrix-hookshot/passkey.pem";
  accountDataType = "uk.half-shot.matrix-hookshot.github.password-store";

  # flake8's 79-column limit can't be met by a file whose constants are Nix store
  # paths — `${pkgs.systemd}/bin/systemctl` alone is over it. Everything else the
  # linter checks still applies.
  storeToken =
    pkgs.writers.writePython3 "matrix-hookshot-github-token" { flakeIgnore = [ "E501" ]; }
      ''
        """Mirror UserTokenStore.storeUserToken from sops, without the bot command."""

        import base64
        import hashlib
        import json
        import os
        import subprocess
        import sys
        import urllib.error
        import urllib.parse
        import urllib.request

        HS = "${homeserverUrl}"
        BOT = "@hookshot:${domain}"
        USER = "@${adminLocalpart}:${domain}"
        PASSKEY = "${passFile}"
        # src/tokens/mod.rs: static MAX_TOKEN_PART_SIZE: usize = 128
        CHUNK = 128
        OPENSSL = "${pkgs.openssl}/bin/openssl"


        def log(msg):
            print(f"hookshot-github-token: {msg}", flush=True)


        creds = os.environ["CREDENTIALS_DIRECTORY"]
        state = os.environ["STATE_DIRECTORY"]

        with open(os.path.join(creds, "token"), "rb") as fh:
            # sops files routinely carry a trailing newline; a token with \n in it
            # authenticates as nothing and the 401 is not obviously self-inflicted.
            token = fh.read().strip()
        if not token:
            log("secret is empty — nothing to store")
            sys.exit(1)

        with open(os.path.join(creds, "as_token")) as fh:
            as_token = fh.read().strip()

        try:
            with open(PASSKEY, "rb") as fh:
                passkey = fh.read()
        except FileNotFoundError:
            log(f"{PASSKEY} does not exist yet — hookshot has not run its preStart")
            sys.exit(1)

        # src/format_util.rs: hash_id = md5 hex, over the key read as a utf-8 string.
        key_id = hashlib.md5(passkey).hexdigest()

        # Re-encrypting produces different ciphertext every run (PKCS#1 v1.5 is
        # randomised), so idempotence is tracked on the INPUTS instead: same token and
        # same passkey => nothing to do. Keeps deploys from restarting the bridge.
        fingerprint = hashlib.sha256(token + b"\0" + key_id.encode()).hexdigest()
        stamp = os.path.join(state, "fingerprint")
        quoted_bot = urllib.parse.quote(BOT, safe="")
        data_key = urllib.parse.quote(f"${accountDataType}:{USER}", safe="")
        url = f"{HS}/_matrix/client/v3/user/{quoted_bot}/account_data/{data_key}?user_id={quoted_bot}"


        def request(method, target, body=None):
            req = urllib.request.Request(target, method=method)
            req.add_header("Authorization", f"Bearer {as_token}")
            if body is not None:
                req.add_header("Content-Type", "application/json")
                req.data = json.dumps(body).encode()
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    return resp.status, json.loads(resp.read() or b"{}")
            except urllib.error.HTTPError as err:
                try:
                    return err.code, json.loads(err.read() or b"{}")
                except ValueError:
                    return err.code, {}


        status, current = request("GET", url)
        stored_ok = status == 200 and current.get("keyId") == key_id and current.get("encrypted")
        if stored_ok and os.path.exists(stamp):
            with open(stamp) as fh:
                if fh.read().strip() == fingerprint:
                    log("token already stored and unchanged")
                    sys.exit(0)

        # Fail loudly at deploy time rather than leaving GitHubWatcher to log
        # "Resource not accessible by integration" every 15 seconds forever. Advisory
        # only: no network (a VM check, a boot before egress) must not block the write.
        try:
            probe = urllib.request.Request(
                "https://api.github.com/notifications?per_page=1",
                headers={
                    "Authorization": f"Bearer {token.decode()}",
                    "Accept": "application/vnd.github+json",
                },
            )
            with urllib.request.urlopen(probe, timeout=15) as resp:
                log(f"token can read /notifications (HTTP {resp.status})")
        except urllib.error.HTTPError as err:
            log(
                f"WARNING: this token cannot read /notifications (HTTP {err.code}). "
                "It must be a CLASSIC PAT with the `notifications` or `repo` scope — "
                "a GitHub App or fine-grained token cannot read that endpoint."
            )
        except OSError as err:
            log(f"could not reach api.github.com to validate the token ({err}); continuing")

        # src/tokens/mod.rs encrypt(): chunk the utf-8 BYTES, RSA PKCS#1 v1.5 each
        # chunk against the public half of passkey.pem, base64 (standard, padded).
        pub = subprocess.run(
            [OPENSSL, "rsa", "-pubout", "-outform", "PEM"],
            input=passkey,
            capture_output=True,
            check=True,
        ).stdout

        # openssl pkeyutl needs the key as a *file* and the plaintext on stdin, so the
        # public half (not secret) is staged in the 0700 StateDirectory. The token
        # itself only ever travels on a pipe — never argv, never a file.
        pub_path = os.path.join(state, "pubkey.pem")
        with open(pub_path, "wb") as fh:
            fh.write(pub)

        parts = []
        for offset in range(0, len(token), CHUNK):
            enc = subprocess.run(
                [
                    OPENSSL,
                    "pkeyutl",
                    "-encrypt",
                    "-pubin",
                    "-inkey",
                    pub_path,
                    "-pkeyopt",
                    "rsa_padding_mode:pkcs1",
                ],
                input=token[offset:offset + CHUNK],
                capture_output=True,
                check=True,
            )
            parts.append(base64.b64encode(enc.stdout).decode())

        status, _ = request(
            "PUT",
            url,
            {"encrypted": parts, "keyId": key_id, "algorithm": "rsa-pkcs1v15"},
        )
        if status != 200:
            log(f"failed to write the token account data (HTTP {status})")
            sys.exit(1)

        with open(stamp, "w") as fh:
            fh.write(fingerprint)
        os.chmod(stamp, 0o600)
        log(f"stored github token for {USER} ({len(parts)} part(s), keyId {key_id})")

        # A running bridge only loads this at startup.
        subprocess.run(
            ["${pkgs.systemd}/bin/systemctl", "restart", "matrix-hookshot.service"],
            check=True,
        )
        log("restarted hookshot to load the token")
      '';
in
{
  options.custom.profiles.matrix.hookshot.personalToken = {
    enable = lib.mkEnableOption ''
      storing the GitHub personal access token for the notification feed from
      sops, instead of running `github setpersonaltoken` in the admin room (which
      would leave the credential in that room's unencrypted history). Must be a
      CLASSIC PAT with the `notifications` or `repo` scope — `GET /notifications`
      rejects GitHub App and fine-grained tokens outright, which is why the
      `github login` OAuth flow cannot drive the feed
    '';

    secretName = lib.mkOption {
      type = lib.types.str;
      default = "hookshot_github_personal_token";
      description = "sops secret holding the classic PAT.";
    };

    sopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression ''self.lib.getSecretFile "matrix"'';
      description = ''
        Which sops file `secretName` lives in, when this module should declare the
        secret itself. Leave null to REFERENCE a secret another module already
        declares (the fleet's `github_token` is declared by nixConfig.nix, and
        redeclaring its sopsFile here would just be a second place to keep in
        sync). Either way this module adds itself to the secret's restartUnits, so
        a rotation still lands.
      '';
    };
  };

  config = lib.mkIf (hookshotCfg.enable && cfg.enable) {
    assertions = [
      {
        assertion = cfg.sopsFile != null || config.sops.secrets ? ${cfg.secretName};
        message = ''
          custom.profiles.matrix.hookshot.personalToken.secretName is "${cfg.secretName}",
          which no module declares. Either set personalToken.sopsFile so this module
          declares it, or enable the profile that owns it.
        '';
      }
    ];

    sops.secrets.${cfg.secretName} =
      # Only claim ownership of the secret when told which file it is in; otherwise
      # just attach to whoever declared it.
      lib.optionalAttrs (cfg.sopsFile != null) { inherit (cfg) sopsFile; } // {
        restartUnits = [ "matrix-hookshot-github-token.service" ];
      };

    systemd.services.matrix-hookshot-github-token = {
      description = "Store the GitHub personal access token in hookshot's token store";
      # after+wants, never before/requires: it restarts hookshot, and it needs the
      # passkey that hookshot's preStart generates.
      after = [ "matrix-hookshot.service" ];
      wants = [ "matrix-hookshot.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = stateDir;
        StateDirectoryMode = "0700";
        LoadCredential = [
          "token:${config.sops.secrets.${cfg.secretName}.path}"
          "as_token:${config.sops.secrets.hookshot_as_token.path}"
        ];
        ExecStart = storeToken;
      };
    };

    # Contribute to `matrix-reset`: the token account data lives on the homeserver,
    # so a wipe takes it with it and the fingerprint must go too or we'd skip the
    # rewrite. isDm so it runs in the post-bridge phase.
    custom.profiles.matrix.resetState = [
      {
        service = "matrix-hookshot-github-token.service";
        isDm = true;
        paths = [ "/var/lib/${stateDir}" ];
      }
    ];

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = "/var/lib/${stateDir}";
          user = "root";
          group = "root";
          mode = "0700";
        }
      ];
    };
  };
}

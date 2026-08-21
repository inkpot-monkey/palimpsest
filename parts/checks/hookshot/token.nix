{
  self,
  pkgs,
  ...
}:

# VM check for the declarative GitHub token store
# (modules/nixos/profiles/matrix/hookshot-github-token.nix).
#
# The module reimplements hookshot's own UserTokenStore.storeUserToken against a
# format that lives in hookshot's Rust source, not in any API: 128-byte chunks,
# RSA PKCS#1 v1.5, base64, plus an md5-of-the-passkey keyId. If any of that drifts,
# hookshot reads the account data back, fails to decrypt, and reports no token —
# which looks exactly like "you never logged in". So the check does not inspect the
# shape and call it a day: it DECRYPTS what the unit wrote, with openssl and the
# real private key, and asserts the plaintext is the value that went in.
#
# The bridge is a stub — it exists to have a key generated and its restarts
# counted, which is all the unit interacts with. The fixture "tokens" are obvious
# non-credentials on purpose; nothing here is or resembles a real secret.

let
  serverName = "tokentest.test";
  port = 6167;
  url = "http://127.0.0.1:${toString port}";
  admin = "admin";
  bot = "hookshot";
  asToken = "test-as-token";
  hsToken = "test-hs-token";
  asPort = 9993;

  keyFile = "/var/lib/matrix-hookshot/passkey.pem";
  # Writable on purpose: the rotation step rewrites it in place, which an
  # environment.etc entry (a symlink into the read-only store) cannot do.
  secretFile = "/run/hookshot-github-token";
  accountDataType = "uk.half-shot.matrix-hookshot.github.password-store";

  # A classic PAT is 40 bytes, i.e. exactly one chunk. The rotation step uses a
  # long value to exercise the >128-byte chunking path a real one never reaches.
  fixtureShort = "not-a-real-token-0000000000000000000000";
  fixtureLong =
    "not-a-real-token-" + builtins.concatStringsSep "" (builtins.genList (_: "0123456789") 30);

  registration = pkgs.writeText "hookshot-registration.yaml" ''
    id: hookshot
    url: http://127.0.0.1:${toString asPort}
    as_token: ${asToken}
    hs_token: ${hsToken}
    sender_localpart: ${bot}
    rate_limited: false
    namespaces:
      users:
        - exclusive: true
          regex: '@_github_.*'
      aliases: []
      rooms: []
  '';

  asSink = pkgs.writers.writePython3 "as-sink" { } ''
    from http.server import BaseHTTPRequestHandler, HTTPServer


    class H(BaseHTTPRequestHandler):
        def _ok(self):
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b"{}")

        do_GET = do_PUT = do_POST = _ok

        def log_message(self, *args):
            pass


    HTTPServer(("127.0.0.1", ${toString asPort}), H).serve_forever()
  '';

  # Reads back what the unit wrote and decrypts it the way hookshot does: base64 ->
  # RSA PKCS#1 v1.5 with the private key -> concatenate the per-chunk plaintexts.
  decrypt = pkgs.writeShellScript "decrypt-stored-value" ''
    set -eu
    bot="@${bot}:${serverName}"
    botenc="$(${pkgs.jq}/bin/jq -rn --arg b "$bot" '$b|@uri')"
    key="$(${pkgs.jq}/bin/jq -rn --arg s "${accountDataType}:@${admin}:${serverName}" '$s|@uri')"
    data="$(${pkgs.curl}/bin/curl -s -H "Authorization: Bearer ${asToken}" \
      "${url}/_matrix/client/v3/user/$botenc/account_data/$key?user_id=$botenc")"
    n="$(${pkgs.jq}/bin/jq -r '.encrypted | length' <<<"$data")"
    for i in $(seq 0 $((n - 1))); do
      ${pkgs.jq}/bin/jq -r --argjson i "$i" '.encrypted[$i]' <<<"$data" \
        | ${pkgs.coreutils}/bin/base64 -d \
        | ${pkgs.openssl}/bin/openssl pkeyutl -decrypt -inkey ${keyFile} \
            -pkeyopt rsa_padding_mode:pkcs1
    done
  '';
in
pkgs.testers.nixosTest {
  name = "matrix-hookshot-github-token";

  nodes.machine =
    {
      lib,
      pkgs,
      ...
    }:
    {
      imports = [ (self + /modules/nixos/profiles/matrix/hookshot-github-token.nix) ];

      options = {
        custom.profiles.matrix.adminLocalpart = lib.mkOption {
          type = lib.types.str;
          default = admin;
        };
        custom.profiles.matrix.hookshot.enable = lib.mkEnableOption "hookshot (stub)";
        # The module chains its ordering off this; it is declared by the sibling
        # notifications-room module, which this check has no reason to stand up.
        custom.profiles.matrix.hookshot.notificationsRoom.enable =
          lib.mkEnableOption "notifications room (stub)";
        custom.profiles.matrix.resetState = lib.mkOption {
          type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
          default = [ ];
        };
        custom.profiles.impermanence.enable = lib.mkEnableOption "impermanence (stub)";
        environment.persistence = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        # Enough of sops-nix's surface for the module to declare its secret.
        sops.secrets = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, ... }:
              {
                options = {
                  path = lib.mkOption {
                    type = lib.types.str;
                    default = "/etc/sops-${name}";
                  };
                  sopsFile = lib.mkOption {
                    type = lib.types.nullOr lib.types.path;
                    default = null;
                  };
                  restartUnits = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                  };
                };
              }
            )
          );
        };
      };

      config = {
        environment.systemPackages = [
          pkgs.curl
          pkgs.jq
          pkgs.openssl
        ];

        services.matrix-tuwunel = {
          enable = true;
          settings.global = {
            server_name = serverName;
            address = [ "127.0.0.1" ];
            port = [ port ];
            allow_federation = false;
            allow_registration = true;
            # tuwunel refuses to start with open registration and no token, even
            # though the only account this check creates is the appservice bot.
            registration_token_file = "/etc/tuwunel-reg-token";
            grant_admin_to_first_user = true;
            appservice_dir = "/etc/tuwunel-appservices/";
          };
        };
        environment.etc."tuwunel-appservices/hookshot-registration.yaml".source = registration;
        environment.etc."tuwunel-reg-token".text = "test-reg-token";

        sops.secrets.hookshot_as_token.path = "/etc/hookshot-as-token";
        environment.etc."hookshot-as-token".text = asToken;
        # Stands in for the sops-rendered file, down to the trailing newline sops
        # emits — a value carrying it authenticates as nothing, so the unit has to
        # strip it. The test rewrites this file to simulate a rotation.
        systemd.services.seed-token-secret = {
          wantedBy = [ "multi-user.target" ];
          before = [ "matrix-hookshot-github-token.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "seed-token-secret" ''
              printf '%s\n' ${lib.escapeShellArg fixtureShort} > ${secretFile}
              chmod 0400 ${secretFile}
            '';
          };
        };

        systemd.services.hookshot-as-sink = {
          wantedBy = [ "multi-user.target" ];
          before = [ "tuwunel.service" ];
          serviceConfig.ExecStart = asSink;
        };

        # Stub bridge: generates the encryption key in its preStart exactly as the
        # real nixpkgs module does, and records every start so restarts are countable.
        systemd.services.matrix-hookshot = {
          description = "stub matrix-hookshot";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StateDirectory = "matrix-hookshot";
            ExecStartPre = pkgs.writeShellScript "stub-genkey" ''
              [ -f ${keyFile} ] || ${pkgs.openssl}/bin/openssl genrsa -out ${keyFile} 4096
            '';
            ExecStart = pkgs.writeShellScript "stub-bridge-start" ''
              echo start >> /var/lib/hookshot-starts
            '';
          };
        };

        custom.profiles.matrix.hookshot = {
          enable = true;
          personalToken = {
            enable = true;
            secretName = "hookshot_github_personal_token";
          };
        };
        sops.secrets.hookshot_github_personal_token.path = secretFile;
        # Driven explicitly by the test, not at boot.
        systemd.services.matrix-hookshot-github-token.wantedBy = lib.mkForce [ ];
      };
    };

  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("tuwunel.service")
    machine.wait_until_succeeds("curl -sf ${url}/_matrix/client/versions", timeout=60)
    machine.succeed("systemctl start matrix-hookshot.service")

    # Register the appservice bot; the unit writes account data as it. Surfaced
    # rather than -sf'd away: a rejection here is a homeserver/registration
    # mismatch, and "exit code 22" on its own says nothing about which.
    reg = machine.succeed(
        "curl -s -w '\\n%{http_code}' -X POST ${url}/_matrix/client/v3/register"
        " -H 'authorization: Bearer ${asToken}' -H 'content-type: application/json'"
        " -d '{\"type\":\"m.login.application_service\",\"username\":\"${bot}\"}'"
    ).strip().splitlines()
    assert reg[-1] in ("200", "400"), f"appservice registration rejected: {reg}"
    print(f"appservice bot registration -> HTTP {reg[-1]} {reg[0][:120]}")

    def stored():
        bot_enc = machine.succeed(
            "jq -rn --arg s '@${bot}:${serverName}' '$s|@uri'"
        ).strip()
        key = machine.succeed(
            "jq -rn --arg s '${accountDataType}:@${admin}:${serverName}' '$s|@uri'"
        ).strip()
        return json.loads(machine.succeed(
            f"curl -s -H 'Authorization: Bearer ${asToken}'"
            f" '${url}/_matrix/client/v3/user/{bot_enc}/account_data/{key}?user_id={bot_enc}'"
        ))

    def starts():
        return int(machine.succeed("wc -l < /var/lib/hookshot-starts || echo 0").strip())

    def key_id():
        return machine.succeed("md5sum ${keyFile} | cut -d' ' -f1").strip()

    before = starts()

    # --- First run ------------------------------------------------------------
    machine.succeed("systemctl start matrix-hookshot-github-token.service")
    data = stored()
    assert data.get("algorithm") == "rsa-pkcs1v15", f"wrong algorithm: {data}"
    assert data.get("keyId") == key_id(), f"keyId is not md5 of the key file: {data.get('keyId')}"
    assert len(data.get("encrypted", [])) == 1, f"expected one chunk: {data}"
    #     The assertion that actually matters: hookshot's own decrypt path, run for
    #     real. A shape that looks right but decrypts to nothing is the failure mode.
    #     This also proves the sops trailing newline was stripped, not encrypted in.
    assert machine.succeed("${decrypt}") == "${fixtureShort}", "stored value does not decrypt to the input"
    assert starts() == before + 1, "bridge not restarted to load the new value"
    print("OK: stored, decrypts to the input, trailing newline stripped, bridge restarted")

    # --- Idempotent -----------------------------------------------------------
    ciphertext = stored()["encrypted"]
    machine.succeed("systemctl restart matrix-hookshot-github-token.service")
    machine.succeed(
        "journalctl -u matrix-hookshot-github-token.service | grep -q 'already stored and unchanged'"
    )
    assert stored()["encrypted"] == ciphertext, "rewrote an unchanged value"
    assert starts() == before + 1, "restarted the bridge with nothing to write"
    print("OK: unchanged input is a no-op (PKCS#1 v1.5 is randomised, so this must key on inputs)")

    # --- Rotated value, long enough to exercise chunking ----------------------
    machine.succeed(
        "install -m 0400 /dev/null ${secretFile}"
        " && printf '%s\\n' '${fixtureLong}' > ${secretFile}"
    )
    machine.succeed("systemctl restart matrix-hookshot-github-token.service")
    data = stored()
    expected_chunks = (len("${fixtureLong}") + 127) // 128
    assert len(data["encrypted"]) == expected_chunks, f"expected {expected_chunks} chunks: {data}"
    assert machine.succeed("${decrypt}") == "${fixtureLong}", "rotated value does not decrypt to the new one"
    assert starts() == before + 2, "bridge not restarted after a rotation"
    print(f"OK: rotated {len('${fixtureLong}')}-byte value re-encrypted into {expected_chunks} chunks, decrypts")

    # --- Rotated encryption key -----------------------------------------------
    #     A new key means every stored value is undecryptable. The keyId must follow
    #     it, or hookshot reports "no token" instead of a key mismatch.
    machine.succeed("rm -f ${keyFile}")
    machine.succeed("systemctl restart matrix-hookshot.service")
    new_key = key_id()
    assert new_key != data["keyId"], "the key file did not actually rotate"
    machine.succeed("systemctl restart matrix-hookshot-github-token.service")
    assert stored()["keyId"] == new_key, "keyId did not follow the key file"
    assert machine.succeed("${decrypt}") == "${fixtureLong}", "not re-encrypted under the new key"
    print("OK: key rotation re-encrypts and re-stamps the keyId")
  '';
}

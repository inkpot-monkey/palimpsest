{
  self,
  pkgs,
  ...
}:

# VM check for the per-bridge management-DM provisioner
# (modules/nixos/profiles/matrix/dm-provision.nix). Exercises the REAL builder
# against a minimal tuwunel: it creates an is_direct room, invites the bot, sets
# m.direct, sends a welcome to UNENCRYPTED rooms (and skips it for encrypted),
# and is idempotent via a persisted marker. The test plays the bridge bot by
# joining the invite (the real bot's auto-join is the bridge's own behaviour,
# out of scope here).

let
  serverName = "dmtest.test";
  port = 6167;
  url = "http://127.0.0.1:${toString port}";
  regToken = "test-reg-token";
  admin = "admin";
  adminPass = "adminpass";

  helpers = pkgs.writeText "mx-helpers.sh" ''
    set -eu
    URL="${url}"
    TOKEN="${regToken}"

    mx_register() { # localpart password
      s=$(curl -s -X POST "$URL/_matrix/client/v3/register" -H 'content-type: application/json' \
        -d "$(jq -nc --arg u "$1" --arg p "$2" '{username:$u,password:$p,inhibit_login:true}')" \
        | jq -r '.session // empty')
      [ -n "$s" ] || { echo "no UIA session for $1" >&2; return 1; }
      code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/_matrix/client/v3/register" \
        -H 'content-type: application/json' \
        -d "$(jq -nc --arg u "$1" --arg p "$2" --arg t "$TOKEN" --arg s "$s" \
          '{username:$u,password:$p,inhibit_login:true,auth:{type:"m.login.registration_token",token:$t,session:$s}}')")
      [ "$code" = "200" ] || { echo "register $1 -> HTTP $code" >&2; return 1; }
    }

    mx_login() { # localpart password -> token
      curl -s -X POST "$URL/_matrix/client/v3/login" -H 'content-type: application/json' \
        -d "$(jq -nc --arg u "$1" --arg p "$2" \
          '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')" \
        | jq -r '.access_token'
    }

    mx_invited() { # token -> invited room ids
      curl -s "$URL/_matrix/client/v3/sync?timeout=0" -H "authorization: Bearer $1" \
        | jq -r '.rooms.invite // {} | keys[]'
    }

    mx_join() { # token room
      curl -sf -o /dev/null -X POST "$URL/_matrix/client/v3/join/$2" \
        -H "authorization: Bearer $1" -H 'content-type: application/json' -d '{}'
    }

    mx_joined() { # token room -> joined mxids
      curl -s "$URL/_matrix/client/v3/rooms/$2/joined_members" \
        -H "authorization: Bearer $1" | jq -r '.joined // {} | keys[]'
    }

    mx_texts() { # token room -> "sender\tbody"
      curl -s "$URL/_matrix/client/v3/rooms/$2/messages?dir=b&limit=50" \
        -H "authorization: Bearer $1" \
        | jq -r '.chunk[] | select(.type=="m.room.message") | "\(.sender)\t\(.content.body)"'
    }

    mx_mdirect() { # token localpart -> m.direct account data (raw json)
      curl -s "$URL/_matrix/client/v3/user/@$2:${serverName}/account_data/m.direct" \
        -H "authorization: Bearer $1"
    }

    mx_tags() { # token localpart room -> tag keys
      curl -s "$URL/_matrix/client/v3/user/@$2:${serverName}/rooms/$3/tags" \
        -H "authorization: Bearer $1" | jq -r '.tags // {} | keys[]'
    }

    mx_untag() { # token localpart room tag -> delete a room tag
      curl -s -o /dev/null -X DELETE \
        "$URL/_matrix/client/v3/user/@$2:${serverName}/rooms/$3/tags/$4" \
        -H "authorization: Bearer $1"
    }

    mx_encryption() { # token room -> algorithm or empty
      curl -s "$URL/_matrix/client/v3/rooms/$2/state/m.room.encryption" \
        -H "authorization: Bearer $1" | jq -r '.algorithm // empty'
    }
  '';
in
pkgs.testers.nixosTest {
  name = "matrix-dm-provision";

  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # The REAL builder, bound to this node's config.
      mkDm = import (self + /modules/nixos/profiles/matrix/dm-provision.nix) {
        inherit pkgs config;
      };
      # Provisioner service + don't auto-run at boot (the test drives it once the
      # admin/bot accounts exist).
      dmService =
        args:
        lib.mkMerge [
          (mkDm args)
          { wantedBy = lib.mkForce [ ]; }
        ];
    in
    {
      options = {
        # The one profile option dm-provision.nix reads; declared here so we don't
        # need to import the whole matrix profile.
        custom.profiles.matrix.adminLocalpart = lib.mkOption {
          type = lib.types.str;
          default = admin;
        };
        # Minimal stand-in for sops-nix's secrets surface — just the `.path` that
        # dm-provision.nix references, so no sops machinery runs in the VM.
        sops.secrets = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (
            lib.types.submodule { options.path = lib.mkOption { type = lib.types.str; }; }
          );
        };
      };

      config = {
        environment.systemPackages = [
          pkgs.curl
          pkgs.jq
        ];

        services.matrix-tuwunel = {
          enable = true;
          settings.global = {
            server_name = serverName;
            address = [ "127.0.0.1" ];
            port = [ port ];
            allow_federation = false;
            allow_registration = true;
            registration_token_file = "/etc/tuwunel-reg-token";
            grant_admin_to_first_user = true;
          };
        };
        environment.etc."tuwunel-reg-token".text = regToken;

        # Admin password the provisioner logs in with (no sops in the VM).
        sops.secrets.matrix_admin_password.path = "/etc/admin-pw";
        environment.etc."admin-pw".text = adminPass;

        # dm-provision requires this unit; stub it (the test registers admin itself).
        systemd.services.tuwunel-register-admin = {
          description = "stub register-admin (test registers via API)";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

        # Unencrypted DM with a welcome, and an encrypted DM (welcome must be skipped).
        # The shared m.direct serialization lock the matrix profile normally
        # provides (matrix/default.nix); needed here so the two provisioners don't
        # race the m.direct read-modify-write.
        systemd.tmpfiles.rules = [ "f /run/matrix-dm-mdirect.lock 0666 root root -" ];

        systemd.services."matrix-dm-testbot-u" = dmService {
          bot = "testbot-u";
          afterUnit = "tuwunel.service";
          welcomeCommand = "help-u";
        };
        systemd.services."matrix-dm-testbot-e" = dmService {
          bot = "testbot-e";
          afterUnit = "tuwunel.service";
          encrypted = true;
          welcomeCommand = "help-e";
          topic = "encrypted admin room";
        };
      };
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("tuwunel.service")
    machine.wait_for_open_port(${toString port})
    machine.wait_until_succeeds("curl -sf ${url}/_matrix/client/versions", timeout=60)

    H = ". ${helpers}"
    def sh(cmd):
        return machine.succeed(f"{H}; {cmd}").strip()

    sh("mx_register ${admin} ${adminPass}")
    sh("mx_register testbot-u botpass")
    sh("mx_register testbot-e botpass")
    admin_tok = sh("mx_login ${admin} ${adminPass}")
    bu = sh("mx_login testbot-u botpass")
    be = sh("mx_login testbot-e botpass")

    # Run the provisioners without blocking (they wait for the bot to join).
    machine.succeed("systemctl start --no-block matrix-dm-testbot-u.service")
    machine.succeed("systemctl start --no-block matrix-dm-testbot-e.service")

    def wait_join(tok):
        for _ in range(60):
            inv = sh(f"mx_invited {tok}").split()
            if inv:
                sh(f"mx_join {tok} {inv[0]}")
                return inv[0]
            machine.sleep(1)
        raise Exception("no invite")

    room_u = wait_join(bu)
    room_e = wait_join(be)

    machine.wait_until_succeeds("systemctl is-active matrix-dm-testbot-u.service", timeout=60)
    machine.wait_until_succeeds("systemctl is-active matrix-dm-testbot-e.service", timeout=60)

    # Unencrypted: bot joined, m.direct set, welcome sent.
    assert "@testbot-u:${serverName}" in sh(f"mx_joined {admin_tok} {room_u}"), "bot not joined (u)"
    assert room_u in sh(f"mx_mdirect {admin_tok} ${admin}"), "m.direct missing room_u"
    machine.wait_until_succeeds(
        f"{H}; mx_texts {admin_tok} {room_u} | grep -F 'help-u'", timeout=30
    )
    assert "m.favourite" in sh(f"mx_tags {admin_tok} ${admin} {room_u}"), "room_u not favourited"
    print("OK: unencrypted DM — joined, m.direct, welcome sent, favourited")

    # Encrypted: bot joined, encryption on, welcome SKIPPED.
    assert "@testbot-e:${serverName}" in sh(f"mx_joined {admin_tok} {room_e}"), "bot not joined (e)"
    assert sh(f"mx_encryption {admin_tok} {room_e}") == "m.megolm.v1.aes-sha2", "room_e not encrypted"
    machine.sleep(5)
    assert "help-e" not in sh(f"mx_texts {admin_tok} {room_e}"), "welcome leaked into encrypted room!"
    assert "m.favourite" in sh(f"mx_tags {admin_tok} ${admin} {room_e}"), "room_e not favourited"
    print("OK: encrypted DM — joined, encrypted, welcome skipped, favourited")

    # Idempotency: re-run creates no second room (persisted marker)...
    machine.succeed("systemctl restart matrix-dm-testbot-u.service")
    machine.wait_until_succeeds("systemctl is-active matrix-dm-testbot-u.service", timeout=30)
    machine.succeed("journalctl -u matrix-dm-testbot-u.service | grep -q 'already created'")
    # ...but the favourite is re-asserted even when the DM already exists: drop the
    # tag, restart, confirm it returns (the gap that only-on-creation favouriting had).
    sh(f"mx_untag {admin_tok} ${admin} {room_u} m.favourite")
    assert "m.favourite" not in sh(f"mx_tags {admin_tok} ${admin} {room_u}"), "untag failed"
    machine.succeed("systemctl restart matrix-dm-testbot-u.service")
    machine.wait_until_succeeds(
        f"{H}; mx_tags {admin_tok} ${admin} {room_u} | grep -qx m.favourite", timeout=30
    )
    print("OK: idempotent re-run; favourite re-applied on an existing DM")
  '';
}

{
  self,
  pkgs,
  ...
}:

# VM check for the hermes Matrix bot + its per-job rooms
# (modules/nixos/profiles/matrix/hermes-rooms.nix), run against a REAL tuwunel.
#
# WHY A VM AND NOT AN EVAL. Everything that can go wrong here goes wrong at the
# homeserver, not in Nix: an account that silently already exists, a createRoom
# rejected by a room-version rule, a bot that is invited but never joins (and so
# cannot be delivered to), a marker that outlives the room it names. Each of those
# leaves a GREEN unit and a job that delivers nowhere — the exact failure shape
# #infra-alerts was refactored to stop having. So the script runs for real.
#
# The five properties, each one a way the per-job channel silently stops working:
#
#   1. the bot ACCOUNT exists and its password is the one rk1b will log in with;
#   2. a declared room exists, named and topic'd, and the BOT IS JOINED — an invite
#      it never accepted is indistinguishable from a working room until a job runs;
#   3. re-running creates no second room (persisted marker);
#   4. a marker naming a room the homeserver no longer has is REPLACED, not trusted
#      — that is what a matrix-reset leaves behind;
#   5. a room created elsewhere (#infra-alerts, whose id this module never owns) is
#      joined from its id file, which is what makes --failure-deliver land.

let
  serverName = "hermestest.test";
  port = 6167;
  url = "http://127.0.0.1:${toString port}";
  regToken = "test-reg-token";
  admin = "admin";
  adminPass = "adminpass";
  botPass = "hermespass";

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
        | jq -r '.access_token // empty'
    }

    mx_create() { # token name -> room id (private room, no invites)
      curl -s -X POST "$URL/_matrix/client/v3/createRoom" \
        -H "authorization: Bearer $1" -H 'content-type: application/json' \
        -d "$(jq -nc --arg n "$2" '{name:$n,preset:"private_chat"}')" | jq -r '.room_id // empty'
    }

    mx_invite() { # token room mxid
      curl -s -o /dev/null -X POST "$URL/_matrix/client/v3/rooms/$2/invite" \
        -H "authorization: Bearer $1" -H 'content-type: application/json' \
        -d "$(jq -nc --arg u "$3" '{user_id:$u}')"
    }

    mx_joined() { # token room -> joined mxids
      curl -s "$URL/_matrix/client/v3/rooms/$2/joined_members" \
        -H "authorization: Bearer $1" | jq -r '.joined // {} | keys[]'
    }

    mx_room_name() { # token room -> name
      curl -s "$URL/_matrix/client/v3/rooms/$2/state/m.room.name" \
        -H "authorization: Bearer $1" | jq -r '.name // empty'
    }

    mx_topic() { # token room -> topic
      curl -s "$URL/_matrix/client/v3/rooms/$2/state/m.room.topic" \
        -H "authorization: Bearer $1" | jq -r '.topic // empty'
    }

    mx_tags() { # token localpart room -> tag keys
      curl -s "$URL/_matrix/client/v3/user/@$2:${serverName}/rooms/$3/tags" \
        -H "authorization: Bearer $1" | jq -r '.tags // {} | keys[]'
    }

    mx_send() { # token room body -> event id
      curl -s -X PUT "$URL/_matrix/client/v3/rooms/$2/send/m.room.message/$(date +%s%N)" \
        -H "authorization: Bearer $1" -H 'content-type: application/json' \
        -d "$(jq -nc --arg b "$3" '{msgtype:"m.text",body:$b}')" | jq -r '.event_id // empty'
    }
  '';
in
pkgs.testers.nixosTest {
  name = "matrix-hermes-rooms";

  nodes.machine =
    {
      lib,
      pkgs,
      ...
    }:
    {
      imports = [ (self + /modules/nixos/profiles/matrix/hermes-rooms.nix) ];

      options = {
        # The parent profile's options this module reads or contributes to, declared
        # here so the test does not have to pull in the whole matrix profile (and its
        # bridges) to exercise one oneshot.
        custom.profiles.matrix.adminLocalpart = lib.mkOption {
          type = lib.types.str;
          default = admin;
        };
        custom.profiles.matrix.resetState = lib.mkOption {
          type = lib.types.listOf lib.types.attrs;
          default = [ ];
        };
        custom.profiles.impermanence.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        environment.persistence = lib.mkOption {
          type = lib.types.attrsOf lib.types.attrs;
          default = { };
        };
        # Minimal stand-in for sops-nix's secrets surface — just the `.path` the
        # module references, so no sops machinery runs in the VM.
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

        sops.secrets.matrix_admin_password.path = "/etc/admin-pw";
        sops.secrets.registration_token.path = "/etc/tuwunel-reg-token";
        sops.secrets.hermes_bot_password.path = "/etc/hermes-pw";
        environment.etc."admin-pw".text = adminPass;
        environment.etc."hermes-pw".text = botPass;

        # The module requires this unit; stub it (the test registers admin itself,
        # exactly as the dm-provision check does).
        systemd.services.tuwunel-register-admin = {
          description = "stub register-admin (test registers via API)";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

        custom.profiles.matrix.hermesRooms = {
          enable = true;
          rooms."property-watch" = {
            name = "Property Watch";
            topic = "Daily SE London property search";
          };
          # Stands in for #infra-alerts: a room this module does not own, whose id
          # arrives in a file written by the unit that does.
          joinRoomIdFiles = [ "/run/extra-room-id" ];
        };

        # Don't run at boot — the test drives it once the admin account exists.
        systemd.services.matrix-hermes-rooms.wantedBy = lib.mkForce [ ];
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
    admin_tok = sh("mx_login ${admin} ${adminPass}")

    # A room this module does not create, standing in for #infra-alerts.
    extra = sh(f"mx_create {admin_tok} 'Infra Alerts'")
    assert extra, "could not create the stand-in infra-alerts room"
    sh(f"mx_invite {admin_tok} {extra} @hermes:${serverName}")
    machine.succeed(f"printf '%s' {extra} > /run/extra-room-id")

    machine.succeed("systemctl start matrix-hermes-rooms.service")

    marker = "/var/lib/matrix-hermes-rooms/property-watch.room-id"

    # 1. The account exists and the password is the one rk1b will log in with.
    bot_tok = sh("mx_login hermes ${botPass}")
    assert bot_tok, "the hermes bot account cannot log in with its sops password"
    print("OK: bot account registered")

    # 2. The declared room exists, is named and topic'd, and the BOT IS JOINED.
    room = machine.succeed(f"cat {marker}").strip()
    assert room.startswith("!"), f"no room id marker: {room!r}"
    assert "@hermes:${serverName}" in sh(f"mx_joined {admin_tok} {room}"), "bot not joined"
    assert sh(f"mx_room_name {admin_tok} {room}") == "Property Watch", "room name not set"
    assert sh(f"mx_topic {admin_tok} {room}") == "Daily SE London property search", "topic not set"
    assert "m.favourite" in sh(f"mx_tags {admin_tok} ${admin} {room}"), "room not favourited"
    # A joined bot can actually post — which is the whole point of the channel.
    assert sh(f"mx_send {bot_tok} {room} hello"), "the bot cannot post into its own room"
    print("OK: room created, named, joined, postable")

    # 5. The room it does NOT own is joined from its id file (--failure-deliver).
    assert "@hermes:${serverName}" in sh(f"mx_joined {admin_tok} {extra}"), \
        "bot not joined to the room named by joinRoomIdFiles"
    print("OK: joined the externally-created room")

    # 3. Idempotent: a second run reuses the room rather than creating another.
    machine.succeed("systemctl restart matrix-hermes-rooms.service")
    assert machine.succeed(f"cat {marker}").strip() == room, "a second run created a second room"
    print("OK: idempotent")

    # 4. A marker naming a room the homeserver no longer has is replaced, not trusted.
    machine.succeed(f"printf '%s' '!gone:${serverName}' > {marker}")
    machine.succeed("systemctl restart matrix-hermes-rooms.service")
    fresh = machine.succeed(f"cat {marker}").strip()
    assert fresh.startswith("!") and fresh != "!gone:${serverName}", \
        f"a dead room id was trusted: {fresh!r}"
    assert "@hermes:${serverName}" in sh(f"mx_joined {admin_tok} {fresh}"), "bot not joined to the rebuilt room"
    print("OK: a stale marker is replaced")
  '';
}

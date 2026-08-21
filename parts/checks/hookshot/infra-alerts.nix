{
  self,
  pkgs,
  ...
}:

# VM check for the #infra-alerts room + connection provisioner
# (modules/nixos/profiles/matrix/infra-alerts.nix).
#
# This module hid a four-week outage. The room was deleted by a matrix-reset, the
# roomId stayed pinned in config because a static connection needed it at build
# time, nothing re-provisioned it, and every curl in the oneshot is `|| true` — so
# it kept logging "ready in <room that no longer exists>" while every alerter on
# the fleet POSTed into a 404. The assertions below are aimed squarely at that:
#
#   - a pinned room id that does NOT resolve must be refused, not adopted
#   - a persisted marker whose room is gone must be refused, and a new room made
#   - the connection must be resolvable the way hookshot resolves it, i.e. the
#     bot's room account data must map some hookId to the state event's state key
#     (GenericHook.js: getHookId) — a state event alone is a hook that 404s
#
# The bridge is a stub: hookshot's consumption of the connection is upstream
# behaviour, and a real one would need a GitHub App to start.

let
  serverName = "infratest.test";
  port = 6167;
  url = "http://127.0.0.1:${toString port}";
  regToken = "test-reg-token";
  admin = "admin";
  adminPass = "adminpass";
  bot = "hookshot";
  asToken = "test-as-token";
  hsToken = "test-hs-token";
  asPort = 9993;

  hookId = "testhook00000000";
  # A room id that parses but has never existed — exactly the shape the dead pin
  # had on kelpy. The provisioner must decline to adopt it.
  deadPin = "!deadpin00000000:${serverName}";
  goneRoom = "!gone000000000000:${serverName}";

  connectionType = "uk.half-shot.matrix-hookshot.generic.hook";
  connectionName = "infra-alerts";
  markerFile = "/var/lib/matrix-infra-alerts/room-id";
  webhookUrlFile = "/var/lib/matrix-infra-alerts/webhook_url";

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
          regex: '@_webhooks_.*'
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

  helpers = pkgs.writeText "ia-helpers.sh" ''
    set -eu
    URL="${url}"
    AS="${asToken}"
    BOT="@${bot}:${serverName}"

    enc() { jq -rn --arg s "$1" '$s|@uri'; }

    mx_register() { # localpart password
      s=$(curl -s -X POST "$URL/_matrix/client/v3/register" -H 'content-type: application/json' \
        -d "$(jq -nc --arg u "$1" --arg p "$2" '{username:$u,password:$p,inhibit_login:true}')" \
        | jq -r '.session // empty')
      [ -n "$s" ] || { echo "no UIA session for $1" >&2; return 1; }
      curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/_matrix/client/v3/register" \
        -H 'content-type: application/json' \
        -d "$(jq -nc --arg u "$1" --arg p "$2" --arg t "${regToken}" --arg s "$s" \
          '{username:$u,password:$p,inhibit_login:true,auth:{type:"m.login.registration_token",token:$t,session:$s}}')"
    }

    mx_login() { # localpart password -> token
      curl -s -X POST "$URL/_matrix/client/v3/login" -H 'content-type: application/json' \
        -d "$(jq -nc --arg u "$1" --arg p "$2" \
          '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')" \
        | jq -r '.access_token'
    }

    mx_room_name() { # token room -> name
      curl -s "$URL/_matrix/client/v3/rooms/$(enc "$2")/state/m.room.name" \
        -H "authorization: Bearer $1" | jq -r '.name // empty'
    }

    mx_joined() { # token room -> joined mxids
      curl -s "$URL/_matrix/client/v3/rooms/$(enc "$2")/joined_members" \
        -H "authorization: Bearer $1" | jq -r '.joined // {} | keys[]'
    }

    # --- the bot's view, which is the one hookshot actually uses ------------------
    as_acctdata() { # room -> the hookId -> stateKey map (raw json)
      curl -s "$URL/_matrix/client/v3/user/$(enc "$BOT")/rooms/$(enc "$1")/account_data/${connectionType}?user_id=$(enc "$BOT")" \
        -H "authorization: Bearer $AS"
    }

    as_connection() { # room statekey -> the connection state event (raw json)
      curl -s "$URL/_matrix/client/v3/rooms/$(enc "$1")/state/${connectionType}/$(enc "$2")?user_id=$(enc "$BOT")" \
        -H "authorization: Bearer $AS"
    }
  '';
in
pkgs.testers.nixosTest {
  name = "matrix-infra-alerts";

  nodes.machine =
    {
      lib,
      pkgs,
      ...
    }:
    {
      imports = [ (self + /modules/nixos/profiles/matrix/infra-alerts.nix) ];

      options = {
        custom.profiles.matrix.adminLocalpart = lib.mkOption {
          type = lib.types.str;
          default = admin;
        };
        custom.profiles.matrix.hookshot.enable = lib.mkEnableOption "hookshot (stub)";
        # infra-alerts.nix chains its ordering off these; they are declared by the
        # sibling modules, which this check has no reason to stand up. Left off, so
        # the ordering chain here is just the bridge — the one-transaction case is
        # the admin-room check's job.
        custom.profiles.matrix.hookshot.notificationsRoom.enable =
          lib.mkEnableOption "notifications room (stub)";
        custom.profiles.matrix.hookshot.personalToken.enable = lib.mkEnableOption "credential store (stub)";
        custom.profiles.matrix.resetState = lib.mkOption {
          type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
          default = [ ];
        };
        custom.profiles.impermanence.enable = lib.mkEnableOption "impermanence (stub)";
        environment.persistence = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
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
                  owner = lib.mkOption {
                    type = lib.types.str;
                    default = "root";
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
        # The profile reads `self.lib.getSecretFile` and takes the webhook port from
        # the service registry; test nodes get neither module arg from specialArgs.
        # The sopsFile `self` resolves is unused — every secret path is forced to a
        # plain file below — while `settings` is the real registry, so the port the
        # published webhook URL carries is the deployed one.
        _module.args.self = self;
        _module.args.settings = self.settings;

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
            appservice_dir = "/etc/tuwunel-appservices/";
          };
        };
        environment.etc."tuwunel-reg-token".text = regToken;
        environment.etc."tuwunel-appservices/hookshot-registration.yaml".source = registration;

        sops.secrets.matrix_admin_password.path = "/etc/admin-pw";
        environment.etc."admin-pw".text = adminPass;
        sops.secrets.hookshot_as_token.path = "/etc/as-token";
        environment.etc."as-token".text = asToken;
        sops.secrets.infra_alerts_hook_id.path = "/etc/hook-id";
        environment.etc."hook-id".text = hookId;

        systemd.services.tuwunel-register-admin = {
          description = "stub register-admin (test registers via API)";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

        systemd.services.hookshot-as-sink = {
          wantedBy = [ "multi-user.target" ];
          before = [ "tuwunel.service" ];
          serviceConfig.ExecStart = asSink;
        };

        # Stub bridge; the provisioner restarts it when it writes, and the counter is
        # how the test sees that.
        systemd.services.matrix-hookshot = {
          description = "stub matrix-hookshot";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "stub-bridge-start" ''
              echo start >> /var/lib/hookshot-starts
            '';
          };
        };

        custom.profiles.matrix.hookshot.enable = true;
        custom.profiles.matrix.infraAlerts = {
          enable = true;
          # A pin naming a room that never existed — the shape kelpy carried for four
          # weeks. Adopting it blindly is the bug; the provisioner must refuse.
          roomId = deadPin;
        };
        systemd.services.matrix-infra-alerts-room.wantedBy = lib.mkForce [ ];
      };
    };

  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("tuwunel.service")
    machine.wait_for_open_port(${toString port})
    machine.wait_until_succeeds("curl -sf ${url}/_matrix/client/versions", timeout=60)

    H = ". ${helpers}"
    def sh(cmd):
        return machine.succeed(f"{H}; {cmd}").strip()

    sh("mx_register ${admin} ${adminPass}")
    admin_tok = sh("mx_login ${admin} ${adminPass}")
    machine.succeed(
        "curl -s -o /dev/null -X POST ${url}/_matrix/client/v3/register"
        " -H 'authorization: Bearer ${asToken}' -H 'content-type: application/json'"
        " -d '{\"type\":\"m.login.application_service\",\"username\":\"${bot}\"}'"
    )
    machine.succeed("systemctl start matrix-hookshot.service")

    def marker():
        return machine.succeed("cat ${markerFile}").strip()

    def starts():
        return int(machine.succeed("wc -l < /var/lib/hookshot-starts || echo 0").strip())

    def assert_wired(room):
        """Assert the connection is resolvable the way hookshot resolves it."""
        acct = json.loads(sh(f"as_acctdata {room}"))
        state = json.loads(sh(f"as_connection {room} ${hookId}"))
        assert state.get("name") == "${connectionName}", f"connection state wrong: {state}"
        # GenericHook.js getHookId(): find the account-data KEY whose VALUE is the
        # state key. Without this the state event is a hook that answers 404.
        resolved = [k for k, v in acct.items() if v == "${hookId}"]
        assert resolved == ["${hookId}"], f"hookId does not resolve: acct={acct}"
        assert "@${bot}:${serverName}" in sh(f"mx_joined {admin_tok} {room}"), "bot not joined"
        assert sh(f"mx_room_name {admin_tok} {room}") == "Infra Alerts", "room name wrong"

    before = starts()

    # --- A dead pin must NOT be adopted -------------------------------------------
    machine.succeed("systemctl start matrix-infra-alerts-room.service")
    room = marker()
    assert room != "${deadPin}", "adopted a pinned room that does not exist"
    assert room.startswith("!"), f"no room created: {room!r}"
    machine.succeed("journalctl -u matrix-infra-alerts-room.service | grep -q 'created room'")
    assert_wired(room)
    assert starts() == before + 1, "bridge not restarted to load the connection"
    print(f"OK: dead pin refused, room created and fully wired -> {room}")

    # The webhook URL the fleet's alerters post to, carrying the shared hook id.
    hook_url = machine.succeed("cat ${webhookUrlFile}").strip()
    assert hook_url.endswith("/webhook/${hookId}"), f"webhook url wrong: {hook_url}"
    assert machine.succeed("stat -c %a ${webhookUrlFile}").strip() == "644", "webhook url not readable"
    print(f"OK: webhook url published -> {hook_url}")

    # --- Idempotent ---------------------------------------------------------------
    machine.succeed("systemctl restart matrix-infra-alerts-room.service")
    assert marker() == room, "room changed on a no-op run"
    assert starts() == before + 1, "restarted the bridge with nothing to write"
    print("OK: re-run is a no-op")

    # --- A marker whose room is gone must not be trusted either --------------------
    #     This is the four-week outage in miniature: the id survives the room, and
    #     everything downstream keeps reporting success while posting into nothing.
    machine.succeed("echo -n '${goneRoom}' > ${markerFile}")
    machine.succeed("systemctl restart matrix-infra-alerts-room.service")
    machine.succeed(
        "journalctl -u matrix-infra-alerts-room.service | grep -q 'the recorded room is gone'"
    )
    fresh = marker()
    assert fresh not in ("${goneRoom}", room), f"reused a room that does not exist: {fresh}"
    assert_wired(fresh)
    assert starts() == before + 2, "bridge not restarted for the replacement room"
    print(f"OK: stale marker refused, replacement room created and wired -> {fresh}")
  '';
}

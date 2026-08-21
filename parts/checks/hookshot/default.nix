{
  self,
  pkgs,
  ...
}:

# VM check for hookshot's admin-room oneshot
# (modules/nixos/profiles/matrix/hookshot-adminroom.nix), driven against a real
# tuwunel with the REAL DM provisioner in front of it.
#
# Two behaviours, both invisible from the outside until they silently aren't
# working — which is exactly how they failed in production:
#
#   1. The ADMIN-ROOM MARKER, without which `github login` / `github
#      notifications toggle` don't exist at all (tuwunel never stamps is_direct).
#   2. The NOTIFICATION STREAM POSITION (upstream #965). Hookshot's
#      UserNotificationWatcher.addUser does `data.since || existing?.since`, so
#      the `0` that a never-polled room legitimately reports reads as "missing"
#      and it throws. Only the watcher ever writes notif_state, so it can never
#      start: `github login` succeeds, `notifications toggle` says "Enabled", and
#      nothing ever arrives. Seeding a non-zero `since` is what breaks the
#      deadlock, so this check pins the seed's presence, its magnitude (ms, not
#      seconds — GitHubWatcher does `new Date(since)`), that it heals a room that
#      is ALREADY activated, and that it never rewinds a live stream position.
#
# The bridge itself is a stub: hookshot's own consumption of these markers is
# upstream behaviour, and proving it would need a stubbed GitHub API. What this
# check owns is that the markers we write are present and well-formed. The test
# plays the bridge bot (registering + joining via the appservice token) the same
# way the dm-provision check does.

let
  serverName = "hstest.test";
  port = 6167;
  url = "http://127.0.0.1:${toString port}";
  regToken = "test-reg-token";
  admin = "admin";
  adminPass = "adminpass";
  bot = "hookshot";
  asToken = "test-as-token";
  hsToken = "test-hs-token";
  asPort = 9993;

  # Adversarial room name/topic. These are OPTION values that end up inside a shell
  # script, so backticks / $(...) / a quote must survive verbatim — the real default
  # topic contains `github login`, which executed as root on the first real deploy
  # and blanked itself. /tmp/pwned is the canary.
  notifRoomName = "GitHub `id` Notifications";
  notifRoomTopic = "Run `github login`; $(touch /tmp/pwned) it's fine";

  # Where the notifications-room module persists its server-assigned room id.
  notificationsRoomIdFile = "/var/lib/matrix-hookshot-notifications-room/room-id";

  adminRoomType = "uk.half-shot.matrix-hookshot.github.room";
  notifStateType = "uk.half-shot.matrix-hookshot.github.notif_state";

  # Appservice registration in the production shape (sender_localpart outside the
  # namespaces — tuwunel grants it implicitly, which is what lets us masquerade).
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
        - exclusive: true
          regex: '@_webhooks_.*'
      aliases: []
      rooms: []
  '';

  # Swallows tuwunel's appservice transactions so it doesn't retry-log forever.
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

  helpers = pkgs.writeText "hs-helpers.sh" ''
    set -eu
    URL="${url}"
    TOKEN="${regToken}"
    AS="${asToken}"
    BOT="@${bot}:${serverName}"

    enc() { jq -rn --arg s "$1" '$s|@uri'; }

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

    # --- bridge-bot side, via the appservice token (what the unit under test uses) ---
    as_register_bot() {
      curl -s -o /dev/null -X POST "$URL/_matrix/client/v3/register" \
        -H "authorization: Bearer $AS" -H 'content-type: application/json' \
        -d "$(jq -nc --arg u "${bot}" '{type:"m.login.application_service",username:$u}')"
    }

    as_invited() { # -> invited room ids
      curl -s "$URL/_matrix/client/v3/sync?timeout=0&user_id=$(enc "$BOT")" \
        -H "authorization: Bearer $AS" | jq -r '.rooms.invite // {} | keys[]'
    }

    as_join() { # room
      curl -sf -o /dev/null -X POST \
        "$URL/_matrix/client/v3/join/$(enc "$1")?user_id=$(enc "$BOT")" \
        -H "authorization: Bearer $AS" -H 'content-type: application/json' -d '{}'
    }

    as_account_data() { # room type -> raw json
      curl -s "$URL/_matrix/client/v3/user/$(enc "$BOT")/rooms/$(enc "$1")/account_data/$2?user_id=$(enc "$BOT")" \
        -H "authorization: Bearer $AS"
    }

    as_set_account_data() { # room type json
      curl -sf -o /dev/null -X PUT \
        "$URL/_matrix/client/v3/user/$(enc "$BOT")/rooms/$(enc "$1")/account_data/$2?user_id=$(enc "$BOT")" \
        -H "authorization: Bearer $AS" -H 'content-type: application/json' -d "$3"
    }

    # --- operator side ------------------------------------------------------------
    mx_joined() { # token room -> joined mxids
      curl -s "$URL/_matrix/client/v3/rooms/$(enc "$2")/joined_members" \
        -H "authorization: Bearer $1" | jq -r '.joined // {} | keys[]'
    }

    mx_set_topic() { # token room topic
      curl -sf -o /dev/null -X PUT \
        "$URL/_matrix/client/v3/rooms/$(enc "$2")/state/m.room.topic" \
        -H "authorization: Bearer $1" -H 'content-type: application/json' \
        -d "$(jq -nc --arg t "$3" '{topic:$t}')"
    }

    mx_topic() { # token room -> topic
      curl -s "$URL/_matrix/client/v3/rooms/$(enc "$2")/state/m.room.topic" \
        -H "authorization: Bearer $1" | jq -r '.topic // empty'
    }

    mx_room_name() { # token room -> name
      curl -s "$URL/_matrix/client/v3/rooms/$(enc "$2")/state/m.room.name" \
        -H "authorization: Bearer $1" | jq -r '.name // empty'
    }

    mx_tags() { # token localpart room -> tag keys
      curl -s "$URL/_matrix/client/v3/user/@$2:${serverName}/rooms/$(enc "$3")/tags" \
        -H "authorization: Bearer $1" | jq -r '.tags // {} | keys[]'
    }
  '';
in
pkgs.testers.nixosTest {
  name = "matrix-hookshot-adminroom";

  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # The REAL builders, bound to this node's config.
      mkDm = import (self + /modules/nixos/profiles/matrix/dm-provision.nix) {
        inherit pkgs config;
      };
      mkAdminRoom = import (self + /modules/nixos/profiles/matrix/hookshot-adminroom.nix) {
        inherit pkgs config;
      };
      notificationsRoom = config.custom.profiles.matrix.hookshot.notificationsRoom;
      # Don't auto-run at boot — the test drives both units explicitly.
      manual =
        svc:
        lib.mkMerge [
          svc
          { wantedBy = lib.mkForce [ ]; }
        ];
    in
    {
      # The REAL notifications-room module, so the room provisioner under test is
      # the deployed one. Its siblings (hookshot.nix, impermanence) are stubbed
      # below rather than imported — they'd drag in sops, the bridge package and
      # the GitHub App for no added coverage.
      imports = [
        (self + /modules/nixos/profiles/matrix/hookshot-notifications-room.nix)
        # Not to test the credential store (parts/checks/hookshot/token.nix owns
        # that) but because it is the THIRD unit that restarts the bridge, and the
        # one-transaction phase below is only representative with all three in it.
        (self + /modules/nixos/profiles/matrix/hookshot-github-token.nix)
      ];

      options = {
        custom.profiles.matrix.adminLocalpart = lib.mkOption {
          type = lib.types.str;
          default = admin;
        };
        # Declared by hookshot.nix in the real tree.
        custom.profiles.matrix.hookshot.enable = lib.mkEnableOption "hookshot (stub)";
        # `matrix-reset` wiring the module contributes to; unused here.
        custom.profiles.matrix.resetState = lib.mkOption {
          type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
          default = [ ];
        };
        custom.profiles.impermanence.enable = lib.mkEnableOption "impermanence (stub)";
        environment.persistence = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        # Minimal stand-in for sops-nix's secrets surface — just the `.path` the
        # builders reference, so no sops machinery runs in the VM.
        sops.secrets = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                path = lib.mkOption { type = lib.types.str; };
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
            appservice_dir = "/etc/tuwunel-appservices/";
          };
        };
        environment.etc."tuwunel-reg-token".text = regToken;
        environment.etc."tuwunel-appservices/hookshot-registration.yaml".source = registration;

        sops.secrets.matrix_admin_password.path = "/etc/admin-pw";
        environment.etc."admin-pw".text = adminPass;
        sops.secrets.hookshot_as_token.path = "/etc/hookshot-as-token";
        environment.etc."hookshot-as-token".text = asToken;

        # dm-provision requires this unit; stub it (the test registers admin itself).
        systemd.services.tuwunel-register-admin = {
          description = "stub register-admin (test registers via API)";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

        # The shared m.direct serialization lock the matrix profile normally provides.
        systemd.tmpfiles.rules = [ "f /run/matrix-dm-mdirect.lock 0666 root root -" ];

        # Appservice transaction sink, so tuwunel's pushes don't error-loop.
        systemd.services.hookshot-as-sink = {
          wantedBy = [ "multi-user.target" ];
          before = [ "tuwunel.service" ];
          serviceConfig.ExecStart = asSink;
        };

        # Stub bridge. The unit under test restarts it once per new admin room; the
        # counter is how the test observes that (and that it doesn't restart twice).
        systemd.services.matrix-hookshot = {
          description = "stub matrix-hookshot";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StateDirectory = "matrix-hookshot";
            ExecStartPre = pkgs.writeShellScript "stub-genkey" ''
              [ -f /var/lib/matrix-hookshot/passkey.pem ] \
                || ${pkgs.openssl}/bin/openssl genrsa -out /var/lib/matrix-hookshot/passkey.pem 4096
            '';
            ExecStart = pkgs.writeShellScript "stub-bridge-start" ''
              echo start >> /var/lib/hookshot-starts
            '';
          };
        };

        systemd.services."matrix-dm-hookshot" = manual (mkDm {
          inherit bot;
          afterUnit = "tuwunel.service";
          name = "Hookshot admin";
        });

        custom.profiles.matrix.hookshot = {
          enable = true;
          personalToken = {
            enable = true;
            secretName = "hookshot_github_personal_token";
          };
          notificationsRoom = {
            enable = true;
            name = notifRoomName;
            topic = notifRoomTopic;
          };
        };
        sops.secrets.hookshot_github_personal_token.path = "/run/hookshot-github-token";
        systemd.services.seed-token-secret = {
          wantedBy = [ "multi-user.target" ];
          before = [ "matrix-hookshot-github-token.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "seed-token-secret" ''
              printf 'not-a-real-token-0000000000000000000000\n' > /run/hookshot-github-token
              chmod 0400 /run/hookshot-github-token
            '';
          };
        };

        # The room provisioner is real; just don't let it race the test at boot.
        systemd.services.matrix-hookshot-notifications-room.wantedBy = lib.mkForce [ ];
        systemd.services.matrix-hookshot-github-token.wantedBy = lib.mkForce [ ];

        # Both instances, wired exactly as hookshot.nix wires them.
        systemd.services."matrix-hookshot-adminroom" = manual (mkAdminRoom {
          inherit bot;
          dmMarker = "/var/lib/private/matrix-dm-hookshot/dm-created";
          asTokenPath = config.sops.secrets.hookshot_as_token.path;
          bridgeService = "matrix-hookshot.service";
          dmService = "matrix-dm-hookshot.service";
          # A dedicated room owns the feed, so the DM must assert it OFF.
          notifications = false;
        });

        systemd.services."matrix-hookshot-notifications-adminroom" = manual (mkAdminRoom {
          inherit bot;
          label = "notifications room";
          notifications = true;
          dmMarker = notificationsRoom.roomIdFile;
          asTokenPath = config.sops.secrets.hookshot_as_token.path;
          bridgeService = "matrix-hookshot.service";
          dmService = "matrix-hookshot-notifications-room.service";
          extraAfter = [ "matrix-hookshot-adminroom.service" ];
          stateDirectory = "matrix-hookshot-notifications-adminroom";
        });
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

    def notif_since(room):
        raw = sh(f"as_account_data {room} ${notifStateType}")
        return json.loads(raw).get("since")

    def bridge_starts():
        return int(machine.succeed("wc -l < /var/lib/hookshot-starts || echo 0").strip())

    # --- No DM yet: the unit must be a graceful no-op, not a failure ---------------
    machine.succeed("systemctl restart matrix-hookshot-adminroom.service")
    machine.succeed(
        "journalctl -u matrix-hookshot-adminroom.service | grep -q 'no DM marker yet'"
    )
    print("OK: no-op when the DM does not exist yet")

    # --- Provision the DM with the REAL provisioner, and play the bridge bot -------
    sh("mx_register ${admin} ${adminPass}")
    admin_tok = sh("mx_login ${admin} ${adminPass}")
    sh("as_register_bot")
    machine.succeed("systemctl start --no-block matrix-dm-hookshot.service")

    room = None
    for _ in range(60):
        inv = sh("as_invited").split()
        if inv:
            room = inv[0]
            sh(f"as_join {room}")
            break
        machine.sleep(1)
    assert room, "bot never got an invite to the management DM"
    machine.wait_until_succeeds("systemctl is-active matrix-dm-hookshot.service", timeout=60)
    print(f"OK: management DM provisioned and joined -> {room}")

    machine.succeed("systemctl start matrix-hookshot.service")
    before = bridge_starts()

    # --- The unit under test ------------------------------------------------------
    machine.succeed("systemctl restart matrix-hookshot-adminroom.service")

    # 1. Admin-room marker: without this, `github login` / `notifications toggle`
    #    don't exist at all, because tuwunel never stamps is_direct on the invite.
    marker = json.loads(sh(f"as_account_data {room} ${adminRoomType}"))
    assert marker.get("admin_user") == "@${admin}:${serverName}", f"admin marker wrong: {marker}"
    print("OK: DM marked as a hookshot admin room")

    # 2. Notification stream position seeded (upstream #965). A `0` here is exactly
    #    what addUser reads as "missing" — the deadlock this seed exists to break.
    since = notif_since(room)
    assert isinstance(since, int) and since > 0, f"notif-since not seeded: {since!r}"
    #    ...and in MILLISECONDS: GitHubWatcher does `new Date(since).toISOString()`,
    #    so a seconds-scale value would land in 1970 and re-deliver the backlog.
    assert since >= 10**12, f"notif-since looks like seconds, not ms: {since}"
    now_ms = int(machine.succeed("date +%s").strip()) * 1000
    assert abs(now_ms - since) < 10 * 60 * 1000, f"notif-since not near now: {since} vs {now_ms}"
    print(f"OK: notif-since seeded in ms near now -> {since}")

    # 3. The bridge is restarted once, so it loads the room as an admin room.
    assert bridge_starts() == before + 1, "bridge not restarted for the new admin room"
    print("OK: bridge restarted once for the new admin room")

    # --- Idempotency: a re-run changes nothing ------------------------------------
    machine.succeed("systemctl restart matrix-hookshot-adminroom.service")
    machine.succeed(
        "journalctl -u matrix-hookshot-adminroom.service | grep -q 'already active as an admin room'"
    )
    assert bridge_starts() == before + 1, "bridge restarted again on an unchanged room"
    assert notif_since(room) == since, "notif-since rewritten on a re-run"
    print("OK: idempotent re-run — no restart, no reseed")

    # --- Never rewind a live stream position --------------------------------------
    #     Once the watcher is running it owns notif_state; overwriting it would
    #     re-deliver every notification since that point. Nothing written => nothing
    #     to make hookshot re-read => no restart.
    advanced = since + 3600 * 1000
    sh(f"as_set_account_data {room} ${notifStateType} '{json.dumps({'since': advanced})}'")
    machine.succeed("systemctl restart matrix-hookshot-adminroom.service")
    assert notif_since(room) == advanced, "seed clobbered a live notif-since"
    machine.succeed(
        "journalctl -u matrix-hookshot-adminroom.service | grep -q 'notif-since already at'"
    )
    assert bridge_starts() == before + 1, "bridge restarted with nothing to re-read"
    print("OK: an existing stream position is left alone, and no needless restart")

    # --- Healing: an ALREADY-ACTIVATED room still gets re-seeded -------------------
    #     The path that matters for a deployment predating the seed: the room is
    #     already in the `activated` marker, so the restart-once bookkeeping
    #     short-circuits. The seed must happen BEFORE that early exit, and must
    #     still force a restart — a live hookshot never re-reads this account data
    #     on its own, so an unrestarted bridge keeps the broken watcher state.
    sh(f"as_set_account_data {room} ${notifStateType} '{json.dumps({'since': 0})}'")
    assert notif_since(room) == 0, "failed to reset notif-since for the healing case"
    machine.succeed("systemctl restart matrix-hookshot-adminroom.service")
    healed = notif_since(room)
    assert isinstance(healed, int) and healed > 0, f"already-activated room not healed: {healed!r}"
    assert bridge_starts() == before + 2, "healing did not restart the bridge to take effect"
    print(f"OK: already-activated room re-seeded, and restarted to take effect -> {healed}")

    # --- The DM surrenders the feed ------------------------------------------------
    #     With a dedicated room configured, the DM keeps its admin-room powers but
    #     must assert the feed OFF: hookshot keys its watcher on userId:type, so two
    #     admin rooms with the feed on means whichever loads last silently wins.
    dm_state = json.loads(sh(f"as_account_data {room} ${adminRoomType}"))
    assert dm_state["github"]["notifications"]["enabled"] is False, f"DM feed not off: {dm_state}"
    assert dm_state["admin_user"] == "@${admin}:${serverName}", "DM lost its admin_user"
    print("OK: the DM stays an admin room with the feed asserted off")

    # --- The dedicated notifications room ------------------------------------------
    machine.succeed("systemctl restart matrix-hookshot-notifications-room.service")
    nroom = machine.succeed("cat ${notificationsRoomIdFile}").strip()
    assert nroom.startswith("!"), f"no room id persisted: {nroom!r}"
    assert "@${bot}:${serverName}" in sh(f"mx_joined {admin_tok} {nroom}"), "bot not in notif room"
    #     Name and topic must arrive VERBATIM: they pass through Nix -> shell -> jq,
    #     and shell metacharacters in them must never be evaluated.
    assert sh(f"mx_room_name {admin_tok} {nroom}") == ${builtins.toJSON notifRoomName}, "room name mangled"
    assert sh(f"mx_topic {admin_tok} {nroom}") == ${builtins.toJSON notifRoomTopic}, "room topic mangled"
    machine.fail("test -e /tmp/pwned")
    assert "m.favourite" in sh(f"mx_tags {admin_tok} ${admin} {nroom}"), "notif room not favourited"
    print(f"OK: notifications room provisioned, joined, named, favourited -> {nroom}")

    # It is created ONCE: a re-run reuses the persisted id rather than making a second.
    machine.succeed("systemctl restart matrix-hookshot-notifications-room.service")
    assert machine.succeed("cat ${notificationsRoomIdFile}").strip() == nroom, "room recreated"
    print("OK: notifications room creation is idempotent")

    # Name/topic are re-asserted on an EXISTING room, so an edited option lands on
    # deploy — and a room created by an earlier broken render heals itself.
    sh(f"mx_set_topic {admin_tok} {nroom} 'stale'")
    assert sh(f"mx_topic {admin_tok} {nroom}") == "stale", "failed to stale the topic"
    machine.succeed("systemctl restart matrix-hookshot-notifications-room.service")
    assert sh(f"mx_topic {admin_tok} {nroom}") == ${builtins.toJSON notifRoomTopic}, "topic not re-asserted"
    machine.fail("test -e /tmp/pwned")
    print("OK: name/topic re-asserted on an existing room, still verbatim")

    # Marked as an admin room, seeded, and the feed asserted ON — the declarative
    # equivalent of typing `github notifications toggle` in that room.
    before_n = bridge_starts()
    machine.succeed("systemctl restart matrix-hookshot-notifications-adminroom.service")
    n_state = json.loads(sh(f"as_account_data {nroom} ${adminRoomType}"))
    assert n_state["admin_user"] == "@${admin}:${serverName}", f"notif room not marked: {n_state}"
    assert n_state["github"]["notifications"]["enabled"] is True, f"feed not enabled: {n_state}"
    n_since = notif_since(nroom)
    assert isinstance(n_since, int) and n_since >= 10**12, f"notif room not seeded: {n_since!r}"
    assert bridge_starts() == before_n + 1, "bridge not restarted to load the notifications room"
    print(f"OK: notifications room is an admin room with the feed on, seeded -> {n_since}")

    # Idempotent: nothing left to write, so no restart.
    machine.succeed("systemctl restart matrix-hookshot-notifications-adminroom.service")
    assert bridge_starts() == before_n + 1, "restarted the bridge with nothing to write"
    assert notif_since(nroom) == n_since, "reseeded an already-seeded notifications room"
    print("OK: notifications room re-run is a no-op")

    # Declared state is ASSERTED: a hand toggle-off in chat is put back, and the
    # bridge restarted so it actually re-reads it.
    sh(
        f"as_set_account_data {nroom} ${adminRoomType} "
        f"'{json.dumps({'admin_user': '@${admin}:${serverName}', 'github': {'notifications': {'enabled': False, 'participating': True}}})}'"
    )
    machine.succeed("systemctl restart matrix-hookshot-notifications-adminroom.service")
    n_state = json.loads(sh(f"as_account_data {nroom} ${adminRoomType}"))
    assert n_state["github"]["notifications"]["enabled"] is True, "declared feed state not re-asserted"
    #     ...without trampling hookshot's own keys in the same object.
    assert n_state["github"]["notifications"]["participating"] is True, "clobbered participating"
    assert bridge_starts() == before_n + 2, "re-assert did not restart the bridge"
    print("OK: the declared feed state is re-asserted without clobbering hookshot's own keys")

    # --- All of it in ONE transaction, the way `matrix-reset` drives it -------------
    #     matrix-reset does a single `systemctl restart` over every isDm oneshot at
    #     once. Both admin-room instances restart the bridge from *inside* that
    #     transaction while being ordered After= it, which is the shape that can
    #     deadlock systemd. After= serialises them; this pins that it stays true,
    #     because a deadlock here hangs the reset with no obvious culprit.
    machine.succeed(
        "systemctl restart"
        " matrix-dm-hookshot.service"
        " matrix-hookshot-notifications-room.service"
        " matrix-hookshot-adminroom.service"
        " matrix-hookshot-notifications-adminroom.service"
        " matrix-hookshot-github-token.service",
        timeout=120,
    )
    for unit in [
        "matrix-dm-hookshot",
        "matrix-hookshot-notifications-room",
        "matrix-hookshot-adminroom",
        "matrix-hookshot-notifications-adminroom",
        "matrix-hookshot-github-token",
    ]:
        machine.succeed(f"systemctl is-active {unit}.service")
    #     ...and the declared state is intact on the other side.
    assert json.loads(sh(f"as_account_data {nroom} ${adminRoomType}"))["github"]["notifications"]["enabled"] is True
    assert json.loads(sh(f"as_account_data {room} ${adminRoomType}"))["github"]["notifications"]["enabled"] is False
    assert notif_since(nroom) == n_since, "reseeded during the batch restart"
    print("OK: the whole set restarts in one transaction without deadlocking")
  '';
}

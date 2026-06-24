{
  self,
  pkgs,
  ...
}:

# VM check for the Claude relay (ADR-0025), slice 01: prove the relay logs in,
# syncs, and acts ONLY on the allowlisted sender (echo), ignoring everyone else.
# A minimal tuwunel homeserver stands in for the real matrix profile.

let
  serverName = "relay.test";
  port = 6167;
  url = "http://127.0.0.1:${toString port}";
  regToken = "test-reg-token";
  botLocalpart = "claude-relay";
  allowedMxid = "@allowed:${serverName}";

  # Bash helpers for the Matrix C-S API, sourced in the testScript. Each echoes
  # the value the driver needs (access token, room id, message bodies), so the
  # Python side stays free of curl/jq quoting.
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

    mx_login() { # localpart password -> access_token
      curl -s -X POST "$URL/_matrix/client/v3/login" -H 'content-type: application/json' \
        -d "$(jq -nc --arg u "$1" --arg p "$2" \
          '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')" \
        | jq -r '.access_token'
    }

    mx_create_room() { # token -> room_id
      curl -s -X POST "$URL/_matrix/client/v3/createRoom" \
        -H "authorization: Bearer $1" -H 'content-type: application/json' \
        -d '{"preset":"private_chat"}' | jq -r '.room_id'
    }

    mx_invite() { # token room mxid
      curl -sf -o /dev/null -X POST "$URL/_matrix/client/v3/rooms/$2/invite" \
        -H "authorization: Bearer $1" -H 'content-type: application/json' \
        -d "$(jq -nc --arg u "$3" '{user_id:$u}')"
    }

    mx_join() { # token room
      curl -sf -o /dev/null -X POST "$URL/_matrix/client/v3/join/$2" \
        -H "authorization: Bearer $1" -H 'content-type: application/json' -d '{}'
    }

    mx_send() { # token room body
      txn="m$(date +%s%N)"
      curl -sf -o /dev/null -X PUT "$URL/_matrix/client/v3/rooms/$2/send/m.room.message/$txn" \
        -H "authorization: Bearer $1" -H 'content-type: application/json' \
        -d "$(jq -nc --arg b "$3" '{msgtype:"m.text",body:$b}')"
    }

    mx_members() { # token room -> joined mxids, newline-separated
      curl -s "$URL/_matrix/client/v3/rooms/$2/joined_members" \
        -H "authorization: Bearer $1" | jq -r '.joined // {} | keys[]'
    }

    # All "<sender> <body>" pairs in the room, most-recent first.
    mx_texts() { # token room -> "sender\tbody" lines
      curl -s "$URL/_matrix/client/v3/rooms/$2/messages?dir=b&limit=50" \
        -H "authorization: Bearer $1" \
        | jq -r '.chunk[] | select(.type=="m.room.message") | "\(.sender)\t\(.content.body)"'
    }

    mx_poll_event() { # token room -> latest poll.start event_id
      curl -s "$URL/_matrix/client/v3/rooms/$2/messages?dir=b&limit=50" \
        -H "authorization: Bearer $1" \
        | jq -r '[.chunk[] | select(.type=="org.matrix.msc3381.poll.start")][0].event_id // empty'
    }

    mx_poll_respond() { # token room poll_id answer_id
      txn="p$(date +%s%N)"
      curl -sf -o /dev/null -X PUT \
        "$URL/_matrix/client/v3/rooms/$2/send/org.matrix.msc3381.poll.response/$txn" \
        -H "authorization: Bearer $1" -H 'content-type: application/json' \
        -d "$(jq -nc --arg e "$3" --arg a "$4" \
          '{"m.relates_to":{rel_type:"m.reference",event_id:$e},"org.matrix.msc3381.poll.response":{answers:[$a]}}')"
    }

    mx_invited() { # token -> invited room ids
      curl -s "$URL/_matrix/client/v3/sync?timeout=0" -H "authorization: Bearer $1" \
        | jq -r '.rooms.invite // {} | keys[]'
    }

    mx_federate() { # token room -> m.federate of the create event ("true"/"false")
      curl -s "$URL/_matrix/client/v3/rooms/$2/state/m.room.create" \
        -H "authorization: Bearer $1" | jq -r '."m.federate"'
    }
  '';

  # Stand-in for the real `claude` CLI: reads input lines from its tmux pane, writes
  # a transcript turn (assistant text + a tool_use), then fires the relay-provisioned
  # Stop hook — exercising the relay's send-keys -> hook -> transcript -> post path.
  stub = pkgs.writeShellScript "claude-stub" ''
    set -eu
    sid="stub-$$"
    proj="$HOME/.claude/projects/stub"
    mkdir -p "$proj"
    tr="$proj/$sid.jsonl"
    : > "$tr"
    hook=$(jq -r '.hooks.Stop[0].hooks[0].command' "$HOME/.claude/settings.json")
    while IFS= read -r line; do
      # "needperm": fire a permission Notification, wait for the granted number
      # the relay types back after the poll vote, then record the grant.
      if [ "$line" = "needperm" ]; then
        notif=$(jq -r '.hooks.Notification[0].hooks[0].command' "$HOME/.claude/settings.json")
        jq -nc --arg s "$sid" '{session_id:$s,hook_event_name:"Notification",notification_type:"permission_prompt",message:"Run Bash command?"}' | sh -c "$notif"
        IFS= read -r choice
        jq -nc --arg t "granted: $choice" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}' >> "$tr"
        jq -nc --arg s "$sid" --arg tp "$tr" '{session_id:$s,transcript_path:$tp,hook_event_name:"Stop",cwd:"/tmp"}' | sh -c "$hook"
        continue
      fi
      jq -nc --arg t "$line" '{type:"user",message:{role:"user",content:[{type:"text",text:$t}]}}' >> "$tr"
      jq -nc --arg t "You said: $line" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}' >> "$tr"
      jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Bash",input:{command:"echo hi"}}]}}' >> "$tr"
      jq -nc --arg s "$sid" --arg tp "$tr" '{session_id:$s,transcript_path:$tp,hook_event_name:"Stop",cwd:"/tmp"}' | sh -c "$hook"
    done
  '';
in
pkgs.testers.nixosTest {
  name = "claude-relay-lifecycle";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ (self + /modules/nixos/services/claude-relay) ];

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      # Minimal homeserver (stands in for the matrix profile).
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

      # The relay bot's password file.
      environment.etc."claude-relay-pw".text = "botpass";

      services.claude-relay = {
        enable = true;
        homeserver = url;
        user = botLocalpart;
        passwordFile = "/etc/claude-relay-pw";
        allowedSender = allowedMxid;
        claudeCommand = "${stub}";
      };
      # Don't race the bot account into existence — the driver registers it, then
      # (re)starts the relay. Relay also self-heals via Restart=on-failure.
      systemd.services.claude-relay.wantedBy = lib.mkForce [ ];

      virtualisation.memorySize = 2048;
    };

  testScript = ''
    import shlex

    machine.start()
    machine.wait_for_unit("tuwunel.service")
    machine.wait_for_open_port(${toString port})
    # Homeserver ready?
    machine.wait_until_succeeds("curl -sf ${url}/_matrix/client/versions", timeout=60)

    H = ". ${helpers}"

    def sh(cmd):
        return machine.succeed(f"{H}; {cmd}").strip()

    # Accounts: bot first (becomes admin, harmless), then the two humans.
    sh("mx_register ${botLocalpart} botpass")
    sh("mx_register allowed apass")
    sh("mx_register mallory mpass")

    # Start the relay; it logs in and stands up a control room (inviting us).
    machine.systemctl("start claude-relay.service")
    machine.wait_for_unit("claude-relay.service")
    machine.wait_until_succeeds(
        "journalctl -u claude-relay.service | grep -q 'entering sync loop'", timeout=90
    )

    allowed_tok = sh("mx_login allowed apass")
    mallory_tok = sh("mx_login mallory mpass")

    joined = set()

    def wait_new_room(tok):
        for _ in range(60):
            fresh = [r for r in sh(f"mx_invited {tok}").split() if r not in joined]
            if fresh:
                sh(f"mx_join {tok} {fresh[0]}")
                joined.add(fresh[0])
                return fresh[0]
            machine.sleep(1)
        raise Exception("timed out waiting for a new invite")

    control = wait_new_room(allowed_tok)
    print(f"control = {control}")

    def send_control(text):
        sh(f"mx_send {allowed_tok} {control} {shlex.quote(text)}")

    # `new` creates a session room (non-federated) we get invited to.
    send_control("new /tmp")
    room1 = wait_new_room(allowed_tok)
    fed = sh(f"mx_federate {allowed_tok} {room1}")
    assert fed == "false", f"session room must be non-federated, got m.federate={fed}"
    print("OK: new -> non-federated session room")

    # Routing: a message in the session room reaches its session; reply comes back.
    sh(f"mx_send {allowed_tok} {room1} hello")
    machine.wait_until_succeeds(
        f"{H}; mx_texts {allowed_tok} {room1} | grep -F 'You said: hello'", timeout=60
    )
    print("OK: message routed to its session")

    # Allowlist still holds inside a session room: mallory is ignored.
    sh(f"mx_invite {allowed_tok} {room1} @mallory:${serverName}")
    sh(f"mx_join {mallory_tok} {room1}")
    sh(f"mx_send {mallory_tok} {room1} evil")
    machine.sleep(8)
    assert "You said: evil" not in sh(f"mx_texts {allowed_tok} {room1}"), "non-allowlisted sender acted on!"
    print("OK: non-allowlisted sender ignored in session room")

    # Permission poll still works, scoped to this session room.
    sh(f"mx_send {allowed_tok} {room1} needperm")
    machine.wait_until_succeeds(
        f"{H}; mx_poll_event {allowed_tok} {room1} | grep -q .", timeout=60
    )
    poll_id = sh(f"mx_poll_event {allowed_tok} {room1}")
    sh(f"mx_poll_respond {allowed_tok} {room1} {shlex.quote(poll_id)} 1")
    machine.wait_until_succeeds(
        f"{H}; mx_texts {allowed_tok} {room1} | grep -F 'granted: 1'", timeout=60
    )
    print("OK: permission poll -> vote -> grant, scoped to the session")

    # A second session, isolated from the first.
    send_control("new /tmp")
    room2 = wait_new_room(allowed_tok)
    sh(f"mx_send {allowed_tok} {room2} world")
    machine.wait_until_succeeds(
        f"{H}; mx_texts {allowed_tok} {room2} | grep -F 'You said: world'", timeout=60
    )
    assert "You said: world" not in sh(f"mx_texts {allowed_tok} {room1}"), "routing leaked across sessions!"
    print("OK: two sessions, per-room routing isolated")

    # Cap = 2: a third `new` is refused.
    send_control("new /tmp")
    machine.wait_until_succeeds(
        f"{H}; mx_texts {allowed_tok} {control} | grep -iF 'limit'", timeout=30
    )
    print("OK: concurrency cap enforced")

    # list shows both sessions; kill removes one.
    send_control("list")
    machine.wait_until_succeeds(
        f"{H}; mx_texts {allowed_tok} {control} | grep -F 'claude-1'", timeout=30
    )
    machine.wait_until_succeeds(
        f"{H}; mx_texts {allowed_tok} {control} | grep -F 'claude-2'", timeout=30
    )
    send_control("kill claude-1")
    machine.wait_until_succeeds(
        f"{H}; mx_texts {allowed_tok} {control} | grep -F 'killed claude-1'", timeout=30
    )
    print("OK: list + kill")
  '';
}

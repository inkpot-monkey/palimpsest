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
  name = "claude-relay-grants";

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

    # Now the bot account exists — start the relay and let it sync.
    machine.systemctl("start claude-relay.service")
    machine.wait_for_unit("claude-relay.service")
    # Wait until the relay has actually logged in + entered the sync loop.
    machine.wait_until_succeeds(
        "journalctl -u claude-relay.service | grep -q 'entering sync loop'", timeout=90
    )

    allowed_tok = sh("mx_login allowed apass")
    mallory_tok = sh("mx_login mallory mpass")

    room = sh(f"mx_create_room {allowed_tok}")
    print(f"room = {room}")

    # Invite the bot; it should auto-join. Invite mallory too so she can post.
    sh(f"mx_invite {allowed_tok} {room} @${botLocalpart}:${serverName}")
    sh(f"mx_invite {allowed_tok} {room} @mallory:${serverName}")
    sh(f"mx_join {mallory_tok} {room}")

    # Bot auto-joins on invite.
    machine.wait_until_succeeds(
        f"{H}; mx_members {allowed_tok} {room} | grep -qx @${botLocalpart}:${serverName}",
        timeout=60,
    )

    # The allowlisted sender's message is injected into the claude (stub) session;
    # the resulting transcript turn is posted back: assistant text ...
    sh(f"mx_send {allowed_tok} {room} {shlex.quote('hello')}")
    machine.wait_until_succeeds(
        f"{H}; mx_texts {allowed_tok} {room} | grep -F 'You said: hello'",
        timeout=60,
    )
    # ... and tool calls render as one-line summaries.
    machine.wait_until_succeeds(
        f"{H}; mx_texts {allowed_tok} {room} | grep -F '⚙ Bash'",
        timeout=30,
    )
    print("OK: allowlisted message injected; transcript turn + tool summary posted")

    # A non-allowlisted sender is never injected, so no transcript turn comes back.
    sh(f"mx_send {mallory_tok} {room} {shlex.quote('sneaky')}")
    machine.sleep(8)
    texts = sh(f"mx_texts {allowed_tok} {room}")
    assert "You said: sneaky" not in texts, f"relay acted on a non-allowlisted sender!\n{texts}"
    print("OK: non-allowlisted message ignored")

    # Permission flow: a needperm prompt -> grant poll -> vote -> the chosen number
    # is typed back into the session, producing the grant turn.
    sh(f"mx_send {allowed_tok} {room} needperm")
    machine.wait_until_succeeds(
        f"{H}; mx_poll_event {allowed_tok} {room} | grep -q .", timeout=60
    )
    poll_id = sh(f"mx_poll_event {allowed_tok} {room}")
    print(f"poll = {poll_id}")
    # Event IDs start with '$' — single-quote so the shell doesn't expand it.
    sh(f"mx_poll_respond {allowed_tok} {room} {shlex.quote(poll_id)} 1")
    machine.wait_until_succeeds(
        f"{H}; mx_texts {allowed_tok} {room} | grep -F 'granted: 1'", timeout=60
    )
    print("OK: permission poll -> vote -> grant injected")
  '';
}

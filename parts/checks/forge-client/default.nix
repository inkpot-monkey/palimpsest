{
  self,
  pkgs,
  ...
}:

# The rendered `tea` login (modules/nixos/profiles/tea-login.nix), consumed by
# custom.profiles.forge-client — palimpsest#213.
#
# ── What this replaces, and why ───────────────────────────────────────────────────────────
# #213 asked for "a smoke check that `tea whoami` succeeds after activation — the one signal
# that the rendered YAML still matches tea's upstream Login struct". The first half of that
# is IMPOSSIBLE, measured against a real tea 0.15.1 pointed at the live forge with a
# deliberately bad token:
#
#   tea whoami      → prints "# (disabled)" and exits 0   (cmd/whoami.go discards the
#                     SDK's error: `user, _, _ := client.Users.GetMyUserInfo(...)`)
#   tea api /user   → prints the 401 body and exits 0     (modules/api/client.go never
#                     looks at resp.StatusCode)
#   tea repos ls    → exits 1                             (SDK-backed, error propagates)
#
# So `tea whoami` cannot fail and is worthless as a check — a trap worth knowing for the
# tracker-doc recipes too, since `tea api` is how #210 spells half of them. Use an
# SDK-backed command when you want an exit code to mean something.
#
# The second half — "does the rendered YAML still match the struct" — is a BUILD-TIME
# question: it breaks when nixpkgs moves `tea`, not when a host boots. So it is answered
# here instead, in CI, before any deploy, with no live forge and no network. An
# activation-time unit was deliberately not added as well: both failures it could catch (a
# wrong token, a renamed field) surface as a non-zero exit on the agent's very next `tea`
# call, and on sawtoothShark — a laptop that boots off-tailnet — a boot-time probe against
# a tailnet-only forge is a recurring red unit reporting nothing new.
#
# ── Why a stub server rather than just parsing the file ───────────────────────────────────
# Because the dangerous drift is SILENT. Measured: rename `token` to `access_token` in the
# config and `tea repos ls` still exits 0 — it just sends the request with NO Authorization
# header at all. Against a stub that returns `[]` regardless, a parse-and-exit-code check
# passes while the token has stopped being sent. So the assertion has to be on the WIRE:
# the stub records what arrived, and the token must be in it.
#
# Case 2 is the sops trailing-newline trap, which is why tea-login.nix puts `token` last:
# sops substitutes the placeholder textually, so a value stored as a block scalar injects a
# raw newline into the rendered file. The same token must reach the wire either way.
#
# Case 3 proves case 1 can fail. Without it, a stub that accepts anything would make the
# whole check green no matter what the renderer emitted.

let
  render = import (self + /modules/nixos/profiles/tea-login.nix);

  token = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
  port = "18213";
  url = "http://127.0.0.1:${port}";

  # The real renderer, with the sops placeholder's position taken by a dummy.
  clean = render {
    loginName = "forge";
    inherit url token;
    user = "inkpotmonkey";
  };

  # As sops would render it if the secret were stored with a trailing newline.
  trailingNewline = render {
    loginName = "forge";
    inherit url;
    user = "inkpotmonkey";
    token = token + "\n";
  };

  # NOT the renderer: a hand-written config with `token` renamed, standing in for the
  # upstream struct drift this check exists to catch.
  drifted = ''
    logins:
      - name: forge
        url: ${url}
        user: inkpotmonkey
        default: true
        access_token: ${token}
  '';

  # Records every request it sees to $STUB_LOG, then answers with an empty list so the
  # exit code is decided by `tea`'s own parsing and auth handling, not by the response.
  stub = pkgs.writeText "forge-client-stub.py" ''
    import http.server, os, sys

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            with open(os.environ["STUB_LOG"], "a") as f:
                f.write(f"{self.path} auth={self.headers.get('Authorization')}\n")
            body = b"[]"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
  '';
in
pkgs.runCommand "check-forge-client"
  {
    nativeBuildInputs = [
      pkgs.tea
      # `tea` shells out to `git rev-parse --show-toplevel` to discover repository
      # context on EVERY invocation, including `repos ls`, which needs none. Without git
      # on PATH it does not degrade — it exits 1 with
      #   Error: git rev-parse --show-toplevel: exec: "git": executable file not found
      # (measured here, which is how this line came to exist). That is why the profile
      # puts git on PATH alongside tea rather than assuming the host has it.
      pkgs.git
      pkgs.python3
      pkgs.coreutils
      pkgs.gnugrep
    ];
    inherit clean trailingNewline drifted;
    passAsFile = [
      "clean"
      "trailingNewline"
      "drifted"
    ];
  }
  ''
    set -euo pipefail

    export HOME="$PWD/home"
    mkdir -p "$HOME"

    # A FRESH stub per case, rather than one for the whole run. The stub learns where to
    # log from $STUB_LOG in its own environment, which is fixed at launch — so a single
    # long-lived server cannot be re-pointed per case, and sharing one log would make each
    # assertion read its predecessors' requests too.
    #
    # $1 = case name, $2 = path to the config text. Echoes tea's exit code; the requests the
    # stub saw land in $name.log and tea's own output in $name.out.
    run_tea() {
      local name="$1" cfg="$2" dir rc pid
      dir="$PWD/$name"
      mkdir -p "$dir/tea"
      cp "$cfg" "$dir/tea/config.yml"

      : > "$PWD/$name.log"
      STUB_LOG="$PWD/$name.log" python3 ${stub} ${port} &
      pid=$!

      # The stub binds loopback inside the sandbox's own network namespace, so there is
      # nothing to collide with — but it still needs a moment before the first request.
      # Without this wait tea fails with a bare `EOF`, which looks like a config problem.
      local i
      for i in $(seq 1 100); do
        if (exec 3<>/dev/tcp/127.0.0.1/${port}) 2>/dev/null; then break; fi
        sleep 0.1
      done

      rc=0
      XDG_CONFIG_HOME="$dir" tea repos ls -o json > "$PWD/$name.out" 2>&1 || rc=$?

      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "$rc"
    }

    expect_token_on_the_wire() { # $1 = case name, $2 = description
      local name="$1" desc="$2"
      if ! grep -qF "auth=token ${token}" "$PWD/$name.log"; then
        echo "FAIL: $desc — the token did not reach the wire." >&2
        echo "  requests the stub saw:" >&2
        sed 's/^/    /' "$PWD/$name.log" >&2
        echo "  tea said:" >&2
        sed 's/^/    /' "$PWD/$name.out" >&2
        echo "  config rendered as:" >&2
        sed 's/^/    /' "$PWD/$name/tea/config.yml" >&2
        exit 1
      fi
      echo "ok: $desc"
    }

    # ── 1. The renderer's output, as sops would write it from a clean scalar ──────────────
    rc=$(run_tea clean "$cleanPath")
    if [ "$rc" != 0 ]; then
      echo "FAIL: tea rejected the rendered login (exit $rc)" >&2
      sed 's/^/    /' "$PWD/clean.out" >&2
      sed 's/^/    /' "$PWD/clean/tea/config.yml" >&2
      exit 1
    fi
    expect_token_on_the_wire clean "the rendered login authenticates as the default login"

    # ── 2. The same, with the sops trailing-newline trap sprung ───────────────────────────
    rc=$(run_tea trailing "$trailingNewlinePath")
    if [ "$rc" != 0 ]; then
      echo "FAIL: a trailing newline in the token broke the config (exit $rc)" >&2
      sed 's/^/    /' "$PWD/trailing.out" >&2
      exit 1
    fi
    expect_token_on_the_wire trailing "a trailing newline in the secret is absorbed, not sent"

    # ── 3. Teeth: a renamed token field must NOT satisfy case 1 ───────────────────────────
    run_tea drifted "$driftedPath" > /dev/null
    if grep -qF "auth=token ${token}" "$PWD/drifted.log"; then
      echo "FAIL: a config with no 'token' key still sent the token — this check cannot" >&2
      echo "      detect upstream struct drift and the cases above prove nothing." >&2
      exit 1
    fi
    if ! grep -q 'auth=' "$PWD/drifted.log"; then
      echo "FAIL: the drift case never reached the stub at all, so it is not exercising" >&2
      echo "      the same path as the cases above." >&2
      sed 's/^/    /' "$PWD/drifted.out" >&2
      exit 1
    fi
    echo "ok: a renamed token field is detected (tea sent the request unauthenticated)"

    touch $out
  ''

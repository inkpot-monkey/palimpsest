{
  self,
  pkgs,
  ...
}:

# The fleet disk-space watcher (modules/nixos/profiles/monitoring/disk-space.nix).
#
# What is worth pinning here is not "does it post when a disk is full" — it is the two
# properties that make this alert usable rather than noise, both of which are easy to
# regress silently:
#
#   1. The floor is PER HOST. The same 15 GiB free is healthy on a Pi (floor 5) and
#      critical on the builder (floor 20). This is the whole reason the alert is not a
#      percentage, so it gets a direct test: one poll, two hosts, one alert.
#   2. The query asks VictoriaMetrics to deduplicate by device and to drop tmpfs. The
#      impermanence hosts publish one filesystem under dozens of mountpoints (kelpy: 30),
#      and four of five hosts have a tmpfs `/`. Both facts live in the PromQL, so the
#      mock VM records the queries it is asked and the test asserts their shape — that is
#      the real contract with VictoriaMetrics, and asserting it on a mock's response
#      instead would only be testing the mock.
#
# Plus the quiet semantics shared with the other watchers: debounce before firing, one
# alert not a stream, a recovery notice, and a single re-alert on warn -> critical.
#
# No node-exporter or VictoriaMetrics runs. A captive HTTP server plays VictoriaMetrics,
# answering from files the test rewrites between phases, and a second one plays the
# hookshot webhook, appending every POST body to a log the test asserts against.

let
  vmPort = 8428;
  receiverPort = 9099;
  relayPort = 9098;

  # Mock VictoriaMetrics. Answers /api/v1/query from /tmp/avail.json or /tmp/pct.json
  # depending on which of the two queries it was asked, and appends every query it saw to
  # /tmp/queries.log so the test can assert the PromQL shape.
  vmMock = pkgs.writeShellScript "vm-mock" ''
    exec ${pkgs.python3}/bin/python3 - <<'PY'
    import http.server, json, urllib.parse
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            u = urllib.parse.urlparse(self.path)
            q = urllib.parse.parse_qs(u.query).get("query", [""])[0]
            with open("/tmp/queries.log", "a") as f:
                f.write(q + "\n")
            # The percentage query is the one carrying the `100 * (1 - …)` arithmetic.
            src = "/tmp/pct.json" if "100 *" in q else "/tmp/avail.json"
            try:
                with open(src) as f:
                    body = f.read()
            except FileNotFoundError:
                body = json.dumps({"data": {"result": []}})
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(body.encode())
        def log_message(self, *a):
            pass
    http.server.HTTPServer(("127.0.0.1", ${toString vmPort}), H).serve_forever()
    PY
  '';

  # Mock hookshot: one JSON object per line in /tmp/hooks.log.
  receiver = pkgs.writeShellScript "hook-receiver" ''
    exec ${pkgs.python3}/bin/python3 - <<'PY'
    import http.server
    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("content-length", 0))
            body = self.rfile.read(n).decode("utf-8", "replace")
            with open("/tmp/hooks.log", "a") as f:
                f.write(body + "\n")
            self.send_response(200)
            self.end_headers()
        def log_message(self, *a):
            pass
    http.server.HTTPServer(("127.0.0.1", ${toString receiverPort}), H).serve_forever()
    PY
  '';

  webhookFile = pkgs.writeText "webhook-url" "http://127.0.0.1:${toString receiverPort}/hook";

  # Mock ADR-0020 push relay. Records the Authorization header alongside the body so the
  # test can assert the ntfy publish shape the real relay requires: topic in the JSON
  # BODY (not the URL path) and a `tk_`-prefixed bearer token.
  relayMock = pkgs.writeShellScript "relay-mock" ''
    exec ${pkgs.python3}/bin/python3 - <<'PY'
    import http.server, json
    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("content-length", 0))
            body = self.rfile.read(n).decode("utf-8", "replace")
            rec = {"auth": self.headers.get("authorization", ""), "body": json.loads(body)}
            with open("/tmp/relay.log", "a") as f:
                f.write(json.dumps(rec) + "\n")
            self.send_response(200)
            self.end_headers()
        def log_message(self, *a):
            pass
    http.server.HTTPServer(("127.0.0.1", ${toString relayPort}), H).serve_forever()
    PY
  '';

  relayTokenFile = pkgs.writeText "relay-token" "s3cr3t";
  relayTopicFile = pkgs.writeText "relay-topic" "brave-otter-lamp";

  diskSpaceModule = self + /modules/nixos/profiles/monitoring/disk-space.nix;
in
pkgs.testers.runNixOSTest {
  name = "disk-space";

  nodes.watcher =
    { ... }:
    {
      imports = [ diskSpaceModule ];

      # A two-host stub registry: the split floors are the property under test.
      _module.args.settings = {
        nodes = {
          tiny = {
            hostName = "tiny";
            diskFloorGiB = 5;
          };
          big = {
            hostName = "big";
            diskFloorGiB = 20;
          };
        };
      };

      custom.profiles.monitoring-disk-space = {
        enable = true;
        webhookUrlFile = webhookFile;
        victoriaMetricsUrl = "http://127.0.0.1:${toString vmPort}";
        # Drive the ticks by hand so the debounce is exercised deterministically.
        failureThreshold = 2;
        outOfBand = {
          relayUrl = "http://127.0.0.1:${toString relayPort}";
          tokenFile = relayTokenFile;
          topicFile = relayTopicFile;
        };
      };
      # The timer would race the scripted phases; the test starts the service itself.
      systemd.timers.monitoring-disk-space-check.wantedBy = pkgs.lib.mkForce [ ];

      systemd.services.vm-mock = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = vmMock;
          Restart = "always";
        };
      };
      systemd.services.hook-receiver = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = receiver;
          # Not `always`: the test stops this to simulate the in-band path being down.
          Restart = "no";
        };
      };
      systemd.services.relay-mock = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = relayMock;
          Restart = "always";
        };
      };
    };

  testScript = ''
    import json

    GIB = 1024 ** 3

    def series(rows):
        """rows: (host, device, value) -> a VictoriaMetrics instant-query response."""
        return json.dumps({"data": {"result": [
            {"metric": {"host": h, "device": d}, "value": [0, str(v)]} for h, d, v in rows
        ]}})

    def publish(machine, avail_rows, pct_rows):
        machine.succeed(f"cat > /tmp/avail.json <<'EOF'\n{series(avail_rows)}\nEOF")
        machine.succeed(f"cat > /tmp/pct.json <<'EOF'\n{series(pct_rows)}\nEOF")

    def tick(machine, n=1):
        for _ in range(n):
            machine.succeed("systemctl start monitoring-disk-space-check")

    def hooks(machine):
        out = machine.succeed("cat /tmp/hooks.log 2>/dev/null || true").strip()
        return [json.loads(line)["text"] for line in out.splitlines() if line.strip()]

    def relay(machine):
        out = machine.succeed("cat /tmp/relay.log 2>/dev/null || true").strip()
        return [json.loads(line) for line in out.splitlines() if line.strip()]

    watcher.wait_for_unit("multi-user.target")
    watcher.wait_for_open_port(${toString vmPort})
    watcher.wait_for_open_port(${toString receiverPort})
    watcher.wait_for_open_port(${toString relayPort})

    with subtest("the PromQL deduplicates by device and excludes tmpfs"):
        publish(watcher, [("tiny", "/dev/sda1", 30 * GIB)], [("tiny", "/dev/sda1", 10.0)])
        tick(watcher)
        queries = watcher.succeed("cat /tmp/queries.log")
        assert "max by (host, device)" in queries, f"no per-device dedup in query: {queries}"
        assert "tmpfs" in queries, f"tmpfs not excluded in query: {queries}"
        assert "impermanence" in queries, f"impermanence device not excluded: {queries}"

    with subtest("a healthy device is silent"):
        assert hooks(watcher) == [], f"unexpected alert: {hooks(watcher)}"

    with subtest("the same free space is healthy on one host and critical on another"):
        # 15 GiB free: above tiny's 5 GiB floor (and its 10 GiB warn), below big's 20.
        publish(
            watcher,
            [("tiny", "/dev/sda1", 15 * GIB), ("big", "/dev/sdb1", 15 * GIB)],
            [("tiny", "/dev/sda1", 50.0), ("big", "/dev/sdb1", 97.0)],
        )
        tick(watcher)
        assert hooks(watcher) == [], "fired before the debounce elapsed"
        tick(watcher)
        fired = hooks(watcher)
        assert len(fired) == 1, f"expected exactly one alert, got {fired}"
        assert "[big]" in fired[0] and "critically low" in fired[0], fired[0]
        assert "tiny" not in fired[0], f"alerted on a host that was fine: {fired[0]}"

    with subtest("it does not re-alert while the condition persists"):
        tick(watcher, 3)
        assert len(hooks(watcher)) == 1, f"re-alerted: {hooks(watcher)}"

    with subtest("recovery is reported once"):
        publish(
            watcher,
            [("tiny", "/dev/sda1", 15 * GIB), ("big", "/dev/sdb1", 90 * GIB)],
            [("tiny", "/dev/sda1", 50.0), ("big", "/dev/sdb1", 20.0)],
        )
        tick(watcher)
        fired = hooks(watcher)
        assert len(fired) == 2, f"expected a recovery notice, got {fired}"
        assert "recovered" in fired[1] and "[big]" in fired[1], fired[1]
        tick(watcher, 2)
        assert len(hooks(watcher)) == 2, "repeated the recovery notice"

    with subtest("warn escalating to critical alerts again, once"):
        # 30 GiB free on big: under 2x its 20 GiB floor, so WARN.
        publish(
            watcher,
            [("big", "/dev/sdb1", 30 * GIB)],
            [("big", "/dev/sdb1", 94.0)],
        )
        tick(watcher, 2)
        fired = hooks(watcher)
        assert len(fired) == 3 and "is low" in fired[2], f"expected a warn, got {fired}"

        publish(
            watcher,
            [("big", "/dev/sdb1", 10 * GIB)],
            [("big", "/dev/sdb1", 98.0)],
        )
        tick(watcher, 2)
        fired = hooks(watcher)
        assert len(fired) == 4 and "critically low" in fired[3], f"expected escalation, got {fired}"
        tick(watcher, 2)
        assert len(hooks(watcher)) == 4, f"re-alerted after escalating: {hooks(watcher)}"

    with subtest("an alert the in-band path cannot carry goes out-of-band instead"):
        # The production failure this exists for: rk1b alerting ABOUT kelpy, over a
        # webhook that routes THROUGH kelpy. Ten such alerts were silently dropped in
        # 30 days before the fallback existed.
        watcher.succeed("systemctl stop hook-receiver")
        assert relay(watcher) == [], "relay used while the in-band path was healthy"

        publish(
            watcher,
            [("big", "/dev/sdb1", 1 * GIB)],
            [("big", "/dev/sdb1", 99.0)],
        )
        # Already reported critical, so clear the state to make this a fresh alert.
        watcher.succeed("rm -f /var/lib/monitoring-disk-space/*")
        tick(watcher, 2)

        sent = relay(watcher)
        assert len(sent) == 1, f"expected exactly one out-of-band publish, got {sent}"
        assert sent[0]["auth"] == "Bearer tk_s3cr3t", f"wrong bearer shape: {sent[0]['auth']}"
        assert sent[0]["body"]["topic"] == "brave-otter-lamp", f"topic not in body: {sent[0]}"
        assert "critically low" in sent[0]["body"]["message"], sent[0]["body"]["message"]
        assert "[big]" in sent[0]["body"]["message"], sent[0]["body"]["message"]

    with subtest("the in-band path is preferred again once it returns"):
        watcher.succeed("systemctl start hook-receiver")
        watcher.wait_for_open_port(${toString receiverPort})
        before = len(relay(watcher))
        publish(
            watcher,
            [("big", "/dev/sdb1", 90 * GIB)],
            [("big", "/dev/sdb1", 10.0)],
        )
        tick(watcher)
        assert len(relay(watcher)) == before, "used the out-of-band path while in-band was up"
        assert any("recovered" in h for h in hooks(watcher)), "recovery did not go in-band"
  '';
}

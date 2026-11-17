{
  self,
  pkgs,
  ...
}:

# The hermes overdue-job check (modules/nixos/profiles/monitoring/hermes-overdue.nix),
# forge inkpotmonkey/property#3 and the last unevidenced line of the handover checklist in
# docs/agents/agent-jobs.md.
#
# ⚠ WHAT THIS WATCHER IS FOR, and it is not "did the job say anything". The fleet's first
# agent job (`property-watch`) is a `--monitor-script` job, so a quiet market produces NO
# OUTPUT AT ALL and that is the design working — see ADR-0041 and the mode table in
# docs/agents/agent-jobs.md. A dead scheduler produces the byte-identical experience:
# nothing arrives. So the signal read here is never output and never freshness-of-output; it
# is hermes's own schedule bookkeeping — `next_run_at` falling into the past, and the cron
# ticker's `ticker_last_success` going stale. Case 2 below carries the design: a job that
# ran, printed nothing, and is next due tomorrow must be SILENT.
#
# The alert POSTs JSON to a webhook, and a tiny local HTTP receiver captures the bodies so
# the test can assert what was (and was not) sent — the same stub-VM recipe as
# parts/checks/git-annex-alert. Hermes itself never runs here: the whole input is two files
# under a HERMES_HOME the test writes by hand, with the schemas taken off the live rk1b host
# (`cron/jobs.json`, `cron/ticker_last_success`), so the fixtures are what hermes actually
# writes rather than what the ADR's prose describes — the ADR names `ticker_last_success`
# but puts `jobs.json` at the top of `$HERMES_HOME`, where it is not.

let
  receiverPort = 9099;
  hermesHome = "/tmp/hermes-home";

  # Mock hookshot: append every POST body to /tmp/hooks.log, one JSON object per line.
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
in
pkgs.testers.nixosTest {
  name = "hermes-overdue";
  nodes.machine =
    { ... }:
    {
      imports = [ (self + /modules/nixos/profiles/monitoring/hermes-overdue.nix) ];

      custom.profiles.monitoring-hermes-overdue = {
        enable = true;
        inherit hermesHome;
        webhookUrlFile = webhookFile;
        # An hour of slack past a job's due time, and fifteen minutes past the ticker's last
        # completed pass — the values rk1b runs, so the boundaries exercised below are the
        # boundaries the fleet actually keeps.
        graceSec = 3600;
        tickerStaleSec = 900;
      };

      systemd.services.hook-receiver = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = receiver;
      };
    };

  testScript = ''
    import json

    start_all()
    machine.wait_for_unit("hook-receiver.service")
    machine.wait_for_open_port(${toString receiverPort})
    machine.succeed("mkdir -p ${hermesHome}/cron")

    def now():
        return int(machine.succeed("date +%s").strip())

    def iso(offset):
        """An ISO-8601 instant `offset` seconds from the guest's now, as hermes writes it."""
        return machine.succeed(
            f"date -u -d '@{now() + offset}' +%Y-%m-%dT%H:%M:%S+00:00"
        ).strip()

    def write_jobs(*jobs):
        """cron/jobs.json in hermes's real schema (taken off rk1b), carrying only the fields
        the check is allowed to read."""
        payload = {"jobs": list(jobs), "updated_at": iso(0)}
        machine.succeed(
            "cat > ${hermesHome}/cron/jobs.json <<'EOF'\n"
            + json.dumps(payload, indent=2)
            + "\nEOF"
        )

    def job(next_in, last_ago=-3600, enabled=True, paused=False,
            name="property-watch", jid="705f90d79b87"):
        return {
            "id": jid,
            "name": name,
            "monitor_script": "property-watch.sh",
            "schedule": {"kind": "cron", "expr": "30 7 * * *", "display": "30 7 * * *"},
            "schedule_display": "30 7 * * *",
            "enabled": enabled,
            "state": "paused" if paused else "scheduled",
            "paused_at": iso(-7200) if paused else None,
            "paused_reason": "operator paused it" if paused else None,
            "next_run_at": iso(next_in),
            "last_run_at": iso(last_ago),
            "last_status": "ok",
            "timezone": "Europe/London",
        }

    def tick(ago):
        machine.succeed(
            "printf '%s.605699' $(( $(date +%s) - "
            + str(ago)
            + " )) > ${hermesHome}/cron/ticker_last_success"
        )

    def run():
        # systemd's default 5-starts-in-10s limit is a TEST artifact, not a property of the
        # watcher: the real timer fires quarter-hourly, while the cases below start it a
        # dozen times in a few seconds. Clear the counter rather than widening the unit's
        # limits to suit the harness.
        machine.succeed("systemctl reset-failed monitoring-hermes-overdue-check.service || true")
        machine.succeed("systemctl start monitoring-hermes-overdue-check.service")

    def hooks():
        return machine.succeed("cat /tmp/hooks.log 2>/dev/null || true")

    def clear():
        machine.succeed(": > /tmp/hooks.log")

    # ── 1. Healthy: due tomorrow, ticker beating ──────────────────────────────────────
    clear(); tick(30); write_jobs(job(next_in=70000))
    run()
    assert hooks().strip() == "", f"a healthy schedule must be silent, got: {hooks()!r}"

    # ── 2. ⚠ THE CASE THAT CARRIES THE DESIGN ────────────────────────────────────────
    # The job fired on time and printed NOTHING — a quiet market, which is the
    # monitor-script economy working exactly as intended. No output directory, no output
    # file, no monitor-state change. This must be as silent as case 1: a watcher that read
    # output freshness would alert here every quiet day and be muted within a week, taking
    # the real signal with it.
    clear(); tick(30)
    write_jobs(job(next_in=70000, last_ago=-120))
    machine.succeed("rm -rf ${hermesHome}/cron/output")
    run()
    assert hooks().strip() == "", f"a silent-but-scheduled job must not alert, got: {hooks()!r}"

    # ── 3. ⚠ THE CASE THIS WATCHER EXISTS FOR ────────────────────────────────────────
    # Three hours past due and the ticker is beating happily: hermes is up, the gateway is
    # `active`, and this one job simply did not fire. Indistinguishable from case 2 to
    # anybody reading their messages.
    clear(); tick(30); write_jobs(job(next_in=-10800, last_ago=-97200))
    run()
    got = hooks()
    assert "🚨" in got, got
    assert "property-watch" in got, got
    assert "705f90d79b87" in got, got
    assert "overdue" in got.lower(), got

    # ── 4. Still overdue → no re-spam ────────────────────────────────────────────────
    # The daily job stays overdue until somebody fixes it, and the timer runs every 15
    # minutes. Without the edge trigger that is ~96 identical messages a day into the room
    # every other watcher also writes to.
    clear(); run()
    assert hooks().strip() == "", f"a persisting overdue job must not re-alert, got: {hooks()!r}"

    # ── 5. Recovered → one ✅, then quiet ────────────────────────────────────────────
    clear(); write_jobs(job(next_in=70000, last_ago=-60))
    run()
    got = hooks()
    assert "✅" in got, got
    assert "property-watch" in got, got
    clear(); run()
    assert hooks().strip() == "", f"recovery must fire once, got: {hooks()!r}"

    # ── 6. Disabled and paused jobs are operator decisions ──────────────────────────
    # Both are overdue by three hours on the arithmetic. Paging about a schedule somebody
    # deliberately switched off is exactly how an alert room gets muted.
    clear(); write_jobs(job(next_in=-10800, enabled=False))
    run()
    assert hooks().strip() == "", f"a disabled job must be silent, got: {hooks()!r}"

    clear(); write_jobs(job(next_in=-10800, paused=True))
    run()
    assert hooks().strip() == "", f"a paused job must be silent, got: {hooks()!r}"

    # ── 7. The grace boundary, both sides ────────────────────────────────────────────
    # The comparison is `-gt` against graceSec, so 50 minutes late passes and 70 fails. A
    # one-character slip here decides whether a healthy daily trips the alarm or a dead one
    # never does.
    clear(); write_jobs(job(next_in=-3000))
    run()
    assert hooks().strip() == "", f"50m late is inside the grace window, got: {hooks()!r}"

    clear(); write_jobs(job(next_in=-4200))
    run()
    assert "OVERDUE" in hooks(), f"70m late is outside it, got: {hooks()!r}"

    # ── 8. ⚠ THE WHOLE-SCHEDULER CASE ───────────────────────────────────────────────
    # Every job's next_run_at is in the future, so the per-job loop sees nothing wrong — and
    # the ticker has not completed a pass in an hour, which means none of those slots will
    # ever be honoured. Only `ticker_last_success` can tell these apart, which is why the
    # ADR names it.
    clear(); tick(3600); write_jobs(job(next_in=70000))
    run()
    got = hooks()
    assert "ticker" in got, f"a stalled ticker must alert, got: {got!r}"
    assert "🚨" in got, got

    clear(); run()
    assert hooks().strip() == "", f"a persisting stalled ticker must not re-alert, got: {hooks()!r}"

    clear(); tick(10)
    run()
    assert "✅" in hooks(), f"a beating ticker must clear, got: {hooks()!r}"

    # ...and a ticker file that was never written at all is the same fault, not a crash.
    clear(); machine.succeed("rm ${hermesHome}/cron/ticker_last_success")
    run()
    assert "no successful pass" in hooks(), f"a missing ticker file must alert, got: {hooks()!r}"
    tick(10)

    # ── 9. No schedule at all is not a fault ────────────────────────────────────────
    # ADR-0041 records the gateway running for days with zero jobs. Alerting on it would page
    # the entire window between enabling hermes and handing it its first job.
    clear(); write_jobs()
    run()
    assert hooks().strip() == "", f"zero jobs must be silent, got: {hooks()!r}"

    clear(); machine.succeed("rm ${hermesHome}/cron/jobs.json")
    run()
    assert hooks().strip() == "", f"no jobs.json must be silent, got: {hooks()!r}"

    print(
        "SUCCESS: the overdue check reads next_run_at and ticker_last_success — it pages "
        "once for a job the scheduler did not fire and once for a stalled ticker, clears "
        "each with a notice, and stays silent for a job that ran and said nothing, for "
        "disabled and paused jobs, inside the grace window, and when there is no schedule."
    )
  '';
}

# The fleet's log-format catalogue: for each service whose own severity lives in its MESSAGE
# TEXT rather than in journald's PRIORITY, the anchored regex that finds it.
#
# WHY A CATALOGUE AND NOT A PATTERN PER PROFILE. Three reasons, in order of how much they
# matter:
#
#   1. ⚠ THE ESCAPING. A pattern must be written as an INDENTED (`''`) Nix string. In a
#      regular `"..."` string Nix eats `\d` into a literal `d` — no error, no warning, and the
#      resulting regex matches nothing at all, which looks exactly like a service that has
#      stopped logging errors. Keeping every pattern in one file keeps that trap in one place
#      with a comment on it, instead of once per profile.
#   2. SHARING. Home Assistant and Music Assistant log in the same format (Music Assistant is
#      built on Home Assistant's core), and more than one profile can own a postgres. A
#      catalogue lets them reference one verified pattern rather than drift two copies.
#   3. TESTABILITY. `parts/checks/log-levels` runs every pattern here against a corpus of REAL
#      lines captured from the fleet's own VictoriaLogs, so a format that changes under an
#      upgrade fails the build instead of silently relabelling nothing. That check is the
#      reason to put the patterns somewhere a check can enumerate them.
#
# ── HOW TO ADD ONE ───────────────────────────────────────────────────────────────────────────
#   1. Find the real format. Don't guess, and don't read the upstream source: ask the fleet
#      what it is actually receiving, because a service's format depends on its version, its
#      config and whether something strips its colours:
#        ssh rk1b 'curl -s http://localhost:9428/select/logsql/query \
#          --data-urlencode "query=unit:\"<unit>\" | fields _msg | limit 5" \
#          --data-urlencode "start=24h"'
#   2. ⚠ ANCHOR IT on the line prefix, never on the level word alone. A fleet-wide
#      `_msg:~"ERROR"` sweep once named blocky the worst offender by two orders of magnitude;
#      every one of those 57,000 lines was the substring inside `response_code=NOERROR`.
#   3. Name the capture group `lvl`, and spell the levels exactly as the service does. They are
#      mapped onto the dashboards' vocabulary by monitoring/client.nix, which leaves `level`
#      ALONE for a token it does not recognise — so a missing spelling costs visibility, never
#      a bogus label.
#   4. Add a real line to parts/checks/log-levels/corpus.json with the level it should become,
#      and a case for a line that must NOT match.
#   5. Declare it in the service's OWN profile, not here:
#        custom.profiles.monitoring-client.levelFromMessage."<unit>" =
#          self.lib.logLevelPatterns.<name>;
#      The catalogue holds formats; which units a host actually runs is the profile's business.
{
  # Python's logging module as Home Assistant configures it, which Music Assistant inherits:
  #   2026-11-11 17:26:59.365 ERROR (MainThread) [homeassistant.components.foo] …
  #   \x1b[33m2026-11-10 20:56:54.950 WARNING (MainThread) [music_assistant.tasks] …\x1b[0m
  # The optional ANSI prefix is what makes one pattern do for both: Home Assistant's output is
  # plain and Music Assistant colours every line by level. Anchored through the `(` of the
  # thread name, which is what keeps it off a traceback's continuation lines — those stay at
  # their journald level on purpose (one traceback is one error, not twenty).
  pythonLogging = ''^(?:\x1b\[[0-9;]*m)?\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ (?P<lvl>DEBUG|INFO|WARNING|ERROR|CRITICAL) \('';

  # blocky (logrus text output), level right-padded so the gap varies:
  #   [2026-11-11 02:44:43]  INFO list_cache: import succeeded count=78229 …
  #   [2026-11-11 02:44:43] ERROR …
  # ⚠ The anchor is the whole point here. blocky's query log carries `response_code=NOERROR`
  # on every resolved query — 1.5 million lines in 30 days — and an unanchored pattern turns
  # all of them into errors. Anchored, the same window holds 10,939 real ERROR lines that were
  # invisible to every error view on the fleet.
  blocky = ''^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]\s+(?P<lvl>TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|PANIC)\s'';

  # Go's structured logger (log/slog) in logfmt mode, which is what prometheus-node-exporter
  # and its siblings use since they moved off go-kit:
  #   time=2026-11-11T01:03:15.695+01:00 level=ERROR source=collector.go:168 msg="collector failed" …
  # Anchored at `^time=` rather than on a bare `level=` so a `level=` inside a quoted msg
  # cannot promote the line.
  goSlog = ''^time=\S+ level=(?P<lvl>DEBUG|INFO|WARN|ERROR)\s'';

  # PostgreSQL's stderr log, as the NixOS module leaves it (`log_line_prefix = '[%p] '`):
  #   [536004] WARNING:  database "template1" has a collation version mismatch
  # DETAIL/HINT/STATEMENT/CONTEXT lines deliberately do NOT match: they are continuation lines
  # of the message above them, and counting each one separately would treble every warning.
  postgres = ''^\[\d+\] (?P<lvl>LOG|INFO|NOTICE|WARNING|ERROR|FATAL|PANIC):'';

  # gluetun (and other Go services using its logger shape):
  #   2026-11-11T12:02:21Z INFO [firewall] removing allowed port 38839...
  #   2026-11-11T08:37:09Z ERROR [port forwarding] adding port mapping: …
  gluetun = ''^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z (?P<lvl>DEBUG|INFO|WARN|ERROR|FATAL)\s'';

  # Vaultwarden (Rust, its own bracketed format):
  #   [2026-11-11 14:50:17.953][vaultwarden::auth][ERROR] Token has expired
  vaultwarden = ''^\[[^\]]*\]\[[^\]]*\]\[(?P<lvl>TRACE|DEBUG|INFO|WARN|ERROR)\]\s'';

  # LiteLLM's proxy logger. Note its two formats: this one, and uvicorn's bare
  # `INFO:     127.0.0.1 - "GET /metrics/"` access lines, which are already `info` and
  # deliberately not matched — promoting them would be a no-op over a lot of volume.
  #   09:54:54 - LiteLLM Proxy:ERROR: auth_exception_handler.py:207 - … Malformed API Key …
  litellm = ''^\d{2}:\d{2}:\d{2} - [^:\n]+:(?P<lvl>DEBUG|INFO|WARNING|ERROR|CRITICAL):\s'';

  # matrix-hookshot (level first, then a 4-field timestamp):
  #   ERROR 16:37:00:642 [GitHubWatcher] An error occurred getting notifications: …
  hookshot = ''^(?P<lvl>DEBUG|INFO|WARN|ERROR|FATAL) \d{2}:\d{2}:\d{2}:\d{3}\s'';

  # NestJS, which is immich's server and microservices. Heavily ANSI-coloured, with the level
  # right-padded between escape sequences:
  #   \x1b[32m[Nest] 448044  - \x1b[39m11/11/2026, 1:03:00 AM \x1b[32m    LOG\x1b[39m \x1b[33m[Context]\x1b[39m …
  # ⚠ The `[Nest]` anchor is load-bearing. Immich dumps multi-line Postgres notices whose
  # continuation lines read `  severity: 'WARNING',` — 68 of them in one day, and every one
  # would be a false error without it.
  nestjs = ''\[Nest\].*?\x1b\[\d+m\s*(?P<lvl>LOG|DEBUG|VERBOSE|WARN|ERROR|FATAL)\x1b'';
}

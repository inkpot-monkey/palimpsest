{
  self,
  pkgs,
  inputs,
  ...
}:

# Presence-aware git-annex replication alerting
# (modules/nixos/profiles/monitoring/git-annex-alert.nix).
#
# The profile was "proven live, untested" until the presence split made its behaviour
# genuinely branchy, and that branch is the whole point of surfacing a WORKSTATION's
# annex: a laptop is on-demand, its user-run exporter only publishes while the session
# is up, so absent/stale metrics there are expected quiet — NOT a dead exporter. This
# pins the split:
#
#   on-demand + fresh + bad signal   → pages (broke while the laptop was in use)
#   on-demand + stale / absent file  → SILENT (closed lid, not a fault)
#   on-demand + healthy again        → recovery notice (state was left "down", not reset)
#   always-on + stale / absent file  → pages "unmonitored" (a server exporter genuinely died)
#
# It also covers discovery of a HOME-MANAGER repo (the across-users half): the check
# watches git-annex-<user>-<repo>.prom, published by the user-run exporter, exactly as
# it watches a system repo's git-annex-<repo>.prom.
#
# The alert POSTs JSON to a webhook; a tiny local HTTP receiver captures the bodies to a
# log so the test can assert what was (and was not) sent. No git-annex actually runs —
# the home-manager repos exist only so the check DISCOVERS their tags, and every .prom is
# written by hand to script the exact freshness/health the branch under test needs.

let
  metricsDir = "/var/lib/prometheus-node-exporter-text-files";
  receiverPort = 9099;

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

  alertModule = self + /modules/nixos/profiles/monitoring/git-annex-alert.nix;
  homeGitAnnex = self + /modules/homeManager/git-annex/default.nix;

  # A host that runs the alert plus a captive webhook receiver, watching one home-manager
  # repo owned by `user`. The repo is declared (so discovery finds `<user>-<repo>`) but
  # never activated — its .prom files are written by the test.
  mkNode =
    { presence, user }:
    { ... }:
    {
      imports = [
        inputs.home-manager.nixosModules.home-manager
        alertModule
      ];

      users.users.${user} = {
        isNormalUser = true;
        home = "/home/${user}";
      };

      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.${user} =
        { ... }:
        {
          imports = [ homeGitAnnex ];
          home.stateVersion = "24.05";
          services.git-annex = {
            enable = true;
            repositories.annex = {
              path = "/home/${user}/Annex";
              description = "${user}-annex";
            };
            # Enables discovery by the alert; the user-run writer itself never starts
            # (no session), so the test owns every .prom.
            metrics.enable = true;
          };
        };

      custom.profiles.monitoring-git-annex-alert = {
        enable = true;
        inherit presence metricsDir;
        webhookUrlFile = webhookFile;
        # One bad read pages — the two-tick debounce is pre-existing and orthogonal to the
        # presence branch under test.
        failureThreshold = 1;
        intervalSec = 60;
        staleAfterSec = 120;
      };

      systemd.tmpfiles.rules = [ "d ${metricsDir} 0755 root root -" ];
      systemd.services.hook-receiver = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = receiver;
      };
    };
in
pkgs.testers.nixosTest {
  name = "git-annex-alert";
  nodes = {
    ondemand = mkNode {
      presence = "on-demand";
      user = "alice";
    };
    alwayson = mkNode {
      presence = "always-on";
      user = "bob";
    };
  };

  testScript = ''
    start_all()
    for node in (ondemand, alwayson):
        node.wait_for_unit("hook-receiver.service")
        node.wait_for_open_port(${toString receiverPort})

    # Write a .prom for a home repo tag, dating its check timestamp `age` seconds ago.
    def write_prom(node, user, assistant_up, age):
        ts = int(node.succeed("date +%s").strip()) - age
        node.succeed(
            f"cat > ${metricsDir}/git-annex-{user}-annex.prom <<EOF\n"
            f'git_annex_repo_info{{repo="annex",user="{user}"}} 1\n'
            f'git_annex_check_timestamp_seconds{{repo="annex",user="{user}"}} {ts}\n'
            f'git_annex_assistant_up{{repo="annex",user="{user}"}} {assistant_up}\n'
            "EOF"
        )

    def run_check(node):
        node.succeed("systemctl start monitoring-git-annex-alert-check.service")

    def hooks(node):
        return node.succeed("cat /tmp/hooks.log 2>/dev/null || true")

    def clear(node):
        node.succeed(": > /tmp/hooks.log")

    # === on-demand: the workstation branch =================================
    # (a) FRESH + assistant down → pages. This is "the assistant died while I was
    #     actually using the laptop", the one on-demand failure worth waking for.
    clear(ondemand)
    write_prom(ondemand, "alice", assistant_up=0, age=10)
    run_check(ondemand)
    got = hooks(ondemand)
    assert "assistant is NOT running" in got, f"expected a page, got: {got!r}"
    assert "🚨" in got, got

    # (b) ABSENT file → silent. A closed lid stops the writer; on-demand must not read
    #     that as a dead exporter. Also proves state is NOT reset: no spurious recovery.
    clear(ondemand)
    ondemand.succeed("rm ${metricsDir}/git-annex-alice-annex.prom")
    run_check(ondemand)
    assert hooks(ondemand).strip() == "", f"absent file must be silent on-demand, got: {hooks(ondemand)!r}"

    # (c) FRESH + healthy → recovery. The assistant series was left "down" by (a) and
    #     survived the absent tick (b), so reading 1 now clears it with a ✅.
    clear(ondemand)
    write_prom(ondemand, "alice", assistant_up=1, age=10)
    run_check(ondemand)
    got = hooks(ondemand)
    assert "assistant is running again" in got, f"expected recovery, got: {got!r}"
    assert "✅" in got, got

    # (d) STALE file → silent. Old data on an on-demand host is expected quiet, even
    #     though the assistant now reads 0 in it — the staleness gate fires first.
    clear(ondemand)
    write_prom(ondemand, "alice", assistant_up=0, age=100000)
    run_check(ondemand)
    assert hooks(ondemand).strip() == "", f"stale file must be silent on-demand, got: {hooks(ondemand)!r}"

    # === always-on: the server branch is unchanged ========================
    # (e) STALE file → pages "unmonitored". On a server, stale means the exporter
    #     genuinely died — the blind spot the whole check exists to close.
    clear(alwayson)
    write_prom(alwayson, "bob", assistant_up=1, age=100000)
    run_check(alwayson)
    got = hooks(alwayson)
    assert "stale" in got, f"always-on must page on stale data, got: {got!r}"

    # (e2) FRESH + healthy → recovery, resetting the meta state so the next fault pages
    #      again (stale and absent share one meta key: without this, "no re-alert while
    #      already down" would correctly swallow the absent page below).
    clear(alwayson)
    write_prom(alwayson, "bob", assistant_up=1, age=10)
    run_check(alwayson)
    assert "fresh again" in hooks(alwayson), f"expected meta recovery, got: {hooks(alwayson)!r}"

    # (f) ABSENT file → pages "UNMONITORED". A repo that never published is as loud as
    #     one whose exporter died — absence of data is itself the alarm.
    clear(alwayson)
    alwayson.succeed("rm ${metricsDir}/git-annex-bob-annex.prom")
    run_check(alwayson)
    assert "UNMONITORED" in hooks(alwayson), f"always-on must page on absent data, got: {hooks(alwayson)!r}"

    print("SUCCESS: presence-aware alerting — on-demand suppresses stale/absent and "
          "pages only fresh faults; always-on still pages on stale/absent; home-repo "
          "discovery and recovery verified.")
  '';
}

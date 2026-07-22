# The health signal a git-annex repo has never had (palimpsest#60).
#
# Every git-annex bug found during the music bring-up had the same shape: the repo
# stops replicating while everything reports healthy. `git-annex-init-*` stays
# `active`, no unit fails, the logs are quiet, and content simply stops moving. The
# module fails loudly at *init* and has no notion of *ongoing* health, so the only
# way any of them surfaced was somebody happening to look.
#
# This test pins the two signals that would have caught them, and — the point — it
# asserts they go RED, not just that they exist:
#
#   assistant_up      → the assistant left dead by a deploy that re-ran init (4efcec0)
#   remote_reachable  → a remote URL that never reached the repo (3b05044), and the
#                       SSH identity missing on a first deploy (5269fde). Both present
#                       as a healthy-looking repo whose pushes go nowhere.
#
# `git ls-remote` is the probe because it exercises the whole outbound path the way a
# sync does — DNS, the annex identity, the peer's git-annex user — every tick,
# regardless of whether anything changed. That independence from activity is what
# makes it a heartbeat, and it is why the exporter does not alert on the age of
# last_commit (see the module header).
{ pkgs, ... }:
let
  helper = import ./lib.nix { inherit pkgs; };
  repoPath = "/var/lib/git-annex/lib";
  metricsDir = "/var/lib/prometheus-node-exporter-text-files";
  promFile = "${metricsDir}/git-annex-lib.prom";

  # The real dir is owned by node-exporter (the monitoring-exporters profile creates
  # it). These nodes have no monitoring profile — the git-annex module is standalone —
  # so stand the directory up with the same mode the profile uses. The exporter must
  # treat it as somebody else's directory either way.
  textfileDir = {
    systemd.tmpfiles.rules = [ "d ${metricsDir} 0775 root root -" ];
  };
in
pkgs.testers.nixosTest {
  name = "git-annex-metrics";
  nodes = {
    source =
      { ... }:
      {
        imports = [
          helper.commonNode
          textfileDir
        ];
        services.git-annex.repositories.lib = {
          path = repoPath;
          description = "source";
          assistant = true;
        };
      };

    replica =
      { ... }:
      {
        imports = [
          helper.commonNode
          textfileDir
        ];
        services.git-annex.repositories.lib = {
          path = repoPath;
          description = "replica";
          assistant = true;
          remotes = [
            {
              name = "source";
              url = "git-annex@source:${repoPath}";
            }
          ];
        };
      };
  };

  testScript = ''
    start_all()

    for node in (source, replica):
        node.wait_for_unit("git-annex-init-lib.service")
        node.wait_for_unit("git-annex-assistant-lib.service")

    # Drive the oneshot directly rather than waiting on its timer: the timer only
    # fixes *when* a check happens, and every assertion below is about *what* it
    # reports. Waiting on it would trade minutes of test runtime for no coverage.
    def check(node):
        node.succeed("systemctl start git-annex-metrics-lib.service")
        return node.succeed("cat ${promFile}")

    # --- healthy baseline ---------------------------------------------------
    metrics = check(replica)
    assert 'git_annex_assistant_up{repo="lib"} 1' in metrics, metrics
    assert 'git_annex_remote_reachable{repo="lib",remote="source"} 1' in metrics, metrics
    assert "git_annex_last_commit_timestamp_seconds" in metrics, metrics
    assert "git_annex_check_timestamp_seconds" in metrics, metrics

    # node-exporter runs as its own user and must be able to READ the published file.
    # mktemp creates 0600, so a missing widen-before-rename publishes a metric that is
    # never scraped and a panel that says "No data" — silent, and exactly the class of
    # failure this whole test exists to prevent.
    mode = replica.succeed("stat -c %a ${promFile}").strip()
    assert mode == "644", f"published metrics must be world-readable for node-exporter, got {mode}"

    # A repo with no remotes emits no reachability series at all — the absence is
    # meaningful (nothing to reach), not a 0.
    assert "git_annex_remote_reachable" not in check(source)

    # --- the assistant dies (4efcec0) ---------------------------------------
    # Precisely the production failure: stop the assistant and change NOTHING else.
    # Init stays active, nothing fails, and before this metric existed the host looked
    # perfectly healthy while the repo had stopped replicating.
    replica.succeed("systemctl stop git-annex-assistant-lib.service")
    replica.succeed("systemctl is-active git-annex-init-lib.service")  # still 'active'
    assert 'git_annex_assistant_up{repo="lib"} 0' in check(replica)

    replica.succeed("systemctl start git-annex-assistant-lib.service")
    assert 'git_annex_assistant_up{repo="lib"} 1' in check(replica)

    # --- the remote rots (3b05044 / 5269fde) --------------------------------
    # Point the remote at a host that does not exist. This stands in for both bugs:
    # what the repo *has* in .git/config is unusable, whatever the declared config says.
    # The assistant keeps running and the repo keeps looking fine.
    replica.succeed(
        "sudo -u git-annex git -C ${repoPath} remote set-url source git-annex@nosuchhost:/nope"
    )
    metrics = check(replica)
    assert 'git_annex_remote_reachable{repo="lib",remote="source"} 0' in metrics, metrics
    assert 'git_annex_assistant_up{repo="lib"} 1' in metrics, metrics

    replica.succeed(
        "sudo -u git-annex git -C ${repoPath} remote set-url source git-annex@source:${repoPath}"
    )
    assert 'git_annex_remote_reachable{repo="lib",remote="source"} 1' in check(replica)
  '';
}

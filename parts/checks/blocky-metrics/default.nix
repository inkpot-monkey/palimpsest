# blocky_* collection (palimpsest#39).
#
# blocky has always exposed Prometheus metrics on its HTTP port, but nothing scraped
# them — the metrics existed and were thrown away. The load-bearing behaviour here is
# the whole path, not the config attribute: blocky really serves `blocky_*` on that
# port, and VictoriaMetrics — configured by monitoring/server.nix, unedited — really
# ingests a series for EVERY declared fleet resolver (settings.dns.nameserverHosts).
#
# The fleet is deliberately multi-resolver (ADR-0023), so "DNS is down" and "one
# resolver is degraded" are different incidents; a job that collected only the local
# blocky could not tell them apart. Both resolvers' MagicDNS names are pointed at this
# VM's own blocky so the REAL target list is exercised — a target that resolved to
# nothing would otherwise look exactly like a target that was never configured.
#
# What this cannot prove: the cross-host hop. blocky's metrics port is opened on
# tailscale0 only, and a test VM has no tailscale0 — a second node would have to reach it
# over a plain interface the firewall deliberately does not open, so a two-node rig would
# be testing a path the fleet does not use. Remote reachability stays a deploy-time fact.
{
  self,
  pkgs,
  inputs,
  ...
}:

let
  inherit (pkgs) lib;
  inherit (self) settings;

  resolvers = settings.dns.nameserverHosts;

  # blocky's HTTP port, written out rather than read back from settings.dns.httpPort: a
  # test that derived the port from the same attribute the module scrapes could never
  # catch a wrong one. Stated once so a port change fails on the assertions below rather
  # than on whichever copy was missed.
  httpPort = 4001;

  # The scrape target name server.nix builds for a resolver.
  targetName = host: "${host}.${settings.tailnet}:${toString httpPort}";

  # POST the match[] selector rather than encoding it into the URL: these selectors are
  # all braces and quotes, and /api/v1/export reads raw samples (no -search.latencyOffset
  # shift), so a freshly-ingested scrape is visible immediately.
  export =
    selector: "curl -fsS http://127.0.0.1:8428/api/v1/export --data-urlencode 'match[]=${selector}'";
in
pkgs.testers.nixosTest {
  name = "blocky-metrics";

  nodes.resolver =
    { lib, ... }:
    {
      imports = [
        (self + /modules/nixos/profiles/blocky.nix)
        (self + /modules/nixos/profiles/monitoring/server.nix)
        inputs.sops-nix.nixosModules.sops
        # server.nix has a persistence branch gated on the impermanence profile. The gate is
        # off here, but the module system resolves the option path behind it either way, so
        # `environment.persistence` has to exist. Take the upstream module and declare the
        # gate directly — the profile itself reads `inputs` in its own `imports`, which a
        # test node can only supply as a module argument, and that recurses.
        inputs.impermanence.nixosModules.impermanence
        { options.custom.profiles.impermanence.enable = lib.mkEnableOption "impermanence (off here)"; }
      ];

      # Both profiles read flake specialArgs; nixosTest nodes don't inherit them.
      _module.args = {
        inherit self inputs settings;
      };

      custom.profiles = {
        blocky.enable = true;
        monitoring-server.enable = true;
      };

      # Point the fleet's resolver names at this VM's own blocky, so the unedited scrape
      # config resolves and every declared resolver is genuinely scraped.
      networking.hosts."127.0.0.1" = map (h: "${h}.${settings.tailnet}") resolvers;

      # Everything the scrape path doesn't need. Grafana in particular would demand the
      # monitoring sops secrets (and the `grafana` owner) at activation.
      services.grafana.enable = lib.mkForce false;
      services.victorialogs.enable = lib.mkForce false;
      services.prometheus.exporters.blackbox.enable = lib.mkForce false;
      sops.secrets = lib.mkForce { };

      # The real denylist is fetched over the internet, which a VM doesn't have — blocky
      # would spend its startup retrying. Swap the SOURCE, not the blocking config, so
      # the denylist-size metrics still have something to count.
      services.blocky.settings.blocking.denylists.ads = lib.mkForce [
        (toString (pkgs.writeText "ads.hosts" "0.0.0.0 ads.example\n"))
      ];

      # blocky.nix picks its package out of `inputs.nixpkgs.legacyPackages.<system>` (the
      # profile pins blocky fleet-wide), which needs the node's platform spelled out —
      # nixosTest hands nodes a `pkgs` rather than a hostPlatform.
      nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform;

      virtualisation.memorySize = 2048;
      # VictoriaMetrics keeps the profile's real 10 GiB free-space valve
      # (-storage.minFreeDiskSpaceBytes, ADR-0021), and refuses ALL writes below it — on a
      # default-sized test disk the storage comes up read-only and nothing is ever ingested.
      # Give the VM a (sparse) disk above the valve rather than weakening the flag.
      virtualisation.diskSize = 16384;
    };

  testScript = ''
    resolver.wait_for_unit("blocky.service")
    resolver.wait_for_open_port(${toString httpPort})

    # 1. blocky really publishes metrics on its HTTP port, at the default /metrics path
    #    the scrape job relies on.
    exposed = resolver.succeed("curl -fsS http://127.0.0.1:${toString httpPort}/metrics")
    names = sorted({
        line.split("{")[0].split(" ")[0]
        for line in exposed.splitlines()
        if line.startswith("blocky_")
    })
    assert len(names) > 3, f"blocky exposed almost no metrics: {names}"
    print("blocky exposes: " + ", ".join(names))

    resolver.wait_for_unit("victoriametrics.service")
    resolver.wait_for_open_port(8428)

    export_up = """${export ''up{job="blocky"}''}"""

    # 2. The scrape lands at all. Checked first so a missing job fails here, once,
    #    rather than once per resolver below.
    resolver.wait_until_succeeds(export_up + " | grep -q blocky", timeout=180)

    # 3. EVERY declared fleet resolver is a target — not just the local one — and each is
    #    labelled by its own MagicDNS name, so the boards' instance→host rewrite tells the
    #    two apart. Waited for per host: targets are scraped on independent schedules, so
    #    a single snapshot taken the moment the first one lands races the rest.
    for host in [${lib.concatMapStringsSep ", " (h: ''"${targetName h}"'') resolvers}]:
        resolver.wait_until_succeeds(
            export_up + f""" | grep -q '"instance":"{host}"'""", timeout=120
        )

    # 4. And the series that arrived are blocky's own — a job that resolved and returned
    #    nothing useful would still have produced `up` above.
    series = resolver.succeed("""${export ''{__name__=~"blocky_.*", job="blocky"}''}""")
    assert "blocky_" in series, f"no blocky_* samples were ingested: {series}"

    print("SUCCESS: every fleet resolver's blocky_* metrics are collected.")
  '';
}

# blocky's tailscale-service hosts file is regenerated on a timer, and the generator
# restarts blocky to pick up changes — blocky does not hot-reload `hostsFile`.
#
# The load-bearing behaviour is the CONDITION on that restart: only when the resolved
# IPs actually changed. A generator that restarts unconditionally bounces the fleet's
# DNS every 30 minutes (palimpsest#165) — a ~1s resolution gap each time, and blocky's
# counters reset with it, which is what made the DNS Resolvers board's two error panels
# disagree (raw `blocky_error_total` since the last restart vs a `rate()` over an hour
# that sums across them).
#
# The peer lookup is stubbed: `tailscale ip -4 <peer>` needs a netmap, which a test VM
# has no way to have. Everything downstream of the lookup — the retry loop, the compare,
# the swap, the restart decision — is the real generated script, and the stub's answer is
# swung mid-test so the test proves BOTH directions (unchanged → no restart, changed →
# restart) rather than passing on a generator that never restarts anything.
{
  self,
  pkgs,
  inputs,
  ...
}:

let
  inherit (pkgs) lib;
  inherit (self) settings;

  # The IP the stub reports for every peer, read from a file the test script rewrites.
  stubIpFile = "/run/stub-tailscale-ip";

  stubTailscale = pkgs.writeShellScriptBin "tailscale" ''
    if [ "$1" = "ip" ]; then
      cat ${stubIpFile}
      exit 0
    fi
    exit 1
  '';

  servicesHostsFile = "/run/blocky-services/tailscale-services.hosts";

  privateServices = lib.attrNames settings.services.private;
in
pkgs.testers.nixosTest {
  name = "blocky-service-hosts";

  nodes.resolver =
    { lib, ... }:
    {
      imports = [
        (self + /modules/nixos/profiles/blocky.nix)
        inputs.sops-nix.nixosModules.sops
      ];

      _module.args = {
        inherit self inputs settings;
      };

      custom.profiles.blocky.enable = true;

      # The generator branch is gated on `services.tailscale.enable`. Declare tailscale so
      # the unit exists, but keep tailscaled itself out of the boot: the stub below is what
      # answers peer lookups, and a real daemon with no control plane would only add a
      # login-less service to wait on.
      services.tailscale.enable = true;
      systemd.services.tailscaled.wantedBy = lib.mkForce [ ];

      # Shadow the real `tailscale` in the generator's PATH only.
      systemd.services.blocky-service-hosts.path = lib.mkBefore [ stubTailscale ];

      # blocky.nix pins its package out of `inputs.nixpkgs.legacyPackages.<system>`, which
      # needs the node's platform spelled out — nixosTest hands nodes a `pkgs`.
      nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform;

      # The real denylist is fetched over the internet, which a VM does not have; blocky
      # would spend its startup retrying and the restart timings below would measure that.
      services.blocky.settings.blocking.denylists.ads = lib.mkForce [
        (toString (pkgs.writeText "ads.hosts" "0.0.0.0 ads.example\n"))
      ];

      sops.secrets = lib.mkForce { };

      system.activationScripts.stub-tailscale-ip = ''
        mkdir -p /run
        echo 100.64.0.1 > ${stubIpFile}
      '';
    };

  testScript = ''
    def blocky_pid():
        return resolver.succeed(
            "systemctl show -p MainPID --value blocky.service"
        ).strip()

    resolver.wait_for_unit("blocky.service")

    # 1. First run populates the hosts file from the (stubbed) peer lookup. Every private
    #    service in settings gets a line — a partial file would resolve some names and
    #    silently drop the rest.
    resolver.succeed("systemctl start blocky-service-hosts.service")
    hosts = resolver.succeed("cat ${servicesHostsFile}")
    for name in [${
      lib.concatMapStringsSep ", " (
        s: ''"${lib.toLower s}.${settings.nodes.kelpy.domain}"''
      ) privateServices
    }]:
        assert name in hosts, f"{name} missing from the generated hosts file:\n{hosts}"
    assert hosts.count("100.64.0.1") == ${toString (builtins.length privateServices)}, (
        f"expected one stub IP per private service:\n{hosts}"
    )

    # 2. THE REGRESSION: a second run with nothing changed must not restart blocky.
    #    `cmp` decides that, and `cmp` lives in diffutils — if it is not in the unit's
    #    PATH the compare fails open and every timer tick bounces the resolver.
    before = blocky_pid()
    resolver.succeed("systemctl start blocky-service-hosts.service")
    after = blocky_pid()
    assert before == after, (
        f"blocky was restarted ({before} -> {after}) by a generator run that changed "
        "nothing — the hosts-file compare is failing open"
    )

    # 3. And the guard is a compare, not a switched-off restart: swing the stub's answer
    #    and blocky must come back on the new IPs.
    resolver.succeed("echo 100.64.0.2 > ${stubIpFile}")
    resolver.succeed("systemctl start blocky-service-hosts.service")
    resolver.wait_for_unit("blocky.service")
    changed = blocky_pid()
    assert changed != after, (
        f"blocky was NOT restarted ({after} -> {changed}) after the resolved IPs changed "
        "— it would keep serving the stale addresses"
    )
    assert "100.64.0.2" in resolver.succeed("cat ${servicesHostsFile}")

    print("SUCCESS: the generator restarts blocky on a real IP change and only then.")
  '';
}

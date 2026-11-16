{
  self,
  pkgs,
  ...
}:

# Every datasource rk1b PROVISIONS must resolve to a plugin the configured Grafana actually
# ships. Asserted against the real host config and the real package, not a restatement.
#
# WHY THIS EXISTS. On 2026-11-10 the fleet's nixpkgs bump moved grafana 13.1.6 -> 13.3.0, and
# that package ships NO PROMETHEUS DATASOURCE PLUGIN. Grafana 13.2 externalised its core
# datasource plugins, and nixpkgs' 13.3.0 update dropped `yarn run plugins:build-bundled` from
# `postBuild` while `postInstall` still copies only `public conf`, so nothing builds or installs
# them. Measured on the two store paths, `share/grafana/public/app/plugins/datasource/` went
# from 20 entries to 7, prometheus among the casualties.
#
# ⚠ AND NOTHING WENT RED. The package built. The module evaluated. `systemctl is-active grafana`
# said `active`, with no error in its journal beyond one `level=error` line at startup that
# named a plugin nobody was looking for. VictoriaMetrics kept scraping and kept answering the
# identical query on :8428. The only symptom was every metric panel on every dashboard reading
# "No data" — six days of blind monitoring, and the one thing that WOULD have caught it on the
# day of the bump is the assertion below. That is the whole case for this check: a datasource
# is a contract between a provisioned name and a plugin on disk, and nothing else in the build,
# the deploy or the runtime verifies the two halves meet.
#
# Deliberately NOT a VM test. The failure is a property of the package's file tree, so a VM
# would add minutes of boot to prove something `ls` proves — and the existing VM checks all
# force `services.grafana.enable = false` precisely because booting it drags in the monitoring
# sops secrets. The current hold is recorded in docs/holds.md#grafana.

let
  inherit (pkgs) lib;

  grafana = self.nixosConfigurations.rk1b.config.services.grafana;

  # What the host provisions, verbatim. Adding a datasource to server.nix extends this test
  # rather than bypassing it, which is the point of reading it off the config.
  declaredTypes = lib.unique (map (d: d.type) grafana.provision.datasources.settings.datasources);

  # Where a plugin may legitimately live: bundled in the package, or supplied declaratively.
  # `declarativePlugins` entries carry a versioned name but a plugin id'd directory inside.
  pluginInputs = lib.concatStringsSep " " (map toString grafana.declarativePlugins);
in

pkgs.runCommand "check-grafana-datasource-plugins"
  {
    nativeBuildInputs = [ ];
    inherit pluginInputs;
    grafanaPkg = grafana.package;
    types = lib.concatStringsSep " " declaredTypes;
  }
  ''
    core="$grafanaPkg/share/grafana/public/app/plugins/datasource"

    if [ ! -d "$core" ]; then
      echo "FAIL: $core does not exist — the Grafana package layout moved." >&2
      exit 1
    fi

    echo "Grafana: $grafanaPkg"
    echo "bundled datasource plugins: $(ls "$core" | tr '\n' ' ')"

    rc=0
    for t in $types; do
      found=""

      # A core/bundled plugin: a directory named for the datasource type.
      if [ -d "$core/$t" ]; then
        found="bundled"
      fi

      # A declarative plugin: its plugin.json `id` must equal the datasource type. Matching on
      # the directory NAME would pass on a version suffix and fail on a rename, so read the id.
      if [ -z "$found" ]; then
        for p in $pluginInputs; do
          for j in "$p"/plugin.json "$p"/*/plugin.json; do
            [ -f "$j" ] || continue
            if grep -q "\"id\"[[:space:]]*:[[:space:]]*\"$t\"" "$j"; then
              found="declarative ($p)"
              break 2
            fi
          done
        done
      fi

      if [ -z "$found" ]; then
        echo "FAIL: datasource type '$t' is provisioned but NO plugin provides it." >&2
        echo "      Grafana will answer every query from it with" >&2
        echo "      'Unable to find datasource plugin' and every panel reads 'No data'." >&2
        rc=1
      else
        echo "ok: $t -> $found"
      fi
    done

    [ $rc -eq 0 ] || exit 1
    touch $out
  ''

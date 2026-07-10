#!/usr/bin/env bash
# Fast local Grafana preview loop for iterating on the in-tree dashboards.
#
# Runs a throwaway Grafana (from nixpkgs) on the workstation, its datasources
# pointed at rk1b's live VictoriaMetrics/VictoriaLogs over Tailscale and the
# repo's dashboard JSON provisioned for editing. This is the "see-it-render"
# loop the dashboard work depends on — no deploy-to-rk1b round trip.
#
#   just grafana-preview            # open http://127.0.0.1:3001 (anonymous Admin)
#
# Edit a panel in the UI, then Dashboard settings > JSON Model (or Export >
# "Export for sharing externally" off > Save to file) to get the JSON, and paste
# it back into the matching file in this directory. GOTCHA: the exported model
# carries a numeric `id` and a `version`; the in-tree convention is `id: null`
# and `version: null` — reset both before committing (git diff will flag them).
#
# Overridable via env: GRAFANA_PREVIEW_TARGET (default rk1b MagicDNS name),
# GRAFANA_PREVIEW_PORT (3001), GRAFANA_PREVIEW_WORK (throwaway state dir).
set -euo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
DASH_DIR="$REPO/modules/nixos/profiles/monitoring/dashboards"
TARGET="${GRAFANA_PREVIEW_TARGET:-rk1b.tail8596c.ts.net}" # settings.tailnet = tail8596c.ts.net
PORT="${GRAFANA_PREVIEW_PORT:-3001}"
WORK="${GRAFANA_PREVIEW_WORK:-${XDG_RUNTIME_DIR:-/tmp}/grafana-preview}"

VM_URL="http://$TARGET:8428"
VL_URL="http://$TARGET:9428"

echo ">> resolving grafana + VictoriaLogs datasource plugin from nixpkgs..."
GRAFANA="$(nix build --no-link --print-out-paths 'nixpkgs#grafana')"
VL_PLUGIN="$(nix build --no-link --print-out-paths 'nixpkgs#grafanaPlugins.victoriametrics-logs-datasource')"

# Fresh writable tree (nix store paths are read-only, so we assemble our own).
rm -rf "$WORK"
mkdir -p "$WORK"/{data,logs,plugins,provisioning/datasources,provisioning/dashboards,provisioning/plugins,provisioning/alerting}

# The VL datasource ships as a Grafana plugin; symlink it into a writable plugins dir.
ln -s "$VL_PLUGIN" "$WORK/plugins/victoriametrics-logs-datasource"

cat >"$WORK/provisioning/datasources/rk1b.yaml" <<YAML
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: $VM_URL
    isDefault: true
    editable: true
  - name: VictoriaLogs
    type: victoriametrics-logs-datasource
    access: proxy
    url: $VL_URL
    editable: true
YAML

# Point the provider straight at the in-tree dashboards dir; re-read every 5s so a
# saved .json shows up without a restart.
cat >"$WORK/provisioning/dashboards/local.yaml" <<YAML
apiVersion: 1
providers:
  - name: In-tree dashboards
    type: file
    allowUiUpdates: true
    updateIntervalSeconds: 5
    options:
      path: $DASH_DIR
      foldersFromFilesStructure: false
YAML

cat >"$WORK/grafana.ini" <<INI
[paths]
data = $WORK/data
logs = $WORK/logs
plugins = $WORK/plugins
provisioning = $WORK/provisioning

[server]
http_addr = 127.0.0.1
http_port = $PORT

[auth.anonymous]
enabled = true
org_role = Admin

[auth.basic]
enabled = false

[users]
default_theme = dark

[plugins]
allow_loading_unsigned_plugins = victoriametrics-logs-datasource
preinstall_disabled = true

[analytics]
reporting_enabled = false
check_for_updates = false
INI

echo ">> datasources -> VM $VM_URL   VL $VL_URL"
echo ">> dashboards  -> $DASH_DIR (live, re-read every 5s)"
echo ">> open        -> http://127.0.0.1:$PORT  (anonymous Admin, no login)"
echo ">> Ctrl-C to stop; $WORK is disposable."
echo

exec "$GRAFANA/bin/grafana" server --homepath "$GRAFANA/share/grafana" --config "$WORK/grafana.ini"

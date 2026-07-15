#!/usr/bin/env bash
#
# suricata-alerts.sh — human-readable view of recent Suricata alerts.
#
# Usage:
#   sudo ./suricata-alerts.sh            # last 20 alerts
#   sudo ./suricata-alerts.sh 50         # last 50 alerts
#   sudo ./suricata-alerts.sh --follow   # live stream (Ctrl-C to stop)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root

EVE="/var/log/suricata/eve.json"
[[ -r ${EVE} ]] || die "No ${EVE} — is Suricata running? (systemctl status suricata)"
command -v jq >/dev/null || die "jq is required (apt-get install jq)"

# One line per alert: time  severity  action  src -> dst  signature
FILTER='select(.event_type=="alert")
  | "\(.timestamp | sub("\\..*$"; ""))  sev\(.alert.severity)  \(.alert.action)  \(.src_ip):\(.src_port // 0) -> \(.dest_ip):\(.dest_port // 0)  \(.alert.signature)"'

if [[ ${1:-} == "--follow" || ${1:-} == "-f" ]]; then
    log "Streaming alerts from ${EVE} (Ctrl-C to stop)..."
    tail -n0 -F "${EVE}" | jq --unbuffered -r "${FILTER}"
else
    count="${1:-20}"
    [[ ${count} =~ ^[0-9]+$ ]] || die "usage: $0 [count|--follow]"
    alerts="$(grep -h '"event_type":"alert"' "${EVE}" | tail -n "${count}" || true)"
    if [[ -z ${alerts} ]]; then
        log "No alerts logged yet."
    else
        jq -r "${FILTER}" <<< "${alerts}"
    fi
fi

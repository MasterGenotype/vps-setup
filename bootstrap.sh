#!/usr/bin/env bash
#
# bootstrap.sh — one-shot setup of a fresh Ubuntu VPS as an encrypted
# tunnel (WireGuard VPN) server, with basic hardening, intrusion
# detection & prevention (Suricata IDPS), encrypted DNS (dnscrypt-proxy),
# and initial client configs for a computer and a phone.
#
# Usage (on the VPS, as root):
#   git clone <this-repo> && cd vps-setup
#   sudo ./bootstrap.sh
#
# Skip pieces:
#   sudo NO_CLIENTS=1 ./bootstrap.sh    # no initial device configs
#   sudo NO_SURICATA=1 ./bootstrap.sh   # no intrusion detection/prevention
#   sudo NO_DNSCRYPT=1 ./bootstrap.sh   # no encrypted DNS proxy

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

"${SCRIPT_DIR}/scripts/setup-wireguard.sh"
"${SCRIPT_DIR}/scripts/harden.sh"

if [[ -z ${NO_SURICATA:-} ]]; then
    "${SCRIPT_DIR}/scripts/setup-suricata.sh"
fi

# Before add-client so the initial devices get the tunnel DNS baked in.
if [[ -z ${NO_DNSCRYPT:-} ]]; then
    "${SCRIPT_DIR}/scripts/setup-dnscrypt.sh"
fi

if [[ -z ${NO_CLIENTS:-} ]]; then
    for name in computer phone; do
        if [[ ! -d "/etc/wireguard/clients/${name}" ]]; then
            "${SCRIPT_DIR}/scripts/add-client.sh" "${name}"
        fi
    done
fi

echo
echo "Done. Manage devices with:"
echo "  sudo ./scripts/add-client.sh <name>"
echo "  sudo ./scripts/remove-client.sh <name>"
echo "  sudo ./scripts/list-clients.sh"
echo "View intrusion-detection alerts with:"
echo "  sudo ./scripts/suricata-alerts.sh"

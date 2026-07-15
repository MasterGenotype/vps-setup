#!/usr/bin/env bash
#
# bootstrap.sh — one-shot setup of a fresh Ubuntu VPS as an encrypted
# tunnel (WireGuard VPN) server, with basic hardening, and initial
# client configs for a computer and a phone.
#
# Usage (on the VPS, as root):
#   git clone <this-repo> && cd vps-setup
#   sudo ./bootstrap.sh
#
# Skip initial clients:
#   sudo NO_CLIENTS=1 ./bootstrap.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

"${SCRIPT_DIR}/scripts/setup-wireguard.sh"
"${SCRIPT_DIR}/scripts/harden.sh"

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

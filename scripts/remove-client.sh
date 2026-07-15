#!/usr/bin/env bash
#
# remove-client.sh — revoke a device's VPN access.
#
# Deletes the peer from the server config, applies the change live,
# and removes the stored client files.
#
# Usage:
#   sudo ./remove-client.sh phone

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
load_settings

[[ $# -eq 1 ]] || die "Usage: $0 <client-name>"
NAME="$1"
validate_client_name "${NAME}"
client_exists "${NAME}" || die "Client '${NAME}' not found (see list-clients.sh)"
[[ -f ${WG_CONF} ]] || die "Server config ${WG_CONF} not found"

# Drop the peer block between its BEGIN/END markers.
sed -i "/^# BEGIN client ${NAME}\$/,/^# END client ${NAME}\$/d" "${WG_CONF}"
# Collapse any doubled blank lines left behind.
sed -i '/^$/N;/^\n$/D' "${WG_CONF}"

rm -rf "${CLIENTS_DIR:?}/${NAME}"

# Apply live without disturbing other peers.
if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    wg syncconf "${WG_INTERFACE}" <(wg-quick strip "${WG_INTERFACE}")
fi

log "Client '${NAME}' removed and access revoked."

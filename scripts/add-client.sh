#!/usr/bin/env bash
#
# add-client.sh — register a new device (laptop, phone, ...) on the VPN.
#
# Generates a keypair + preshared key, assigns the next free tunnel IP,
# appends the peer to the server config, and writes a ready-to-import
# client .conf. For phones it also prints a QR code to scan with the
# WireGuard app.
#
# Usage:
#   sudo ./add-client.sh laptop
#   sudo ./add-client.sh phone            # then scan the QR code
#   sudo ./add-client.sh work --split     # tunnel only VPN subnet, not all traffic

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
load_settings

[[ $# -ge 1 ]] || die "Usage: $0 <client-name> [--split]"
NAME="$1"
SPLIT_TUNNEL=false
[[ ${2:-} == "--split" ]] && SPLIT_TUNNEL=true

validate_client_name "${NAME}"
client_exists "${NAME}" && die "Client '${NAME}' already exists (remove it first with remove-client.sh)"
[[ -f ${WG_CONF} ]] || die "Server not set up yet — run setup-wireguard.sh first"
[[ -n ${WG_ENDPOINT:-} && -n ${WG_PORT:-} ]] \
    || die "Missing settings in ${SETTINGS_FILE} — re-run setup-wireguard.sh"

WG_IPV4_NET="${WG_IPV4_NET:-10.8.0.0/24}"
WG_IPV6_NET="${WG_IPV6_NET:-fd42:8:8::/64}"
WG_DNS="${WG_DNS:-1.1.1.1,1.0.0.1}"
NET_PREFIX="${WG_IPV4_NET%.*/*}"        # e.g. 10.8.0
IPV6_PREFIX="${WG_IPV6_NET%%/*}"        # e.g. fd42:8:8::

# ------------------------------------------------- next free tunnel address
# .1 is the server; scan .2-.254 for the first octet not already assigned.
used_octets=$(grep -oE "AllowedIPs *= *${NET_PREFIX//./\\.}\.[0-9]+" "${WG_CONF}" \
    | grep -oE '[0-9]+$' || true)
CLIENT_OCTET=""
for i in $(seq 2 254); do
    if ! grep -qx "${i}" <<< "${used_octets}"; then
        CLIENT_OCTET="${i}"
        break
    fi
done
[[ -n ${CLIENT_OCTET} ]] || die "Tunnel subnet ${WG_IPV4_NET} is full"

CLIENT_IPV4="${NET_PREFIX}.${CLIENT_OCTET}"
CLIENT_IPV6="${IPV6_PREFIX}${CLIENT_OCTET}"

# ------------------------------------------------------------------- keys
umask 077
CLIENT_DIR="${CLIENTS_DIR}/${NAME}"
mkdir -p "${CLIENT_DIR}"

CLIENT_PRIVKEY="$(wg genkey)"
CLIENT_PUBKEY="$(wg pubkey <<< "${CLIENT_PRIVKEY}")"
CLIENT_PSK="$(wg genpsk)"
SERVER_PUBKEY="$(cat "${WG_DIR}/server.pub")"

if ${SPLIT_TUNNEL}; then
    ALLOWED="${WG_IPV4_NET}, ${WG_IPV6_NET}"
else
    ALLOWED="0.0.0.0/0, ::/0"
fi

# --------------------------------------------------------- server-side peer
cat >> "${WG_CONF}" <<EOF

# BEGIN client ${NAME}
[Peer]
PublicKey = ${CLIENT_PUBKEY}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = ${CLIENT_IPV4}/32, ${CLIENT_IPV6}/128
# END client ${NAME}
EOF

# --------------------------------------------------------- client config
CLIENT_CONF="${CLIENT_DIR}/${NAME}.conf"
cat > "${CLIENT_CONF}" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVKEY}
Address = ${CLIENT_IPV4}/32, ${CLIENT_IPV6}/128
DNS = ${WG_DNS}

[Peer]
PublicKey = ${SERVER_PUBKEY}
PresharedKey = ${CLIENT_PSK}
Endpoint = ${WG_ENDPOINT}:${WG_PORT}
AllowedIPs = ${ALLOWED}
PersistentKeepalive = 25
EOF
chmod 600 "${CLIENT_CONF}"

# ---------------------------------------------- apply without dropping peers
if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    wg syncconf "${WG_INTERFACE}" <(wg-quick strip "${WG_INTERFACE}")
else
    warn "wg-quick@${WG_INTERFACE} is not running — peer will apply on next start"
fi

log "Client '${NAME}' added (${CLIENT_IPV4})"
log "Config written to ${CLIENT_CONF}"
echo
log "Phone: scan this QR code in the WireGuard app (+ > Create from QR code):"
echo
qrencode -t ansiutf8 < "${CLIENT_CONF}"
echo
log "Computer: copy the config off the server, e.g."
echo "    scp root@${WG_ENDPOINT}:${CLIENT_CONF} ."
echo "  then import it into the WireGuard app, or on Linux:"
echo "    sudo cp ${NAME}.conf /etc/wireguard/ && sudo wg-quick up ${NAME}"

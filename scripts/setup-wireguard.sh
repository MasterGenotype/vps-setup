#!/usr/bin/env bash
#
# setup-wireguard.sh — turn a fresh Ubuntu VPS into a WireGuard VPN server.
#
# All traffic from connected devices (laptop, phone) is routed through an
# encrypted tunnel to this server and NAT'd out to the Internet.
#
# Idempotent: safe to re-run. Existing server keys and clients are preserved.
#
# Configuration (override via environment or /etc/wireguard/vps-setup.env):
#   WG_PORT        UDP listen port                  (default: 51820)
#   WG_IPV4_NET    tunnel IPv4 subnet               (default: 10.8.0.0/24)
#   WG_IPV6_NET    tunnel IPv6 subnet               (default: fd42:8:8::/64)
#   WG_DNS         DNS servers pushed to clients    (default: 1.1.1.1,1.0.0.1)
#   WG_ENDPOINT    public address clients connect to (default: auto-detected)
#   WG_INTERFACE   WireGuard interface name         (default: wg0)
#
# Usage:
#   sudo ./setup-wireguard.sh
#   sudo WG_PORT=443 WG_DNS=9.9.9.9 ./setup-wireguard.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
require_ubuntu
load_settings

WG_PORT="${WG_PORT:-51820}"
WG_IPV4_NET="${WG_IPV4_NET:-10.8.0.0/24}"
WG_IPV6_NET="${WG_IPV6_NET:-fd42:8:8::/64}"
WG_DNS="${WG_DNS:-1.1.1.1,1.0.0.1}"

# ---------------------------------------------------------------- packages
log "Installing packages (wireguard, qrencode, ufw, iptables)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq wireguard wireguard-tools qrencode ufw iptables curl

# ------------------------------------------------------------ network facts
WAN_IF="${WAN_IF:-$(detect_wan_interface)}"
[[ -n ${WAN_IF} ]] || die "Could not detect WAN interface; set WAN_IF=... and re-run"

WG_ENDPOINT="${WG_ENDPOINT:-$(detect_public_ip)}"
[[ -n ${WG_ENDPOINT} ]] || die "Could not detect public IP; set WG_ENDPOINT=... and re-run"

# Server takes the first host address of each tunnel subnet (.1 / ::1).
SERVER_IPV4="${WG_IPV4_NET%.*/*}.1"
IPV4_PREFIX="${WG_IPV4_NET#*/}"
SERVER_IPV6="${WG_IPV6_NET%%/*}1"
IPV6_PREFIX="${WG_IPV6_NET#*/}"

log "WAN interface : ${WAN_IF}"
log "Endpoint      : ${WG_ENDPOINT}:${WG_PORT}"
log "Tunnel subnet : ${WG_IPV4_NET} / ${WG_IPV6_NET}"

# ------------------------------------------------------------- server keys
umask 077
mkdir -p "${WG_DIR}" "${CLIENTS_DIR}"

if [[ -f "${WG_DIR}/server.key" ]]; then
    log "Reusing existing server key"
else
    log "Generating server keypair"
    wg genkey | tee "${WG_DIR}/server.key" | wg pubkey > "${WG_DIR}/server.pub"
fi
SERVER_PRIVKEY="$(cat "${WG_DIR}/server.key")"

# ------------------------------------------------------------- wg0.conf
if [[ -f ${WG_CONF} ]]; then
    log "Keeping existing ${WG_CONF} (peers preserved)"
else
    log "Writing ${WG_CONF}"
    cat > "${WG_CONF}" <<EOF
[Interface]
Address = ${SERVER_IPV4}/${IPV4_PREFIX}, ${SERVER_IPV6}/${IPV6_PREFIX}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVKEY}

# NAT tunnel traffic out through the WAN interface.
PostUp   = iptables -t nat -A POSTROUTING -s ${WG_IPV4_NET} -o ${WAN_IF} -j MASQUERADE
PostUp   = iptables -A FORWARD -i %i -j ACCEPT
PostUp   = iptables -A FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp   = ip6tables -t nat -A POSTROUTING -s ${WG_IPV6_NET} -o ${WAN_IF} -j MASQUERADE
PostUp   = ip6tables -A FORWARD -i %i -j ACCEPT
PostUp   = ip6tables -A FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_IPV4_NET} -o ${WAN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -s ${WG_IPV6_NET} -o ${WAN_IF} -j MASQUERADE
PostDown = ip6tables -D FORWARD -i %i -j ACCEPT
PostDown = ip6tables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF
fi
chmod 600 "${WG_CONF}"

# ------------------------------------------------------------ IP forwarding
log "Enabling IP forwarding"
cat > /etc/sysctl.d/99-wireguard-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -q --system

# ---------------------------------------------------------------- firewall
log "Configuring UFW (allow SSH + WireGuard port ${WG_PORT}/udp)"
ufw allow OpenSSH >/dev/null
ufw allow "${WG_PORT}/udp" comment 'WireGuard' >/dev/null
ufw --force enable >/dev/null

# ----------------------------------------------------------------- service
log "Enabling and starting wg-quick@${WG_INTERFACE}"
systemctl enable --now "wg-quick@${WG_INTERFACE}"
# Pick up config changes if the service was already running.
systemctl reload-or-restart "wg-quick@${WG_INTERFACE}" 2>/dev/null \
    || systemctl restart "wg-quick@${WG_INTERFACE}"

# --------------------------------------------------------------- settings
save_setting WG_INTERFACE "${WG_INTERFACE}"
save_setting WG_PORT "${WG_PORT}"
save_setting WG_IPV4_NET "${WG_IPV4_NET}"
save_setting WG_IPV6_NET "${WG_IPV6_NET}"
save_setting WG_DNS "${WG_DNS}"
save_setting WG_ENDPOINT "${WG_ENDPOINT}"
save_setting WAN_IF "${WAN_IF}"

log "WireGuard server is up."
wg show "${WG_INTERFACE}" || true
echo
log "Next: add a device with  sudo ./add-client.sh <name>   (e.g. laptop, phone)"

#!/usr/bin/env bash
#
# setup-dnscrypt.sh — install and configure dnscrypt-proxy as the DNS
# resolver for the VPS and its WireGuard clients.
#
# - Installs dnscrypt-proxy from the Ubuntu archive
# - Listens on loopback (127.0.2.1) and the WireGuard server tunnel IPs,
#   so VPN devices resolve through the encrypted proxy inside the tunnel
# - Picks the fastest no-log resolvers automatically (DNSCrypt/DoH),
#   or pin specific ones with DNSCRYPT_SERVERS
# - Points new AND existing WireGuard client configs at the tunnel DNS
#   (existing devices must re-import their config to pick it up)
# - Routes the server's own lookups through the proxy too (systemd-resolved)
# - Opens the firewall for DNS on the WireGuard interface only
#
# Nothing is switched over until the proxy answers a live test query, so a
# broken install can't take out the server's DNS.
#
# Idempotent: safe to re-run.
#
# Configuration (override via environment or /etc/wireguard/vps-setup.env):
#   DNSCRYPT_SERVERS   comma-separated resolver names from the public list
#                      (default: automatic — fastest no-log resolvers)
#
# Usage:
#   sudo ./setup-dnscrypt.sh
#   sudo DNSCRYPT_SERVERS=quad9-dnscrypt-ip4-filter-pri ./setup-dnscrypt.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

trap 'die "setup-dnscrypt.sh failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

require_root
require_ubuntu
load_settings

DNSCRYPT_TOML="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
LOCAL_ADDR="127.0.2.1"

# ---------------------------------------------------------------- packages
log "Installing dnscrypt-proxy (and dig for the health check)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq dnscrypt-proxy
apt-get install -yq dnsutils 2>/dev/null || apt-get install -yq bind9-dnsutils

DNSCRYPT_BIN="$(command -v dnscrypt-proxy || echo /usr/sbin/dnscrypt-proxy)"
[[ -x ${DNSCRYPT_BIN} ]] || die "dnscrypt-proxy binary not found after install"
[[ -f ${DNSCRYPT_TOML} ]] || die "${DNSCRYPT_TOML} not found after install"

# ------------------------------------------------------------ tunnel facts
# If WireGuard is set up, also listen on the server's tunnel addresses so
# VPN clients can use them as their DNS server.
LISTEN="'${LOCAL_ADDR}:53'"
SERVER_IPV4=""
SERVER_IPV6=""
if [[ -n ${WG_IPV4_NET:-} ]]; then
    SERVER_IPV4="${WG_IPV4_NET%.*/*}.1"
    LISTEN+=", '${SERVER_IPV4}:53'"
fi
if [[ -n ${WG_IPV6_NET:-} ]]; then
    SERVER_IPV6="${WG_IPV6_NET%%/*}1"
    LISTEN+=", '[${SERVER_IPV6}]:53'"
fi
if [[ -z ${SERVER_IPV4} && -z ${SERVER_IPV6} ]]; then
    warn "No WireGuard settings found — dnscrypt-proxy will serve loopback only."
    warn "Run setup-wireguard.sh first, then re-run this script for tunnel DNS."
fi

log "Listen addresses: ${LISTEN}"

# ---------------------------------------------------------- dnscrypt config
cp -n "${DNSCRYPT_TOML}" "${DNSCRYPT_TOML}.orig"

log "Configuring ${DNSCRYPT_TOML}"
sed -i "s|^listen_addresses = .*|listen_addresses = [${LISTEN}]|" "${DNSCRYPT_TOML}"
grep -qF "listen_addresses = [${LISTEN}]" "${DNSCRYPT_TOML}" \
    || die "Could not set listen_addresses in ${DNSCRYPT_TOML}"

if [[ -n ${DNSCRYPT_SERVERS:-} ]]; then
    server_names="$(sed "s/[, ]\{1,\}/', '/g; s/^/['/; s/\$/']/" <<< "${DNSCRYPT_SERVERS}")"
    log "Pinning resolvers: ${server_names}"
    if grep -q "^server_names = " "${DNSCRYPT_TOML}"; then
        sed -i "s|^server_names = .*|server_names = ${server_names}|" "${DNSCRYPT_TOML}"
    else
        sed -i "1i server_names = ${server_names}" "${DNSCRYPT_TOML}"
    fi
fi

# ----------------------------------------------------------------- service
# The packaged unit is socket-activated on loopback only, which can't serve
# the tunnel addresses. Replace it with a direct unit (a full unit in
# /etc/systemd overrides the packaged one) ordered after WireGuard so the
# tunnel IPs exist before the proxy binds them.
DNSCRYPT_USER="_dnscrypt-proxy"
id -u "${DNSCRYPT_USER}" >/dev/null 2>&1 || DNSCRYPT_USER="root"

systemctl disable --now dnscrypt-proxy.socket >/dev/null 2>&1 || true
systemctl disable --now dnscrypt-proxy-resolvconf.service >/dev/null 2>&1 || true

log "Writing dnscrypt-proxy.service (user: ${DNSCRYPT_USER})"
cat > /etc/systemd/system/dnscrypt-proxy.service <<EOF
# Managed by vps-setup/scripts/setup-dnscrypt.sh — replaces the packaged
# socket-activated unit so the proxy can bind the WireGuard tunnel IPs.
[Unit]
Description=DNSCrypt proxy for this server and its WireGuard clients
Documentation=https://github.com/DNSCrypt/dnscrypt-proxy/wiki
After=network-online.target wg-quick@${WG_INTERFACE}.service
Wants=network-online.target
Before=nss-lookup.target

[Service]
Type=notify
NonBlocking=true
User=${DNSCRYPT_USER}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=${DNSCRYPT_BIN} -config ${DNSCRYPT_TOML}
Restart=on-failure
RestartSec=5
CacheDirectory=dnscrypt-proxy
LogsDirectory=dnscrypt-proxy
RuntimeDirectory=dnscrypt-proxy

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable dnscrypt-proxy >/dev/null 2>&1
systemctl restart dnscrypt-proxy

# ------------------------------------------------------------ health check
# First start fetches and verifies the public resolver lists; give it time.
log "Waiting for dnscrypt-proxy to answer queries..."
for i in $(seq 1 15); do
    if dig +time=3 +tries=1 @"${LOCAL_ADDR}" cloudflare.com >/dev/null 2>&1; then
        break
    fi
    [[ ${i} -lt 15 ]] || die "dnscrypt-proxy is not answering — see: journalctl -u dnscrypt-proxy"
    sleep 2
done
log "dnscrypt-proxy is resolving."

# ---------------------------------------------------------------- firewall
if [[ -n ${SERVER_IPV4}${SERVER_IPV6} ]]; then
    log "Allowing DNS from VPN clients (interface ${WG_INTERFACE} only)"
    ufw allow in on "${WG_INTERFACE}" to any port 53 proto udp comment 'VPN DNS' >/dev/null
    ufw allow in on "${WG_INTERFACE}" to any port 53 proto tcp comment 'VPN DNS' >/dev/null
fi

# ----------------------------------------------- WireGuard client DNS
if [[ -n ${SERVER_IPV4} ]]; then
    NEW_DNS="${SERVER_IPV4}"
    [[ -n ${SERVER_IPV6} ]] && NEW_DNS+=",${SERVER_IPV6}"

    log "New clients will use tunnel DNS ${NEW_DNS}"
    save_setting WG_DNS "${NEW_DNS}"

    updated=()
    for conf in "${CLIENTS_DIR}"/*/*.conf; do
        [[ -f ${conf} ]] || continue
        if ! grep -q "^DNS = ${NEW_DNS}\$" "${conf}"; then
            sed -i "s|^DNS = .*|DNS = ${NEW_DNS}|" "${conf}"
            updated+=("$(basename "${conf%.conf}")")
        fi
    done
    if (( ${#updated[@]} > 0 )); then
        warn "Updated DNS in existing client configs: ${updated[*]}"
        warn "Those devices must re-import their config to switch over:"
        warn "  phones:    sudo ./list-clients.sh --qr <name>   (re-scan)"
        warn "  computers: re-copy the .conf from ${CLIENTS_DIR}/<name>/"
    fi
fi

# ------------------------------------------------- server's own resolution
# Only switch the host over now that the proxy demonstrably works.
if systemctl is-active --quiet systemd-resolved; then
    log "Routing the server's own DNS through dnscrypt-proxy (systemd-resolved)"
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/dnscrypt.conf <<EOF
# Managed by vps-setup — send this host's lookups to dnscrypt-proxy.
# Delete this file and restart systemd-resolved to undo.
[Resolve]
DNS=${LOCAL_ADDR}
Domains=~.
DNSSEC=no
EOF
    systemctl restart systemd-resolved
else
    warn "systemd-resolved is not active — leaving the server's own resolver as-is."
    warn "Point /etc/resolv.conf at ${LOCAL_ADDR} manually if you want the host to use it."
fi

log "DNSCrypt proxy is up."
log "Test from the server :  dig @${LOCAL_ADDR} example.com"
if [[ -n ${SERVER_IPV4} ]]; then
    log "Test from a client   :  dig @${SERVER_IPV4} example.com   (while on the VPN)"
fi

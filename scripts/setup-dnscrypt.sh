#!/usr/bin/env bash
#
# setup-dnscrypt.sh — install DNSCrypt-Proxy as the DNS resolver for WireGuard
# clients. The proxy listens only on the server's WireGuard addresses, so port
# 53 is never exposed on the public interface.
#
# Idempotent: safe to re-run. Existing WireGuard client configs are updated to
# use the tunnel resolver; re-import those configs on already-enrolled devices.
#
# Configuration (override via environment or /etc/wireguard/vps-setup.env):
#   DNSCRYPT_VERSION          pinned upstream release      (default: 2.1.17)
#   DNSCRYPT_SERVER_NAMES     comma-separated resolvers    (default: automatic)
#   DNSCRYPT_IPV6_UPSTREAM    use IPv6 upstream resolvers  (default: 0)
#   DNSCRYPT_REQUIRE_DNSSEC   require DNSSEC               (default: 1)
#   DNSCRYPT_REQUIRE_NOLOG    require no-logging policy    (default: 1)
#   DNSCRYPT_REQUIRE_NOFILTER require unfiltered resolver  (default: 1)
#
# Usage:
#   sudo ./setup-dnscrypt.sh
#   sudo DNSCRYPT_SERVER_NAMES=cloudflare,scaleway-fr ./setup-dnscrypt.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
require_ubuntu
load_settings

DNSCRYPT_VERSION="${DNSCRYPT_VERSION:-2.1.17}"
DNSCRYPT_SERVER_NAMES="${DNSCRYPT_SERVER_NAMES:-}"
DNSCRYPT_IPV6_UPSTREAM="${DNSCRYPT_IPV6_UPSTREAM:-0}"
DNSCRYPT_REQUIRE_DNSSEC="${DNSCRYPT_REQUIRE_DNSSEC:-1}"
DNSCRYPT_REQUIRE_NOLOG="${DNSCRYPT_REQUIRE_NOLOG:-1}"
DNSCRYPT_REQUIRE_NOFILTER="${DNSCRYPT_REQUIRE_NOFILTER:-1}"

DNSCRYPT_USER="dnscrypt-proxy"
DNSCRYPT_GROUP="dnscrypt-proxy"
DNSCRYPT_BIN="/usr/local/sbin/dnscrypt-proxy"
DNSCRYPT_ETC="/etc/dnscrypt-proxy"
DNSCRYPT_STATE="/var/lib/dnscrypt-proxy"
DNSCRYPT_CONFIG="${DNSCRYPT_ETC}/dnscrypt-proxy.toml"
DNSCRYPT_SERVICE="/etc/systemd/system/dnscrypt-proxy.service"
DNSCRYPT_SIGNING_KEY="RWTk1xXqcTODeYttYMCMLo0YJHaFEHn7a3akqHlb/7QvIQXHVPxKbjB5"

TMP_DIR=""
cleanup() {
    [[ -z ${TMP_DIR} ]] || rm -rf -- "${TMP_DIR}"
}
trap cleanup EXIT
trap 'die "setup-dnscrypt.sh failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

bool_toml() {
    case "$1" in
        1|true|yes|on) printf 'true' ;;
        0|false|no|off) printf 'false' ;;
        *) die "Expected a boolean (0/1, true/false, yes/no, on/off), got: '$1'" ;;
    esac
}

DNSCRYPT_IPV6_UPSTREAM_TOML="$(bool_toml "${DNSCRYPT_IPV6_UPSTREAM}")"
DNSCRYPT_REQUIRE_DNSSEC_TOML="$(bool_toml "${DNSCRYPT_REQUIRE_DNSSEC}")"
DNSCRYPT_REQUIRE_NOLOG_TOML="$(bool_toml "${DNSCRYPT_REQUIRE_NOLOG}")"
DNSCRYPT_REQUIRE_NOFILTER_TOML="$(bool_toml "${DNSCRYPT_REQUIRE_NOFILTER}")"

[[ ${DNSCRYPT_VERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] \
    || die "Invalid DNSCRYPT_VERSION: '${DNSCRYPT_VERSION}'"

systemctl is-active --quiet "wg-quick@${WG_INTERFACE}" \
    || die "wg-quick@${WG_INTERFACE} is not active — run setup-wireguard.sh first"
ip link show dev "${WG_INTERFACE}" >/dev/null 2>&1 \
    || die "WireGuard interface '${WG_INTERFACE}' does not exist"

SERVER_IPV4="$(ip -o -4 address show dev "${WG_INTERFACE}" scope global \
    | awk 'NR == 1 {sub(/\/.*/, "", $4); print $4}')"
SERVER_IPV6="$(ip -o -6 address show dev "${WG_INTERFACE}" scope global \
    | awk 'NR == 1 {sub(/\/.*/, "", $4); print $4}')"

[[ -n ${SERVER_IPV4} ]] \
    || die "No IPv4 address found on ${WG_INTERFACE}; DNSCrypt requires the WireGuard server address"

log "WireGuard DNS address: ${SERVER_IPV4}${SERVER_IPV6:+ / ${SERVER_IPV6}}"

# ---------------------------------------------------------------- packages
export DEBIAN_FRONTEND=noninteractive
log "Installing DNSCrypt-Proxy dependencies"
apt-get update -q
apt-get install -yq ca-certificates curl tar dnsutils

if ! command -v minisign >/dev/null 2>&1; then
    if ! apt-get install -yq minisign; then
        log "Enabling Ubuntu Universe for minisign"
        apt-get install -yq software-properties-common
        add-apt-repository -y universe
        apt-get update -q
        apt-get install -yq minisign
    fi
fi
command -v minisign >/dev/null 2>&1 || die "minisign was not installed"

# -------------------------------------------------------- signed upstream build
case "$(dpkg --print-architecture)" in
    amd64) RELEASE_ARCH="x86_64" ;;
    arm64) RELEASE_ARCH="arm64" ;;
    *) die "Unsupported architecture: $(dpkg --print-architecture) (supported: amd64, arm64)" ;;
esac

ASSET="dnscrypt-proxy-linux_${RELEASE_ARCH}-${DNSCRYPT_VERSION}.tar.gz"
RELEASE_URL="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${DNSCRYPT_VERSION}"
TMP_DIR="$(mktemp -d)"
ARCHIVE="${TMP_DIR}/${ASSET}"
SIGNATURE="${ARCHIVE}.minisig"

log "Downloading DNSCrypt-Proxy ${DNSCRYPT_VERSION} (${RELEASE_ARCH})"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 \
    --output "${ARCHIVE}" "${RELEASE_URL}/${ASSET}"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 \
    --output "${SIGNATURE}" "${RELEASE_URL}/${ASSET}.minisig"

log "Verifying upstream Minisign signature"
minisign -Vm "${ARCHIVE}" -x "${SIGNATURE}" -P "${DNSCRYPT_SIGNING_KEY}" >/dev/null

tar -xzf "${ARCHIVE}" -C "${TMP_DIR}"
EXTRACTED_BIN="$(find "${TMP_DIR}" -type f -name dnscrypt-proxy -print -quit)"
[[ -n ${EXTRACTED_BIN} ]] || die "dnscrypt-proxy binary not found in ${ASSET}"
install -m 0755 "${EXTRACTED_BIN}" "${DNSCRYPT_BIN}"

# --------------------------------------------------------- account/directories
getent group "${DNSCRYPT_GROUP}" >/dev/null 2>&1 \
    || groupadd --system "${DNSCRYPT_GROUP}"
if ! id -u "${DNSCRYPT_USER}" >/dev/null 2>&1; then
    useradd --system --gid "${DNSCRYPT_GROUP}" --home-dir "${DNSCRYPT_STATE}" \
        --shell /usr/sbin/nologin "${DNSCRYPT_USER}"
fi

install -d -m 0750 -o root -g "${DNSCRYPT_GROUP}" "${DNSCRYPT_ETC}"
install -d -m 0750 -o "${DNSCRYPT_USER}" -g "${DNSCRYPT_GROUP}" "${DNSCRYPT_STATE}"

# -------------------------------------------------------------- configuration
LISTEN_ADDRESSES="'${SERVER_IPV4}:53'"
if [[ -n ${SERVER_IPV6} ]]; then
    LISTEN_ADDRESSES+=", '[${SERVER_IPV6}]:53'"
fi

SERVER_NAMES_LINE=""
if [[ -n ${DNSCRYPT_SERVER_NAMES} ]]; then
    IFS=',' read -r -a requested_servers <<< "${DNSCRYPT_SERVER_NAMES}"
    formatted_servers=()
    for server in "${requested_servers[@]}"; do
        server="${server//[[:space:]]/}"
        [[ -n ${server} ]] || continue
        [[ ${server} =~ ^[A-Za-z0-9._-]+$ ]] \
            || die "Invalid resolver name in DNSCRYPT_SERVER_NAMES: '${server}'"
        formatted_servers+=("${server}")
    done
    (( ${#formatted_servers[@]} > 0 )) \
        || die "DNSCRYPT_SERVER_NAMES did not contain a valid resolver name"
    SERVER_NAMES_LINE="server_names = ["
    for server in "${formatted_servers[@]}"; do
        [[ ${SERVER_NAMES_LINE} == "server_names = [" ]] || SERVER_NAMES_LINE+=", "
        SERVER_NAMES_LINE+="'${server}'"
    done
    SERVER_NAMES_LINE+="]"
    warn "Explicit server_names bypass require_dnssec/require_nolog/require_nofilter filters"
fi

CONFIG_TMP="${TMP_DIR}/dnscrypt-proxy.toml"
cat > "${CONFIG_TMP}" <<EOF
# Managed by vps-setup/scripts/setup-dnscrypt.sh.
# Listens only inside the WireGuard tunnel; never expose this on 0.0.0.0/[::].
${SERVER_NAMES_LINE}
listen_addresses = [${LISTEN_ADDRESSES}]
max_clients = 512

ipv4_servers = true
ipv6_servers = ${DNSCRYPT_IPV6_UPSTREAM_TOML}
dnscrypt_servers = true
doh_servers = false
odoh_servers = false

require_dnssec = ${DNSCRYPT_REQUIRE_DNSSEC_TOML}
require_nolog = ${DNSCRYPT_REQUIRE_NOLOG_TOML}
require_nofilter = ${DNSCRYPT_REQUIRE_NOFILTER_TOML}

pqdnscrypt = true
force_tcp = false
http3 = false
timeout = 5000
keepalive = 30

use_syslog = true
cert_refresh_delay = 240

bootstrap_resolvers = ['9.9.9.11:53', '8.8.8.8:53']
ignore_system_dns = true
netprobe_timeout = 60
netprobe_address = '9.9.9.9:53'

block_ipv6 = false
block_unqualified = true
block_undelegated = true

cache = true
cache_size = 4096
cache_min_ttl = 2400
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600

[sources.public-resolvers]
urls = [
  'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md',
  'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md',
  'https://cdn.jsdelivr.net/gh/DNSCrypt/dnscrypt-resolvers@master/v3/public-resolvers.md'
]
cache_file = '${DNSCRYPT_STATE}/public-resolvers.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 73
prefix = ''

[broken_implementations]
fragments_blocked = [
  'cisco',
  'cisco-ipv6',
  'cisco-familyshield',
  'cisco-familyshield-ipv6',
  'cisco-sandbox',
  'cleanbrowsing-adult',
  'cleanbrowsing-adult-ipv6',
  'cleanbrowsing-family',
  'cleanbrowsing-family-ipv6',
  'cleanbrowsing-security',
  'cleanbrowsing-security-ipv6'
]
EOF
install -m 0640 -o root -g "${DNSCRYPT_GROUP}" "${CONFIG_TMP}" "${DNSCRYPT_CONFIG}"

log "Validating DNSCrypt-Proxy configuration"
runuser -u "${DNSCRYPT_USER}" -- "${DNSCRYPT_BIN}" \
    -config "${DNSCRYPT_CONFIG}" -check >/dev/null

# ------------------------------------------------------------------ service
cat > "${DNSCRYPT_SERVICE}" <<EOF
[Unit]
Description=DNSCrypt-Proxy for WireGuard clients
Documentation=https://dnscrypt.info/doc
Wants=network-online.target
Requires=wg-quick@${WG_INTERFACE}.service
After=network-online.target wg-quick@${WG_INTERFACE}.service
PartOf=wg-quick@${WG_INTERFACE}.service

[Service]
Type=simple
User=${DNSCRYPT_USER}
Group=${DNSCRYPT_GROUP}
WorkingDirectory=${DNSCRYPT_STATE}
ExecStart=${DNSCRYPT_BIN} -config ${DNSCRYPT_CONFIG}
Restart=on-failure
RestartSec=5s
UMask=0077

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6
SystemCallArchitectures=native
ReadWritePaths=${DNSCRYPT_STATE}

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "${DNSCRYPT_SERVICE}"

# Ubuntu's distro package may install socket activation, which conflicts with
# explicit listen_addresses. Disable it before enabling the project-owned unit.
systemctl disable --now dnscrypt-proxy.socket >/dev/null 2>&1 || true
systemctl daemon-reload

# --------------------------------------------------------------- firewall
log "Allowing DNS only through ${WG_INTERFACE}"
ufw allow in on "${WG_INTERFACE}" to any port 53 proto udp \
    comment 'DNSCrypt over WireGuard' >/dev/null
ufw allow in on "${WG_INTERFACE}" to any port 53 proto tcp \
    comment 'DNSCrypt over WireGuard' >/dev/null

log "Enabling and starting DNSCrypt-Proxy"
systemctl enable --now dnscrypt-proxy.service >/dev/null
systemctl restart dnscrypt-proxy.service
systemctl is-active --quiet dnscrypt-proxy.service \
    || die "dnscrypt-proxy failed to start — see: journalctl -u dnscrypt-proxy"

# -------------------------------------------------------------- live test
resolved=false
for _ in $(seq 1 12); do
    if dig +time=5 +tries=1 +short @"${SERVER_IPV4}" example.com A \
        | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then
        resolved=true
        break
    fi
    sleep 2
done
${resolved} || die "DNSCrypt-Proxy is running but failed a test query through ${SERVER_IPV4}:53"

if [[ -n ${SERVER_IPV6} ]]; then
    dig +time=5 +tries=1 +short @"${SERVER_IPV6}" example.com A >/dev/null \
        || die "DNSCrypt-Proxy did not answer on [${SERVER_IPV6}]:53"
fi

# ------------------------------------------------------ WireGuard integration
WG_DNS="${SERVER_IPV4}"
[[ -z ${SERVER_IPV6} ]] || WG_DNS+=",${SERVER_IPV6}"
save_setting WG_DNS "${WG_DNS}"
save_setting DNSCRYPT_ENABLED "1"
save_setting DNSCRYPT_VERSION "${DNSCRYPT_VERSION}"
save_setting DNSCRYPT_SERVER_NAMES "${DNSCRYPT_SERVER_NAMES}"
save_setting DNSCRYPT_IPV6_UPSTREAM "${DNSCRYPT_IPV6_UPSTREAM}"
save_setting DNSCRYPT_REQUIRE_DNSSEC "${DNSCRYPT_REQUIRE_DNSSEC}"
save_setting DNSCRYPT_REQUIRE_NOLOG "${DNSCRYPT_REQUIRE_NOLOG}"
save_setting DNSCRYPT_REQUIRE_NOFILTER "${DNSCRYPT_REQUIRE_NOFILTER}"

updated_clients=0
while IFS= read -r -d '' client_conf; do
    if grep -q '^DNS[[:space:]]*=' "${client_conf}"; then
        sed -i "s|^DNS[[:space:]]*=.*|DNS = ${WG_DNS}|" "${client_conf}"
    else
        sed -i "/^Address[[:space:]]*=/a DNS = ${WG_DNS}" "${client_conf}"
    fi
    updated_clients=$((updated_clients + 1))
done < <(find "${CLIENTS_DIR}" -type f -name '*.conf' -print0 2>/dev/null)

log "DNSCrypt-Proxy ${DNSCRYPT_VERSION} is active on ${WG_DNS}"
log "New WireGuard clients will use encrypted DNS automatically."
if (( updated_clients > 0 )); then
    warn "Updated ${updated_clients} stored client config(s); re-import them on existing devices."
fi

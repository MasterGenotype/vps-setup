# shellcheck shell=bash disable=SC2034
# Shared helpers sourced by every script in this repo. Not executable on its own.
# (SC2034: variables defined here are consumed by the sourcing scripts.)

WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_INTERFACE}.conf"
CLIENTS_DIR="${WG_DIR}/clients"
SETTINGS_FILE="${WG_DIR}/vps-setup.env"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ ${EUID} -eq 0 ]] || die "This script must be run as root (try: sudo $0)"
}

require_ubuntu() {
    [[ -r /etc/os-release ]] || die "Cannot detect OS (/etc/os-release missing)"
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID} == "ubuntu" || ${ID_LIKE:-} == *ubuntu* || ${ID_LIKE:-} == *debian* ]] \
        || die "This script targets Ubuntu (detected: ${PRETTY_NAME:-unknown})"
}

# Persist a KEY=VALUE pair into the settings file so later scripts
# (add-client, remove-client) reuse the choices made at setup time.
save_setting() {
    local key="$1" value="$2"
    mkdir -p "${WG_DIR}"
    touch "${SETTINGS_FILE}"
    chmod 600 "${SETTINGS_FILE}"
    if grep -q "^${key}=" "${SETTINGS_FILE}"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${SETTINGS_FILE}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${SETTINGS_FILE}"
    fi
}

# Persisted settings only fill in variables that aren't already set, so
# explicit environment overrides (sudo WG_PORT=443 ./...) always win.
load_settings() {
    [[ -r ${SETTINGS_FILE} ]] || return 0
    local key value
    while IFS='=' read -r key value; do
        [[ ${key} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if [[ -z ${!key+set} ]]; then
            printf -v "${key}" '%s' "${value}"
        fi
    done < "${SETTINGS_FILE}"
}

# Default route's interface, e.g. eth0 / ens3.
detect_wan_interface() {
    ip -4 route show default | awk '{for (i=1;i<NF;i++) if ($i=="dev") print $(i+1)}' | head -n1
}

# Public IPv4 of this server. Tries local addresses first, then an
# external lookup for NAT'd hosts.
detect_public_ip() {
    local ip
    ip=$(ip -4 addr show scope global \
        | awk '/inet /{sub(/\/.*/,"",$2); print $2}' \
        | grep -Ev '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' \
        | head -n1) || true
    if [[ -z ${ip} ]]; then
        ip=$(curl -4 -fsS --max-time 10 https://ifconfig.me 2>/dev/null) || true
    fi
    printf '%s' "${ip}"
}

# Validate a client name: it becomes filenames and config sections.
validate_client_name() {
    [[ $1 =~ ^[A-Za-z0-9_-]{1,32}$ ]] \
        || die "Client name must be 1-32 chars of letters, digits, '-' or '_' (got: '$1')"
}

client_exists() {
    [[ -d "${CLIENTS_DIR}/$1" ]]
}

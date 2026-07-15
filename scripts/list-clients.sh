#!/usr/bin/env bash
#
# list-clients.sh — show registered devices and their live connection state.
#
# Usage:
#   sudo ./list-clients.sh
#   sudo ./list-clients.sh --qr phone    # re-print a client's QR code

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
load_settings

if [[ ${1:-} == "--qr" ]]; then
    NAME="${2:-}"
    [[ -n ${NAME} ]] || die "Usage: $0 --qr <client-name>"
    validate_client_name "${NAME}"
    CONF="${CLIENTS_DIR}/${NAME}/${NAME}.conf"
    [[ -f ${CONF} ]] || die "No config for client '${NAME}'"
    qrencode -t ansiutf8 < "${CONF}"
    exit 0
fi

[[ -d ${CLIENTS_DIR} ]] || die "No clients directory — run setup-wireguard.sh first"

shopt -s nullglob
printf '%-20s %-16s %s\n' "NAME" "TUNNEL IP" "LAST HANDSHAKE"
for dir in "${CLIENTS_DIR}"/*/; do
    name="$(basename "${dir}")"
    conf="${dir}${name}.conf"
    [[ -f ${conf} ]] || continue
    ip=$(awk -F' *= *' '/^Address/{print $2}' "${conf}" | cut -d/ -f1 | cut -d, -f1)
    pubkey=$(awk -F' *= *' '/^PrivateKey/{print $2}' "${conf}" | wg pubkey)
    handshake=$(wg show "${WG_INTERFACE}" latest-handshakes 2>/dev/null \
        | awk -v k="${pubkey}" '$1==k {print $2}')
    if [[ -n ${handshake:-} && ${handshake} != "0" ]]; then
        when="$(date -d "@${handshake}" '+%Y-%m-%d %H:%M:%S')"
    else
        when="never"
    fi
    printf '%-20s %-16s %s\n' "${name}" "${ip}" "${when}"
done

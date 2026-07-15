#!/usr/bin/env bash
#
# setup-suricata.sh — install and configure Suricata as an intrusion
# detection (IDS) or prevention (IPS) system on the VPS.
#
# - Installs Suricata from the official OISF stable PPA (falls back to the
#   distro package if the PPA can't be added)
# - Watches the WAN interface; HOME_NET = server IP + WireGuard subnets
# - Fetches the free ET Open ruleset (suricata-update) and refreshes it
#   daily via a systemd timer
# - IDPS mode (default): inline detection + prevention via NFQUEUE — all
#   rules alert, and a conservative set of high-confidence categories
#   (trojan-activity, exploit-kit, command-and-control) is dropped
# - IPS mode: inline, but blocks only the rules you mark as 'drop' in
#   /etc/suricata/drop.conf (starts blocking nothing)
# - IDS mode: passive detection only, alerts to /var/log/suricata/
#
# In the inline modes SSH is never queued (no lockouts) and the queue is
# fail-open (--queue-bypass), so traffic keeps flowing if Suricata stops.
#
# Idempotent: safe to re-run, including to switch modes. The chosen mode
# persists in vps-setup.env, so re-runs keep it unless you override.
#
# Configuration (override via environment or /etc/wireguard/vps-setup.env):
#   SURICATA_MODE      idps | ips | ids       (default: idps)
#   SURICATA_IFACE     interface to monitor   (default: WAN interface)
#   SURICATA_HOME_NET  HOME_NET override      (default: auto-detected)
#
# Usage:
#   sudo ./setup-suricata.sh
#   sudo SURICATA_MODE=ids ./setup-suricata.sh    # detect-only, block nothing
#   sudo SURICATA_IFACE=wg0 ./setup-suricata.sh   # watch tunnel traffic instead

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
require_ubuntu
load_settings

SURICATA_MODE="${SURICATA_MODE:-idps}"
case "${SURICATA_MODE}" in
    ids|ips|idps) ;;
    *) die "SURICATA_MODE must be 'ids', 'ips' or 'idps' (got: '${SURICATA_MODE}')" ;;
esac

SURICATA_YAML="/etc/suricata/suricata.yaml"
NFQUEUE_HELPER="/usr/local/sbin/suricata-nfqueue-rules"

# Suricata + the ET Open ruleset are memory-hungry; warn on small VPSes.
mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
if (( mem_kb < 1500000 )); then
    warn "This VPS has $(( mem_kb / 1024 )) MB RAM; Suricata with the full ET Open"
    warn "ruleset is happiest with 2 GB+. It will run, but watch for memory pressure."
fi

# ---------------------------------------------------------------- packages
export DEBIAN_FRONTEND=noninteractive

log "Adding the OISF Suricata stable PPA..."
apt-get update -q
apt-get install -yq software-properties-common
if ! add-apt-repository -y ppa:oisf/suricata-stable 2>/dev/null; then
    warn "Could not add the OISF PPA — falling back to the distro's suricata package"
fi

log "Installing Suricata (and jq for the alert viewer)..."
apt-get update -q
apt-get install -yq suricata jq
command -v suricata-update >/dev/null 2>&1 || apt-get install -yq suricata-update
command -v suricata-update >/dev/null 2>&1 \
    || die "suricata-update not found after install — cannot manage rules"

# ------------------------------------------------------------ network facts
SURICATA_IFACE="${SURICATA_IFACE:-${WAN_IF:-$(detect_wan_interface)}}"
[[ -n ${SURICATA_IFACE} ]] || die "Could not detect interface; set SURICATA_IFACE=... and re-run"

# HOME_NET: the server's public IP plus the WireGuard tunnel subnets (if the
# VPN is set up), so rules distinguish "us" from the outside world.
if [[ -n ${SURICATA_HOME_NET:-} ]]; then
    HOME_NET="${SURICATA_HOME_NET}"
else
    nets=()
    public_ip="${WG_ENDPOINT:-}"
    [[ ${public_ip} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || public_ip="$(detect_public_ip)"
    [[ -n ${public_ip} ]] && nets+=("${public_ip}/32")
    [[ -n ${WG_IPV4_NET:-} ]] && nets+=("${WG_IPV4_NET}")
    [[ -n ${WG_IPV6_NET:-} ]] && nets+=("${WG_IPV6_NET}")
    (( ${#nets[@]} > 0 )) || nets=(192.168.0.0/16 10.0.0.0/8 172.16.0.0/12)
    HOME_NET="[$(IFS=,; printf '%s' "${nets[*]}")]"
fi

log "Mode      : ${SURICATA_MODE}"
log "Interface : ${SURICATA_IFACE}"
log "HOME_NET  : ${HOME_NET}"

# ------------------------------------------------------------ suricata.yaml
[[ -f ${SURICATA_YAML} ]] || die "${SURICATA_YAML} not found — did the suricata package install?"
cp -n "${SURICATA_YAML}" "${SURICATA_YAML}.orig"

log "Configuring ${SURICATA_YAML}"
sed -i "s|^\( *HOME_NET:\).*|\1 \"${HOME_NET}\"|" "${SURICATA_YAML}"
# First '- interface:' in the file is the af-packet capture interface.
sed -i "0,/^\( *- interface:\).*/s//\1 ${SURICATA_IFACE}/" "${SURICATA_YAML}"
# Community flow IDs make it easy to correlate events with other tools.
sed -i "s/^\( *community-id:\) false/\1 true/" "${SURICATA_YAML}"

# Select the capture mode: af-packet (passive) for IDS, NFQUEUE (inline)
# otherwise. Packagings launch the daemon differently, so instead of
# assuming a config file, take the service's own ExecStart, swap just the
# capture option, and apply it via a systemd drop-in.
if [[ ${SURICATA_MODE} == "ids" ]]; then
    LISTENMODE="af-packet"
    CAPTURE_OPT="--af-packet"
else
    LISTENMODE="nfqueue"
    CAPTURE_OPT="-q 0"
fi

# Older Debian packagings also read these; keep them in sync where present.
if [[ -f /etc/default/suricata ]]; then
    sed -i "s/^LISTENMODE=.*/LISTENMODE=${LISTENMODE}/" /etc/default/suricata
    sed -i "s/^IFACE=.*/IFACE=${SURICATA_IFACE}/" /etc/default/suricata
fi

exec_start="$(systemctl cat suricata.service 2>/dev/null \
    | sed -n 's/^ExecStart=//p' | awk 'NF' | tail -n1)"
[[ -n ${exec_start} ]] || die "Could not read ExecStart from suricata.service — is the package installed?"
exec_start="$(sed -E 's/ --af-packet(=[^ ]*)?//g; s/ -q [0-9]+//g' <<< "${exec_start}") ${CAPTURE_OPT}"

log "Capture mode: ${LISTENMODE}"
mkdir -p /etc/systemd/system/suricata.service.d
cat > /etc/systemd/system/suricata.service.d/vps-setup.conf <<EOF
# Managed by vps-setup/scripts/setup-suricata.sh — selects the capture mode.
[Service]
ExecStart=
ExecStart=${exec_start}
EOF
systemctl daemon-reload

# ---------------------------------------- inline modes (NFQUEUE diversion)
# A small helper inserts/removes the iptables rules that divert traffic to
# Suricata's queue, and a systemd unit ties its lifetime to suricata.service.
if [[ ${SURICATA_MODE} != "ids" ]]; then
    SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
    SSH_PORT="${SSH_PORT:-22}"
    log "Setting up NFQUEUE diversion (SSH port ${SSH_PORT} exempt, fail-open)"

    cat > "${NFQUEUE_HELPER}" <<'EOF'
#!/usr/bin/env bash
# Installed by vps-setup/scripts/setup-suricata.sh — inserts/removes the
# iptables rules that divert traffic to Suricata's NFQUEUE in IPS mode.
# SSH is never queued so a bad rule can't lock you out, and --queue-bypass
# keeps traffic flowing if Suricata itself is down. Accepted packets
# continue down the chain, so UFW and fail2ban still apply.
set -euo pipefail

QUEUE=0
SSH_PORT=__SSH_PORT__

RULES=(
    "INPUT -p tcp ! --dport ${SSH_PORT} -j NFQUEUE --queue-num ${QUEUE} --queue-bypass"
    "INPUT ! -p tcp -j NFQUEUE --queue-num ${QUEUE} --queue-bypass"
    "OUTPUT -p tcp ! --sport ${SSH_PORT} -j NFQUEUE --queue-num ${QUEUE} --queue-bypass"
    "OUTPUT ! -p tcp -j NFQUEUE --queue-num ${QUEUE} --queue-bypass"
    "FORWARD -j NFQUEUE --queue-num ${QUEUE} --queue-bypass"
)

apply() {
    local cmd="$1" action="$2" rule
    for rule in "${RULES[@]}"; do
        # shellcheck disable=SC2086
        if [[ ${action} == up ]]; then
            ${cmd} -C ${rule} 2>/dev/null || ${cmd} -I ${rule}
        else
            ${cmd} -D ${rule} 2>/dev/null || true
        fi
    done
}

case "${1:-}" in
    up)   apply iptables up;   apply ip6tables up ;;
    down) apply iptables down; apply ip6tables down ;;
    *)    echo "usage: $0 up|down" >&2; exit 1 ;;
esac
EOF
    sed -i "s/__SSH_PORT__/${SSH_PORT}/" "${NFQUEUE_HELPER}"
    chmod 755 "${NFQUEUE_HELPER}"

    cat > /etc/systemd/system/suricata-nfqueue.service <<EOF
[Unit]
Description=NFQUEUE diversion rules for Suricata IPS
BindsTo=suricata.service
After=suricata.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${NFQUEUE_HELPER} up
ExecStop=${NFQUEUE_HELPER} down

[Install]
WantedBy=suricata.service
EOF
    systemctl daemon-reload
    systemctl enable suricata-nfqueue.service >/dev/null 2>&1

    # In the inline modes only rules whose action is 'drop' block traffic;
    # everything else still just alerts. drop.conf tells suricata-update
    # which alert rules to convert. Ship a template, never overwrite the
    # user's choices.
    if [[ ! -f /etc/suricata/drop.conf ]]; then
        cat > /etc/suricata/drop.conf <<'EOF'
# Rules matched here are converted from 'alert' to 'drop' by suricata-update,
# so they actively block traffic in IPS/IDPS mode. One pattern per line: a
# signature ID, "gid:sid", or re:<regex> matched against the whole rule.
# After editing, apply with:
#   sudo systemctl start suricata-update.service
#
# Conservative starting points (enabled automatically in IDPS mode):
#re:trojan-activity
#re:exploit-kit
#re:command-and-control
EOF
    fi

    # IDPS mode = detection + prevention out of the box: make sure the
    # conservative high-confidence categories are active (uncomment them if
    # the template shipped them commented, append them if absent). Anything
    # the user added or removed by hand elsewhere in the file is untouched.
    if [[ ${SURICATA_MODE} == "idps" ]]; then
        for pattern in 're:trojan-activity' 're:exploit-kit' 're:command-and-control'; do
            if grep -qxF "${pattern}" /etc/suricata/drop.conf; then
                continue
            elif grep -qxF "#${pattern}" /etc/suricata/drop.conf; then
                sed -i "s|^#${pattern}\$|${pattern}|" /etc/suricata/drop.conf
            else
                printf '%s\n' "${pattern}" >> /etc/suricata/drop.conf
            fi
        done
        log "Prevention enabled for: trojan-activity, exploit-kit, command-and-control"
    fi
else
    # Switching back to IDS: remove any NFQUEUE diversion from a previous run.
    if systemctl list-unit-files suricata-nfqueue.service >/dev/null 2>&1 \
        && [[ -f /etc/systemd/system/suricata-nfqueue.service ]]; then
        log "IDS mode — removing NFQUEUE diversion from previous IPS setup"
        systemctl disable --now suricata-nfqueue.service >/dev/null 2>&1 || true
        if [[ -x ${NFQUEUE_HELPER} ]]; then "${NFQUEUE_HELPER}" down || true; fi
        rm -f /etc/systemd/system/suricata-nfqueue.service "${NFQUEUE_HELPER}"
        systemctl daemon-reload
    fi
fi

# ------------------------------------------------------------------- rules
log "Fetching the ET Open ruleset (this can take a minute)..."
suricata-update --no-test >/dev/null \
    || die "suricata-update failed — check network access and re-run"

log "Scheduling daily rule updates (suricata-update.timer)"
cat > /etc/systemd/system/suricata-update.service <<'EOF'
[Unit]
Description=Refresh Suricata rulesets (suricata-update)
Wants=network-online.target
After=network-online.target suricata.service

[Service]
Type=oneshot
ExecStart=/usr/bin/suricata-update
ExecStartPost=-/bin/sh -c 'suricatasc -c ruleset-reload-rules >/dev/null 2>&1 || systemctl try-restart suricata'
EOF

cat > /etc/systemd/system/suricata-update.timer <<'EOF'
[Unit]
Description=Daily Suricata rule refresh

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now suricata-update.timer >/dev/null

# -------------------------------------------------------------- logrotate
if [[ ! -f /etc/logrotate.d/suricata ]]; then
    log "Adding logrotate policy for /var/log/suricata"
    cat > /etc/logrotate.d/suricata <<'EOF'
/var/log/suricata/*.log /var/log/suricata/*.json {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl kill -s HUP suricata 2>/dev/null || true
    endscript
}
EOF
fi

# ----------------------------------------------------------------- service
log "Validating configuration (suricata -T)..."
suricata -T -c "${SURICATA_YAML}" >/dev/null \
    || die "Config test failed — original config saved at ${SURICATA_YAML}.orig"

log "Enabling and starting suricata"
systemctl enable suricata >/dev/null 2>&1
systemctl restart suricata
systemctl is-active --quiet suricata || die "suricata failed to start — see: journalctl -u suricata"

# --------------------------------------------------------------- settings
save_setting SURICATA_MODE "${SURICATA_MODE}"
save_setting SURICATA_IFACE "${SURICATA_IFACE}"

log "Suricata is up in ${SURICATA_MODE^^} mode on ${SURICATA_IFACE} (rule loading takes ~a minute)."
log "Alerts: sudo ./suricata-alerts.sh   |   logs: /var/log/suricata/{fast.log,eve.json}"
if [[ ${SURICATA_MODE} == "ips" ]]; then
    log "IPS note: only rules marked 'drop' block traffic — edit /etc/suricata/drop.conf to choose."
elif [[ ${SURICATA_MODE} == "idps" ]]; then
    log "IDPS note: trojan-activity, exploit-kit and command-and-control rules are dropped;"
    log "everything else alerts. Tune /etc/suricata/drop.conf, then: systemctl start suricata-update"
fi

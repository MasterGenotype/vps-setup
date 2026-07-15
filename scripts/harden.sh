#!/usr/bin/env bash
#
# harden.sh — basic security hardening for the VPS.
#
# - Automatic security updates (unattended-upgrades)
# - fail2ban protecting SSH
# - SSH hardening: no passwords, no root password login (key-only)
#
# SSH hardening is only applied if an authorized_keys file exists, so you
# can't lock yourself out. Idempotent: safe to re-run.
#
# Usage:
#   sudo ./harden.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
require_ubuntu

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------- automatic security updates
log "Installing unattended-upgrades and fail2ban..."
apt-get update -q
apt-get install -yq unattended-upgrades fail2ban

log "Enabling automatic security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# ----------------------------------------------------------------- fail2ban
log "Configuring fail2ban for SSH"
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# ------------------------------------------------------------ SSH hardening
has_authorized_keys() {
    local f
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        [[ -s ${f} ]] && return 0
    done
    return 1
}

if has_authorized_keys; then
    log "SSH key found — disabling password authentication"
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 4
LoginGraceTime 30
EOF
    if sshd -t; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd
        log "SSH hardened (key-only login)"
    else
        rm -f /etc/ssh/sshd_config.d/99-hardening.conf
        die "sshd config test failed — hardening rolled back, SSH untouched"
    fi
else
    warn "No authorized_keys found — skipping SSH password lockdown so you don't get locked out."
    warn "Add your key (ssh-copy-id) and re-run this script."
fi

log "Hardening complete."

#!/usr/bin/env bash
#
# setup-vnc.sh — install a VNC server with a lightweight XFCE desktop,
# reachable from your phone (Termux / a VNC viewer app) or computer.
#
# VNC itself is weakly encrypted, so the server is never exposed to the
# open Internet. Two access modes:
#
#   vpn (default)  Listens on all interfaces but the firewall only allows
#                  the WireGuard subnet. With the VPN on, connect straight
#                  to the server's tunnel IP (e.g. 10.8.0.1:5901).
#   ssh            Listens on localhost only. Connect through an SSH
#                  tunnel (e.g. from Termux: ssh -L 5901:127.0.0.1:5901 ...).
#
# Configuration (environment variables):
#   VNC_USER      account the desktop runs as   (default: the sudo user,
#                 or a dedicated 'vnc' user; never root)
#   VNC_DISPLAY   display number, port = 5900+N (default: 1)
#   VNC_GEOMETRY  resolution                    (default: 1280x720)
#   VNC_DEPTH     color depth                   (default: 24)
#   VNC_ACCESS    vpn | ssh                     (default: vpn)
#   VNC_PASSWORD  set non-interactively; omit to be prompted (recommended)
#
# Usage:
#   sudo ./setup-vnc.sh
#   sudo VNC_GEOMETRY=1920x1080 VNC_ACCESS=ssh ./setup-vnc.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
require_ubuntu
load_settings

VNC_DISPLAY="${VNC_DISPLAY:-1}"
VNC_GEOMETRY="${VNC_GEOMETRY:-1280x720}"
VNC_DEPTH="${VNC_DEPTH:-24}"
VNC_ACCESS="${VNC_ACCESS:-vpn}"
VNC_PORT=$((5900 + VNC_DISPLAY))

[[ ${VNC_DISPLAY} =~ ^[0-9]+$ ]] || die "VNC_DISPLAY must be a number"
[[ ${VNC_ACCESS} == "vpn" || ${VNC_ACCESS} == "ssh" ]] \
    || die "VNC_ACCESS must be 'vpn' or 'ssh'"

# Never run a desktop session as root: default to the invoking sudo user,
# falling back to a dedicated 'vnc' account.
VNC_USER="${VNC_USER:-${SUDO_USER:-vnc}}"
[[ ${VNC_USER} != "root" ]] || VNC_USER="vnc"

# vpn mode needs the WireGuard subnet from setup-wireguard.sh.
if [[ ${VNC_ACCESS} == "vpn" && -z ${WG_IPV4_NET:-} ]]; then
    warn "No WireGuard settings found — falling back to ssh (localhost-only) mode."
    warn "Run setup-wireguard.sh first if you want direct access over the VPN."
    VNC_ACCESS="ssh"
fi

# ---------------------------------------------------------------- packages
log "Installing XFCE desktop and TigerVNC (this can take a few minutes)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq xfce4 xfce4-terminal dbus-x11 \
    tigervnc-standalone-server tigervnc-common

# ------------------------------------------------------------------- user
if ! id -u "${VNC_USER}" &>/dev/null; then
    log "Creating user '${VNC_USER}'"
    adduser --disabled-password --gecos "VNC desktop user" "${VNC_USER}"
fi
VNC_HOME="$(getent passwd "${VNC_USER}" | cut -d: -f6)"
[[ -d ${VNC_HOME} ]] || die "Home directory for ${VNC_USER} not found"

# --------------------------------------------------------------- password
mkdir -p "${VNC_HOME}/.vnc"
if [[ -f "${VNC_HOME}/.vnc/passwd" ]]; then
    log "Keeping existing VNC password (delete ${VNC_HOME}/.vnc/passwd to reset)"
elif [[ -n ${VNC_PASSWORD:-} ]]; then
    (( ${#VNC_PASSWORD} >= 6 )) || die "VNC_PASSWORD must be at least 6 characters"
    printf '%s' "${VNC_PASSWORD}" | vncpasswd -f > "${VNC_HOME}/.vnc/passwd"
else
    log "Choose a VNC password for user '${VNC_USER}' (used by the viewer app):"
    su - "${VNC_USER}" -c vncpasswd
fi
chmod 600 "${VNC_HOME}/.vnc/passwd"

# --------------------------------------------------------------- xstartup
cat > "${VNC_HOME}/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
chmod +x "${VNC_HOME}/.vnc/xstartup"
chown -R "${VNC_USER}:${VNC_USER}" "${VNC_HOME}/.vnc"

# ---------------------------------------------------------------- service
if [[ ${VNC_ACCESS} == "ssh" ]]; then
    LOCALHOST_OPT="yes"
else
    LOCALHOST_OPT="no"
fi

log "Writing systemd unit vncserver@.service (display :${VNC_DISPLAY}, port ${VNC_PORT})"
cat > /etc/systemd/system/vncserver@.service <<EOF
[Unit]
Description=TigerVNC remote desktop on display :%i
After=network.target

[Service]
Type=simple
User=${VNC_USER}
WorkingDirectory=${VNC_HOME}
PAMName=login
ExecStartPre=-/usr/bin/vncserver -kill :%i
ExecStart=/usr/bin/vncserver :%i -fg -localhost ${LOCALHOST_OPT} -geometry ${VNC_GEOMETRY} -depth ${VNC_DEPTH}
ExecStop=/usr/bin/vncserver -kill :%i
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "vncserver@${VNC_DISPLAY}"

# ---------------------------------------------------------------- firewall
if [[ ${VNC_ACCESS} == "vpn" ]]; then
    log "Allowing VNC port ${VNC_PORT} from the VPN subnet only (${WG_IPV4_NET})"
    ufw allow from "${WG_IPV4_NET}" to any port "${VNC_PORT}" proto tcp \
        comment 'VNC over VPN' >/dev/null
    ufw --force enable >/dev/null
fi

save_setting VNC_USER "${VNC_USER}"
save_setting VNC_DISPLAY "${VNC_DISPLAY}"
save_setting VNC_ACCESS "${VNC_ACCESS}"

# ------------------------------------------------------------ instructions
sleep 2
systemctl --no-pager --quiet is-active "vncserver@${VNC_DISPLAY}" \
    || die "VNC service failed to start — check: journalctl -u vncserver@${VNC_DISPLAY}"

WG_SERVER_IP="${WG_IPV4_NET:+${WG_IPV4_NET%.*/*}.1}"

log "VNC server is running (user: ${VNC_USER}, display :${VNC_DISPLAY})."
echo
if [[ ${VNC_ACCESS} == "vpn" ]]; then
    cat <<EOF
Connect from your phone (WireGuard VPN must be ON):
  1. Install a VNC viewer app (e.g. AVNC from F-Droid, or RealVNC Viewer).
  2. New connection ->  ${WG_SERVER_IP}:${VNC_PORT}
  3. Enter the VNC password you chose above.

Or from Termux with an SSH tunnel (works without the VPN):
  pkg install openssh
  ssh -L ${VNC_PORT}:127.0.0.1:${VNC_PORT} ${VNC_USER}@${WG_ENDPOINT:-<server-ip>}
  # keep that running, then point the VNC viewer app at 127.0.0.1:${VNC_PORT}
EOF
else
    cat <<EOF
The server only listens on localhost — connect through an SSH tunnel.

From Termux on your phone:
  pkg install openssh
  ssh -L ${VNC_PORT}:127.0.0.1:${VNC_PORT} ${VNC_USER}@${WG_ENDPOINT:-<server-ip>}
  # keep that running, then install a VNC viewer app (e.g. AVNC) and
  # connect it to 127.0.0.1:${VNC_PORT}
EOF
fi
echo
echo "Note: Termux is only the tunnel — the actual screen is shown by the"
echo "VNC viewer app. Manage the service with:"
echo "  sudo systemctl {status|restart|stop} vncserver@${VNC_DISPLAY}"

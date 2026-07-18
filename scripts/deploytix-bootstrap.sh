#!/usr/bin/env bash
# deploytix-bootstrap.sh — Prepare a deploytix working tree.
#
# Run as root INSIDE the Artix chroot, it also provisions the build user:
#   - creates ${DEPLOYTIX_USER} (primary group: wheel) with password
#     ${DEPLOYTIX_USER_PASSWORD}, and enables sudo for wheel
#   - persists DISPLAY/XAUTHORITY (host X access, prepared on the host by
#     setup-artix-chroot.sh) in /etc/profile.d/deploytix-gui.sh
#   - clones deploytix (with all vendored submodules) into the user's
#     ~/.gitrepos/deploytix as that user
# Run as a regular user, it just clones/updates the tree for that user.
#
# Usage:
#   deploytix-bootstrap.sh [DEST]            clone/update + submodules
#   deploytix-bootstrap.sh --build [DEST]    additionally run `make install`
#
# Environment overrides:
#   DEPLOYTIX_BRANCH           Deploytix branch to clone/track (default: main)
#   DEPLOYTIX_USER             build user to provision (default: superphenotype)
#   DEPLOYTIX_USER_PASSWORD    its password (default: angel)
#   DEPLOYTIX_GUI_DISPLAY      host X display (default: :1)
#   DEPLOYTIX_GUI_XAUTHORITY   X cookie path (default: /tmp/hostxauth)
set -euo pipefail

REPO_URL="https://github.com/MasterGenotype/Deploytix.git"
REPO_BRANCH="${DEPLOYTIX_BRANCH:-main}"
DEPLOYTIX_USER="${DEPLOYTIX_USER:-superphenotype}"
DEPLOYTIX_USER_PASSWORD="${DEPLOYTIX_USER_PASSWORD:-angel}"
GUI_DISPLAY="${DEPLOYTIX_GUI_DISPLAY:-:1}"
GUI_XAUTHORITY="${DEPLOYTIX_GUI_XAUTHORITY:-/tmp/hostxauth}"

log() { printf '>>> %s\n' "$*"; }

BUILD=0
if [[ "${1:-}" == "--build" ]]; then
    BUILD=1
    shift
fi

if [[ ${EUID} -eq 0 ]]; then
    # --- Provision the build user (chroot / root mode) ---
    if ! id -u "${DEPLOYTIX_USER}" >/dev/null 2>&1; then
        log "Creating user ${DEPLOYTIX_USER} (primary group: wheel)"
        useradd -m -g wheel -s /bin/bash "${DEPLOYTIX_USER}"
    fi
    printf '%s:%s\n' "${DEPLOYTIX_USER}" "${DEPLOYTIX_USER_PASSWORD}" | chpasswd
    log "Password set for ${DEPLOYTIX_USER}"

    # Enable sudo for the wheel group when sudo is present.
    if command -v sudo >/dev/null 2>&1 && [[ -d /etc/sudoers.d ]] \
        && ! grep -Erqs '^\s*%wheel\s+ALL' /etc/sudoers /etc/sudoers.d; then
        printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
        chmod 440 /etc/sudoers.d/10-wheel
        log "Enabled sudo for the wheel group"
    fi

    # Persist the environment needed to reach the host X server.
    cat > /etc/profile.d/deploytix-gui.sh <<EOF_ENV
export DISPLAY=${GUI_DISPLAY}
export XAUTHORITY=${GUI_XAUTHORITY}
EOF_ENV
    chmod 644 /etc/profile.d/deploytix-gui.sh
    log "Persisted DISPLAY=${GUI_DISPLAY} XAUTHORITY=${GUI_XAUTHORITY} in /etc/profile.d/deploytix-gui.sh"

    USER_HOME="$(getent passwd "${DEPLOYTIX_USER}" | cut -d: -f6)"
    DEST="${1:-${USER_HOME}/.gitrepos/deploytix}"
    as_user() { runuser -u "${DEPLOYTIX_USER}" -- "$@"; }
else
    DEST="${1:-${HOME}/.gitrepos/deploytix}"
    as_user() { "$@"; }
fi

# --- Clone or update the deploytix tree ---
if [[ -d "${DEST}/.git" ]]; then
    log "Updating existing clone at ${DEST} (branch: ${REPO_BRANCH})"
    as_user git -C "${DEST}" fetch origin "${REPO_BRANCH}"
    as_user git -C "${DEST}" checkout "${REPO_BRANCH}"
    as_user git -C "${DEST}" pull --ff-only origin "${REPO_BRANCH}"
else
    log "Cloning ${REPO_URL} (branch: ${REPO_BRANCH}) to ${DEST}"
    as_user mkdir -p "$(dirname "${DEST}")"
    as_user git clone --branch "${REPO_BRANCH}" "${REPO_URL}" "${DEST}"
fi

# sync picks up .gitmodules URL changes on pre-existing clones before init.
log "Initializing vendored submodules"
as_user git -C "${DEST}" submodule sync --recursive
as_user git -C "${DEST}" submodule update --init --recursive

log "Submodule status:"
as_user git -C "${DEST}" submodule status --recursive

if [[ "${BUILD}" == 1 ]]; then
    log "Building and installing deploytix"
    as_user make -C "${DEST}" install
fi

log "Done. Working tree ready at ${DEST}"
log "Launch the GUI with:"
log "  sudo env DISPLAY=${GUI_DISPLAY} XAUTHORITY=${GUI_XAUTHORITY} /usr/bin/deploytix-gui"

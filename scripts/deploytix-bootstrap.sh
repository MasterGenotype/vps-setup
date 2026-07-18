#!/usr/bin/env bash
# deploytix-bootstrap.sh — Standalone bootstrapper for a deploytix working tree.
#
# Lives OUTSIDE the deploytix repo (it is the thing that fetches the repo).
# Clones the deploytix repository (or fast-forwards an existing clone), then
# syncs and initializes all vendored submodules (vendor/tkg-gui,
# vendor/gamescope) recursively, so the installer can resolve and build its
# custom packages (deploytix-git, deploytix-gui-git, tkg-gui-git,
# gamescope-git) entirely from the repo tree.
#
# The default destination (~/.gitrepos/deploytix) matches the paths the
# installer searches at runtime.
#
# Usage:
#   deploytix-bootstrap.sh [DEST]            clone/update + submodules
#   deploytix-bootstrap.sh --build [DEST]    additionally run `make install`
set -euo pipefail

REPO_URL="https://github.com/MasterGenotype/Deploytix.git"

BUILD=0
if [[ "${1:-}" == "--build" ]]; then
    BUILD=1
    shift
fi
DEST="${1:-$HOME/.gitrepos/deploytix}"

if [[ -d "$DEST/.git" ]]; then
    echo ">>> Updating existing clone at $DEST"
    git -C "$DEST" pull --ff-only
else
    echo ">>> Cloning $REPO_URL to $DEST"
    mkdir -p "$(dirname "$DEST")"
    git clone "$REPO_URL" "$DEST"
fi

# sync picks up .gitmodules URL changes on pre-existing clones before init.
echo ">>> Initializing vendored submodules"
git -C "$DEST" submodule sync --recursive
git -C "$DEST" submodule update --init --recursive

echo ">>> Submodule status:"
git -C "$DEST" submodule status --recursive

if [[ "$BUILD" == 1 ]]; then
    echo ">>> Building and installing deploytix"
    make -C "$DEST" install
fi

echo ">>> Done. Working tree ready at $DEST"

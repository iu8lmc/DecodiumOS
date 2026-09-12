#!/bin/bash

set -e                  # exit on error
set -o pipefail         # exit on pipeline error
set -u                  # treat unset variable as error

#==========================
# Decodium
#==========================
# Installs Decodium through decodiumos-update-decodium (shipped by mod 50):
# official AppImage release, SHA-256 verified, packaged as "decodium".
# The same command updates it later on an installed system.

if [ -z "${DECODIUM_VERSION:-}" ] || [ -z "${DECODIUM_REPO:-}" ]; then
    print_warn "DECODIUM_VERSION or DECODIUM_REPO is empty — Decodium will not be shipped."
    exit 0
fi

wait_network

print_ok "Recording the Decodium release source..."
install -d -m 0755 /etc/decodiumos
cat > /etc/decodiumos/decodium.conf <<EOF
# Release source used by decodiumos-update-decodium.
# VERSION is "latest" or a release tag to stay on.
REPO=$DECODIUM_REPO
VERSION=latest
EOF
judge "Record the Decodium release source"

print_ok "Installing Decodium ($DECODIUM_VERSION) from $DECODIUM_REPO..."
decodiumos-update-decodium --repo "$DECODIUM_REPO" --version "$DECODIUM_VERSION"
judge "Install Decodium"

test -x /opt/decodium/AppRun && test -L /usr/bin/decodium
judge "Verify the Decodium installation"

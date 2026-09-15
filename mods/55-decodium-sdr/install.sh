#!/bin/bash

set -e                  # exit on error
set -o pipefail         # exit on pipeline error
set -u                  # treat unset variable as error

#==========================
# Decodium SDR
#==========================
# Installs Decodium SDR through decodiumos-update-decodium (shipped by mod 50):
# official AppImage release, SHA-256 verified, packaged as "decodium-sdr".
# The same command updates it later on an installed system.

if [ -z "${DECODIUM_SDR_VERSION:-}" ] || [ -z "${DECODIUM_SDR_REPO:-}" ]; then
    print_warn "DECODIUM_SDR_VERSION or DECODIUM_SDR_REPO is empty — Decodium SDR will not be shipped."
    exit 0
fi

wait_network

print_ok "Recording the Decodium SDR release source..."
install -d -m 0755 /etc/decodiumos
cat > /etc/decodiumos/decodium-sdr.conf <<EOF
# Release source used by: decodiumos-update-decodium --app decodium-sdr
# VERSION is "latest" or a release tag to stay on.
REPO=$DECODIUM_SDR_REPO
VERSION=latest
EOF
judge "Record the Decodium SDR release source"

print_ok "Installing Decodium SDR ($DECODIUM_SDR_VERSION) from $DECODIUM_SDR_REPO..."
decodiumos-update-decodium --app decodium-sdr --repo "$DECODIUM_SDR_REPO" \
    --version "$DECODIUM_SDR_VERSION" --keep-deb /var/cache/decodiumos-debs
judge "Install Decodium SDR"

test -e /opt/decodium-sdr/AppRun && test -L /usr/bin/decodium-sdr
test -f /usr/share/applications/it.decodium.sdr.desktop
# Every shared library the bundled binary needs must resolve inside the image.
missing=$(ldd /opt/decodium-sdr/usr/bin/decodium-sdr | grep 'not found' || true)
if [ -n "$missing" ]; then
    echo "$missing"
    false
fi
judge "Verify the Decodium SDR installation"

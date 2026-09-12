#!/bin/bash

set -e                  # exit on error
set -o pipefail         # exit on pipeline error
set -u                  # treat unset variable as error

#==========================
# DecodiumOS base package
#==========================
# Builds and installs the dpkg-tracked package "decodiumos-base":
#   - distribution identity (os-release, lsb-release, issue) diverted away
#     from AnduinOS base-files, so base-files upgrades never undo it;
#   - radio station integration: udev access rules for CAT/PTT serial ports,
#     ModemManager exclusion, dialout membership, tighter time sync, the
#     "Ham Radio" menu and app folder, and the Decodium updater.
# Static files live in rootfs/ and DEBIAN/ next to this script.

MOD_DIR="$(dirname "$(readlink -f "$0")")"
PACKAGE="decodiumos-base"
MAINTAINER="DecodiumOS <noreply@decodiumos.invalid>"

umask 022
STAGE=$(mktemp -d /tmp/decodiumos-base.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
# mktemp creates 0700; the package root becomes "/" metadata in the archive.
chmod 0755 "$STAGE"

print_ok "Staging $PACKAGE $TARGET_BUILD_VERSION..."
cp -a "$MOD_DIR/rootfs/." "$STAGE/"
find "$STAGE" -name __pycache__ -prune -exec rm -rf {} +
install -d -m 0755 "$STAGE/DEBIAN"
install -m 0755 "$MOD_DIR/DEBIAN/preinst" "$MOD_DIR/DEBIAN/postinst" \
    "$MOD_DIR/DEBIAN/postrm" "$STAGE/DEBIAN/"
chmod 0755 \
    "$STAGE/usr/libexec/decodiumos/ham-groups" \
    "$STAGE/usr/sbin/decodiumos-update-decodium"
# GNOME resolves <DefaultMergeDirs/> of gnome-applications.menu to
# gnome-applications-merged; other desktops read applications-merged.
install -d -m 0755 "$STAGE/etc/xdg/menus/gnome-applications-merged"
ln -s ../applications-merged/decodiumos-hamradio.menu \
    "$STAGE/etc/xdg/menus/gnome-applications-merged/decodiumos-hamradio.menu"
judge "Stage $PACKAGE files"

print_ok "Generating distribution identity files..."
install -d -m 0755 "$STAGE/usr/lib" "$STAGE/etc"
cat > "$STAGE/usr/lib/os-release" <<EOF
PRETTY_NAME="$TARGET_BUSINESS_NAME $TARGET_BUILD_VERSION"
NAME="$TARGET_BUSINESS_NAME"
VERSION_ID="$TARGET_BUILD_VERSION"
VERSION="$TARGET_BUILD_VERSION ($UPSTREAM_BASE_NAME, $TARGET_UBUNTU_VERSION)"
VERSION_CODENAME=$TARGET_UBUNTU_VERSION
ID=$TARGET_NAME
ID_LIKE="ubuntu debian"
HOME_URL="$TARGET_HOME_URL"
UBUNTU_CODENAME=$TARGET_UBUNTU_VERSION
EOF
cat > "$STAGE/etc/lsb-release" <<EOF
DISTRIB_ID=$TARGET_BUSINESS_NAME
DISTRIB_RELEASE=$TARGET_BUILD_VERSION
DISTRIB_CODENAME=$TARGET_UBUNTU_VERSION
DISTRIB_DESCRIPTION="$TARGET_BUSINESS_NAME $TARGET_BUILD_VERSION"
EOF
printf '%s %s \\n \\l\n\n' "$TARGET_BUSINESS_NAME" "$TARGET_BUILD_VERSION" \
    > "$STAGE/etc/issue"
printf '%s %s\n' "$TARGET_BUSINESS_NAME" "$TARGET_BUILD_VERSION" \
    > "$STAGE/etc/issue.net"
judge "Generate distribution identity files"

print_ok "Writing $PACKAGE control file..."
installed_size=$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $TARGET_BUILD_VERSION
Architecture: all
Maintainer: $MAINTAINER
Installed-Size: $installed_size
Depends: base-files, passwd, python3, squashfs-tools, apt
Section: hamradio
Priority: optional
Homepage: $TARGET_HOME_URL
Description: $TARGET_BUSINESS_NAME identity and radio station integration
 Distribution identity for $TARGET_BUSINESS_NAME, based on $UPSTREAM_BASE_NAME,
 plus the system integration an amateur radio station needs: desktop access
 to CAT/PTT serial ports, ModemManager exclusion for radio interfaces,
 dialout membership for local users, tighter NTP polling for FT8/FT4/FT2,
 a Ham Radio application folder and the Decodium updater.
EOF
judge "Write $PACKAGE control file"

deb="/tmp/${PACKAGE}_${TARGET_BUILD_VERSION}_all.deb"
print_ok "Building $deb..."
dpkg-deb --root-owner-group --build "$STAGE" "$deb"
judge "Build $PACKAGE"

print_ok "Installing $PACKAGE..."
apt install -y "$deb"
judge "Install $PACKAGE"
rm -f "$deb"

print_ok "Verifying distribution identity..."
# shellcheck disable=SC1091
( . /etc/os-release && [ "$ID" = "$TARGET_NAME" ] && [ "$VERSION_CODENAME" = "$TARGET_UBUNTU_VERSION" ] )
judge "Verify distribution identity"

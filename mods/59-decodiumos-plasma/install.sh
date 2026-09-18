#!/bin/bash

set -e                  # exit on error
set -o pipefail         # exit on pipeline error
set -u                  # treat unset variable as error

#==========================
# DecodiumOS Plasma edition
#==========================
# Only runs when DECODIUMOS_EDITION=plasma. Installs a complete KDE Plasma
# desktop next to the AnduinOS/GNOME one — the Live session, the installer
# and the update path stay exactly the ones the classic edition uses — and
# builds the package "decodiumos-plasma", which makes Plasma the session the
# login screen offers by default and gives it the DecodiumOS colours.
#
# The same package in the update repository turns a classic DecodiumOS into a
# Plasma one: "sudo apt install decodiumos-plasma".

if [ "${DECODIUMOS_EDITION:-gnome}" != "plasma" ]; then
    print_info "Edition ${DECODIUMOS_EDITION:-gnome}: skipping the Plasma desktop."
    exit 0
fi

MOD_DIR="$(dirname "$(readlink -f "$0")")"
PACKAGE="decodiumos-plasma"
MAINTAINER="DecodiumOS <noreply@decodiumos.invalid>"
PLASMA_SET="${PLASMA_PACKAGE_SET:-kde-standard}"

wait_network

# kde-standard pulls SDDM in. The Live session, its autologin and the
# installer are built around GDM, so GDM stays the display manager; the
# answer is preseeded because the SDDM package would otherwise ask.
print_ok "Keeping GDM as the display manager..."
echo "/usr/sbin/gdm3" > /etc/X11/default-display-manager
for pkg in gdm3 sddm; do
    echo "$pkg shared/default-x-display-manager select gdm3" | debconf-set-selections
done
judge "Keep GDM as the display manager"

print_ok "Installing the Plasma desktop ($PLASMA_SET)..."
apt-get install -y "$PLASMA_SET"
judge "Install $PLASMA_SET"

print_ok "Checking the display manager and the Plasma session..."
systemctl disable sddm.service > /dev/null 2>&1 || true
systemctl mask sddm.service > /dev/null 2>&1 || true
test "$(cat /etc/X11/default-display-manager)" = "/usr/sbin/gdm3"
readlink -f /etc/systemd/system/display-manager.service | grep -q gdm3
test -f /usr/share/wayland-sessions/plasma.desktop
test -f /usr/share/xsessions/plasmax11.desktop
judge "Verify the display manager and the Plasma session"

umask 022
STAGE=$(mktemp -d /tmp/decodiumos-plasma.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
chmod 0755 "$STAGE"

print_ok "Staging $PACKAGE $TARGET_BUILD_VERSION..."
cp -a "$MOD_DIR/rootfs/." "$STAGE/"
install -d -m 0755 "$STAGE/DEBIAN"
install -m 0755 "$MOD_DIR/DEBIAN/postinst" "$MOD_DIR/DEBIAN/postrm" "$STAGE/DEBIAN/"
chmod 0755 \
    "$STAGE/usr/libexec/decodiumos/plasma-first-run" \
    "$STAGE/usr/libexec/decodiumos/plasma-default-session"
install -d -m 0755 "$STAGE/usr/share/doc/$PACKAGE"
cat > "$STAGE/usr/share/doc/$PACKAGE/README" <<EOF
$TARGET_BUSINESS_NAME $TARGET_BUILD_VERSION - Plasma edition

Plasma is the session the login screen offers by default. To use GNOME
instead, pick it from the gear menu of the login screen once: the choice is
remembered and this package never overrides it again.

The DecodiumOS colours (scheme "Decodium Ocean Blue") and the wallpaper are
applied at the first Plasma login of each user by
/usr/libexec/decodiumos/plasma-first-run; afterwards Aspetto/System Settings
is in charge.
EOF
judge "Stage $PACKAGE files"

print_ok "Writing $PACKAGE control file..."
installed_size=$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $TARGET_BUILD_VERSION
Architecture: all
Maintainer: $MAINTAINER
Installed-Size: $installed_size
Depends: decodiumos-desktop (>= $TARGET_BUILD_VERSION), $PLASMA_SET, plasma-workspace, accountsservice
Section: metapackages
Priority: optional
Homepage: $TARGET_HOME_URL
Description: $TARGET_BUSINESS_NAME with the KDE Plasma desktop
 Pulls in the complete KDE Plasma desktop ($PLASMA_SET), makes Plasma the
 session the login screen offers by default and gives it the $TARGET_BUSINESS_NAME
 colours. The GNOME session, the installer and every radio application stay
 in place, so the login screen can still return to the classic desktop.
EOF
judge "Write $PACKAGE control file"

deb="/tmp/${PACKAGE}_${TARGET_BUILD_VERSION}_all.deb"
print_ok "Building $deb..."
dpkg-deb --root-owner-group --build "$STAGE" "$deb"
judge "Build $PACKAGE"

print_ok "Installing $PACKAGE..."
apt-get install -y "$deb"
install -D -m 0644 "$deb" "/var/cache/decodiumos-debs/$(basename "$deb")"
rm -f "$deb"
judge "Install $PACKAGE"

print_ok "Verifying the Plasma edition..."
test -x /usr/bin/plasmashell
test -x /usr/bin/plasma-apply-colorscheme
test -f /usr/share/color-schemes/DecodiumOcean.colors
/usr/libexec/decodiumos/plasma-default-session
judge "Verify the Plasma edition"

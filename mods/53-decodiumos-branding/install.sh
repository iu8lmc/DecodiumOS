#!/bin/bash

set -e                  # exit on error
set -o pipefail         # exit on pipeline error
set -u                  # treat unset variable as error

#==========================
# DecodiumOS branding
#==========================
# Builds and installs the dpkg-tracked package "decodiumos-branding":
#   - the DecodiumOS logo, wordmark, wallpapers, installer slides and
#     Plymouth boot splash, rendered here from artwork/*.svg in the
#     Decodium 4 "Ocean Blue" palette;
#   - the desktop colours (dconf: wallpaper, taskbar, start menu);
#   - /usr/libexec/decodiumos/rebrand, which diverts the AnduinOS-branded
#     files of the base system (installer, welcome app, launchers,
#     translations, logos) and generates DecodiumOS copies, re-run by an
#     APT hook after every package operation.

MOD_DIR="$(dirname "$(readlink -f "$0")")"
ART="$MOD_DIR/artwork"
PACKAGE="decodiumos-branding"
MAINTAINER="DecodiumOS <noreply@decodiumos.invalid>"

print_ok "Installing the SVG renderer..."
apt install -y --no-install-recommends librsvg2-bin
judge "Install the SVG renderer"

umask 022
STAGE=$(mktemp -d /tmp/decodiumos-branding.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
chmod 0755 "$STAGE"

render() {  # render <svg> <png> <rsvg-convert size options...>
    local svg="$1" png="$2"
    shift 2
    install -d -m 0755 "$(dirname "$png")"
    rsvg-convert "$@" -o "$png" "$svg"
}

print_ok "Staging $PACKAGE files..."
cp -a "$MOD_DIR/rootfs/." "$STAGE/"
find "$STAGE" -name __pycache__ -prune -exec rm -rf {} +
install -d -m 0755 "$STAGE/DEBIAN"
install -m 0755 "$MOD_DIR/DEBIAN/postinst" "$MOD_DIR/DEBIAN/prerm" \
    "$MOD_DIR/DEBIAN/postrm" "$STAGE/DEBIAN/"
chmod 0755 "$STAGE/usr/libexec/decodiumos/rebrand"
judge "Stage $PACKAGE files"

print_ok "Rendering the DecodiumOS logo..."
share="$STAGE/usr/share/decodiumos"
install -D -m 0644 "$ART/logo.svg" "$share/decodiumos-logo.svg"
install -D -m 0644 "$ART/logo.svg" "$STAGE/usr/share/icons/hicolor/scalable/apps/decodiumos-logo.svg"
for size in 16 22 24 32 48 64 128 256 512; do
    render "$ART/logo.svg" \
        "$STAGE/usr/share/icons/hicolor/${size}x${size}/apps/decodiumos-logo.png" \
        -w "$size" -h "$size"
done
install -D -m 0644 "$STAGE/usr/share/icons/hicolor/256x256/apps/decodiumos-logo.png" \
    "$STAGE/usr/share/pixmaps/decodiumos-logo.png"
# GDM shows this at its natural size under the login prompt.
render "$ART/lockup.svg" "$share/decodiumos-login-logo.png" -h 64
judge "Render the DecodiumOS logo"

print_ok "Rendering the wallpapers..."
for variant in dark light; do
    render "$ART/wallpaper-$variant.svg" \
        "$STAGE/usr/share/backgrounds/decodiumos/decodiumos-$variant.png" -w 3840 -h 2160
done
judge "Render the wallpapers"

print_ok "Rendering the Plymouth boot splash..."
theme="$STAGE/usr/share/plymouth/themes/decodiumos"
render "$ART/lockup.svg" "$theme/watermark.png" -h 80
for frame in $(seq 1 60); do
    angle=$(( (frame - 1) * 6 ))
    sed "s/@ANGLE@/$angle/" "$ART/throbber.svg" > "$STAGE/throbber.svg"
    render "$STAGE/throbber.svg" "$theme/throbber-$(printf %04d "$frame").png" -w 64 -h 64
    cp "$theme/throbber-$(printf %04d "$frame").png" "$theme/animation-$(printf %04d "$frame").png"
done
rm -f "$STAGE/throbber.svg"
judge "Render the Plymouth boot splash"

print_ok "Rendering the installer slides..."
for svg in "$ART"/slides/*.svg; do
    render "$svg" "$share/slideshow/screenshots/$(basename "$svg" .svg).png" -w 752 -h 376
done
judge "Render the installer slides"

print_ok "Writing $PACKAGE control file..."
installed_size=$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $TARGET_BUILD_VERSION
Architecture: all
Maintainer: $MAINTAINER
Installed-Size: $installed_size
Depends: decodiumos-base, python3, dpkg, plymouth-anduinos, plymouth-theme-ubuntu-text
Recommends: fastfetch
Section: misc
Priority: optional
Homepage: $TARGET_HOME_URL
Description: $TARGET_BUSINESS_NAME look: logo, colours, boot splash and wallpapers
 The $TARGET_BUSINESS_NAME visual identity in the Decodium 4 Ocean Blue palette:
 logo, wallpapers, Plymouth boot splash, login screen, start menu and
 taskbar colours, and installer slides. It also presents the
 $UPSTREAM_BASE_NAME-branded parts of the base system (installer, welcome
 app, launchers, translations) as $TARGET_BUSINESS_NAME, keeping them in step
 with upstream upgrades through an APT hook.
EOF
judge "Write $PACKAGE control file"

deb="/tmp/${PACKAGE}_${TARGET_BUILD_VERSION}_all.deb"
print_ok "Building $deb..."
dpkg-deb --root-owner-group --build "$STAGE" "$deb"
judge "Build $PACKAGE"

print_ok "Installing $PACKAGE..."
apt install -y --reinstall "$deb"
rm -f "$deb"
judge "Install $PACKAGE"

# The postinst is tolerant on users' machines; the image build is not.
print_ok "Applying the DecodiumOS branding..."
/usr/libexec/decodiumos/rebrand
judge "Apply the DecodiumOS branding"

print_ok "Verifying the DecodiumOS branding..."
test "$(update-alternatives --query default.plymouth | sed -n 's/^Value: //p')" = \
    /usr/share/plymouth/themes/decodiumos/decodiumos.plymouth
test "$(update-alternatives --query gdm-theme.gresource | sed -n 's/^Value: //p')" = \
    /var/lib/decodiumos/gdm-theme.gresource
grep -q '^Name=DecodiumOS Installer' /usr/share/applications/anduinos-installer-beta.desktop
if grep -rq 'EFI/AnduinOS' /usr/lib/anduinos-installer-beta --include='*.py'; then
    print_error "The installer still references EFI/AnduinOS"
    exit 1
fi
/usr/libexec/decodiumos/rebrand --check | grep -qx 'rebrand: nothing to do'
judge "Verify the DecodiumOS branding"

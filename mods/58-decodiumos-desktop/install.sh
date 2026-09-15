#!/bin/bash

set -e                  # exit on error
set -o pipefail         # exit on pipeline error
set -u                  # treat unset variable as error

#==========================
# DecodiumOS metapackage
#==========================
# "decodiumos-desktop" depends on every DecodiumOS package of this release.
# Installing or upgrading it from the DecodiumOS update repository is how an
# installed system receives new DecodiumOS components (e.g. decodium-rx in
# 1.2.0) without downloading a new ISO. Add new packages to DEPENDS here.

PACKAGE="decodiumos-desktop"
MAINTAINER="DecodiumOS <noreply@decodiumos.invalid>"

depends=("decodiumos-base (>= $TARGET_BUILD_VERSION)" "decodiumos-branding (>= $TARGET_BUILD_VERSION)")
for optional in decodium decodium-rx decodium-sdr qlog; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$optional" 2>/dev/null | grep -q '^ii'; then
        depends+=("$optional")
    fi
done

umask 022
STAGE=$(mktemp -d /tmp/decodiumos-desktop.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
chmod 0755 "$STAGE"
install -d -m 0755 "$STAGE/DEBIAN" "$STAGE/usr/share/doc/$PACKAGE"
cat > "$STAGE/usr/share/doc/$PACKAGE/README" <<EOF
$TARGET_BUSINESS_NAME $TARGET_BUILD_VERSION

This metapackage pulls in every $TARGET_BUSINESS_NAME component. Updates come
from the $TARGET_BUSINESS_NAME repository ($DECODIUMOS_APT_URL) through
"sudo apt update && sudo apt full-upgrade" or the Software application.
EOF

print_ok "Building $PACKAGE $TARGET_BUILD_VERSION..."
depends_line=$(printf '%s, ' "${depends[@]}")
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $TARGET_BUILD_VERSION
Architecture: all
Maintainer: $MAINTAINER
Depends: ${depends_line%, }
Section: metapackages
Priority: optional
Homepage: $TARGET_HOME_URL
Description: $TARGET_BUSINESS_NAME desktop for radio amateurs (metapackage)
 Depends on every $TARGET_BUSINESS_NAME component of release $TARGET_BUILD_VERSION,
 so upgrading this package from the $TARGET_BUSINESS_NAME repository brings an
 installed system up to date, new components included.
EOF
deb="/tmp/${PACKAGE}_${TARGET_BUILD_VERSION}_all.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$deb"
judge "Build $PACKAGE"

print_ok "Installing $PACKAGE..."
apt install -y --reinstall "$deb"
install -D -m 0644 "$deb" "/var/cache/decodiumos-debs/$(basename "$deb")"
rm -f "$deb"
judge "Install $PACKAGE"

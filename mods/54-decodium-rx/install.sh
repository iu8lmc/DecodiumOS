#!/bin/bash

set -e                  # exit on error
set -o pipefail         # exit on pipeline error
set -u                  # treat unset variable as error

#==========================
# Decodium RX (terminal)
#==========================
# Builds and installs the dpkg-tracked package "decodium-rx": a receive-only
# FT8/FT4/FT2 decoder for the terminal (rootfs/usr/bin/decodium-rx) on top
# of decodium-rx-core, Decodium 4's own decode workers built as a command
# line program from the Decodium sources at the installed release
# (core/patch-core.py adds the target).
#
# The compiler tool chain and -dev packages are only needed here: every
# package this mod installs, except the runtime libraries decodium-rx-core
# links against, is purged again before the mod ends, and the release
# package policy is checked afterwards.

MOD_DIR="$(dirname "$(readlink -f "$0")")"
PACKAGE="decodium-rx"
MAINTAINER="DecodiumOS <noreply@decodiumos.invalid>"
REPO="${DECODIUM_REPO:-iu8lmc/Decodium-4.0-Core-Shannon}"
SRC=/tmp/decodium-rx-src
WORK=/tmp/decodium-rx-work

# Same subset of the image policy as mods/51-hamradio-apps.
FORBIDDEN_RE='^(autoconf|automake|bison|build-essential|dkms|dpkg-dev|fakeroot|flex|gdb|libtool|make|make-guile|snapd|xterm|gnome-terminal|tilix|alacritty|zutty|(gcc|g\+\+)(-[0-9]+)?(-(x86-64|aarch64)-linux-gnu)?|lib(gcc|stdc\+\+)-[0-9]+-dev|libreoffice(-.*)?)$'

BUILD_DEPS=(
    git cmake ninja-build g++ gfortran pkg-config
    qt6-base-dev qt6-base-private-dev qt6-declarative-dev qt6-multimedia-dev
    qt6-serialport-dev qt6-websockets-dev qt6-tools-dev qt6-tools-dev-tools
    qt6-l10n-tools qt6-5compat-dev qt6-shadertools-dev
    libfftw3-dev libboost-log-dev libhamlib-dev libusb-1.0-0-dev
    portaudio19-dev libudev-dev libgl-dev
)

installed_packages() {
    dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' | \
        awk '$1 == "ii" { sub(/:.*/, "", $2); print $2 }' | LC_ALL=C sort -u
}

cleanup() { [ -n "${DECODIUM_RX_KEEP:-}" ] || rm -rf "$SRC" "$WORK"; }
trap cleanup EXIT

wait_network

print_ok "Choosing the Decodium source release..."
decodium_version=$(dpkg-query -W -f='${Version}' decodium 2>/dev/null || true)
if [ -n "$decodium_version" ]; then
    tag="v$decodium_version"
else
    tag=$(python3 -c "import json, urllib.request; print(json.load(urllib.request.urlopen(urllib.request.Request('https://api.github.com/repos/$REPO/releases/latest', headers={'User-Agent': 'decodiumos-build'})))['tag_name'])")
fi
echo "Decodium source: $REPO @ $tag"
judge "Choose the Decodium source release"

before=$(installed_packages)

print_ok "Installing the temporary build dependencies..."
apt install -y --no-install-recommends "${BUILD_DEPS[@]}"
judge "Install the temporary build dependencies"

print_ok "Fetching the Decodium $tag sources..."
rm -rf "$SRC"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" \
    "https://github.com/$REPO.git" "$SRC"
judge "Fetch the Decodium sources"

print_ok "Building decodium-rx-core..."
python3 "$MOD_DIR/core/patch-core.py" "$SRC"
cmake -S "$SRC" -B "$SRC/build" -G Ninja -Wno-dev \
    -DCMAKE_BUILD_TYPE=Release -DWSJT_BUILD_UTILS=ON -DWSJT_GENERATE_DOCS=OFF \
    -DWSJT_SKIP_MANPAGES=ON -DENABLE_OMNIRIG=OFF -DDECODIUM_ENABLE_HAMDRM=OFF \
    -DDECODIUM_ENABLE_SSTV=OFF -DDECODIUM_ENABLE_RTLSDR=OFF > /tmp/decodium-rx-cmake.log 2>&1 \
    || { tail -40 /tmp/decodium-rx-cmake.log; exit 1; }
ninja -C "$SRC/build" -j"$(nproc)" decodium_rx_core decodium_ft2sim ft8sim ft4sim \
    > /tmp/decodium-rx-ninja.log 2>&1 \
    || { grep -E "error|undefined" /tmp/decodium-rx-ninja.log | head -40; exit 1; }
rm -f /tmp/decodium-rx-cmake.log /tmp/decodium-rx-ninja.log
judge "Build decodium-rx-core"

print_ok "Staging $PACKAGE..."
umask 022
STAGE="$WORK/pkg"
rm -rf "$WORK"
install -d -m 0755 "$STAGE/DEBIAN" "$STAGE/usr/lib/decodium-rx"
cp -a "$MOD_DIR/rootfs/." "$STAGE/"
chmod 0755 "$STAGE/usr/bin/decodium-rx"
install -m 0755 "$SRC/build/decodium_rx_core" "$STAGE/usr/lib/decodium-rx/decodium-rx-core"
core_version=$("$STAGE/usr/lib/decodium-rx/decodium-rx-core" --version 2>/dev/null | tail -1 || true)
judge "Stage $PACKAGE"

print_ok "Self-test: decoding simulated FT8, FT4 and FT2 slots..."
mkdir -p "$WORK/test" && cd "$WORK/test"
"$SRC/build/ft8sim" "CQ DX IU8LMC JN70" 1500 0.2 0 0 1 -16 > /dev/null
mv 000000_000001.wav 260101_120000.wav
"$SRC/build/ft4sim" "IU8LMC K1ABC FN42" 900 0.1 0 0 1 -12 > /dev/null
mv 000000_000001.wav 260101_120007.wav
"$SRC/build/decodium_ft2sim" "CQ IU8LMC JN70" 1450 -8 260101_120003.wav
export DECODIUM_RX_CORE="$STAGE/usr/lib/decodium-rx/decodium-rx-core"
selftest() {  # selftest <mode> <wav> <expected message>
    local out
    out=$(python3 "$STAGE/usr/bin/decodium-rx" --no-log --no-color -m "$1" --wav "$2")
    echo "$out"
    grep -qF "$3" <<< "$out" || { print_error "$1 self-test did not decode: $3"; exit 1; }
}
selftest ft8 260101_120000.wav "CQ DX IU8LMC JN70"
selftest ft4 260101_120007.wav "IU8LMC K1ABC FN42"
selftest ft2 260101_120003.wav "CQ IU8LMC JN70"
unset DECODIUM_RX_CORE
cd /
judge "Self-test decodium-rx"

print_ok "Resolving the runtime libraries of decodium-rx-core..."
runtime_pkgs=()
while read -r lib; do
    pkg=$(dpkg -S "$lib" 2>/dev/null | head -1 | cut -d: -f1 || true)
    [ -n "$pkg" ] || pkg=$(dpkg -S "$(readlink -f "$lib")" 2>/dev/null | head -1 | cut -d: -f1 || true)
    if [ -z "$pkg" ]; then
        alt=${lib/#\/lib\//\/usr\/lib\/}
        pkg=$(dpkg -S "$alt" 2>/dev/null | head -1 | cut -d: -f1 || true)
    fi
    [ -n "$pkg" ] || { print_error "no package owns $lib"; exit 1; }
    runtime_pkgs+=("$pkg")
done < <(ldd "$STAGE/usr/lib/decodium-rx/decodium-rx-core" | awk '/=> \// { print $3 }')
mapfile -t runtime_pkgs < <(printf '%s\n' "${runtime_pkgs[@]}" | sort -u)
if printf '%s\n' "${runtime_pkgs[@]}" | grep -qE -- '-dev$'; then
    print_error "decodium-rx-core links against a -dev package: $(printf '%s\n' "${runtime_pkgs[@]}" | grep -E -- '-dev$' | xargs)"
    exit 1
fi
echo "Runtime packages: ${runtime_pkgs[*]}"
judge "Resolve the runtime libraries"

print_ok "Building the $PACKAGE package..."
depends="python3, alsa-utils | pulseaudio-utils, $(printf '%s, ' "${runtime_pkgs[@]}" | sed 's/, $//')"
pkg_version="${decodium_version:-${tag#v}}+decodiumos${TARGET_BUILD_VERSION}"
installed_size=$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $pkg_version
Architecture: $TARGET_ARCH
Maintainer: $MAINTAINER
Installed-Size: $installed_size
Depends: $depends
Section: hamradio
Priority: optional
Homepage: https://github.com/$REPO
Description: FT8/FT4/FT2 receive-only decoder for the terminal (Decodium 4 core)
 decodium-rx captures audio from the radio's sound card, cuts it into
 UTC-aligned slots and decodes them with the Decodium 4 decode workers,
 built as a command-line program from the Decodium $tag sources
 ($core_version). Receive only: it never transmits or keys the radio.
EOF
deb="$WORK/${PACKAGE}_${pkg_version}_${TARGET_ARCH}.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$deb"
judge "Build the $PACKAGE package"

print_ok "Installing $PACKAGE..."
apt install -y --reinstall "$deb"
judge "Install $PACKAGE"

print_ok "Purging the temporary build dependencies..."
# Mark everything this mod installed as automatic, let apt work out which of
# it decodium-rx still needs, and purge only the rest: packages that were
# already orphaned before this mod are left alone.
new_pkgs=$(comm -13 <(printf '%s\n' "$before") <(installed_packages) | grep -vx "$PACKAGE" || true)
if [ -n "$new_pkgs" ]; then
    # shellcheck disable=SC2086
    apt-mark auto $new_pkgs > /dev/null
fi
# A package that was already in the image may merely *recommend* part of
# the tool chain (libc6-dev recommends gcc), which keeps it off the autoremove
# list: those are purged by name, then autoremove is consulted again.
for pass in 1 2 3; do
    removable=$(apt-get -s autoremove | awk '/^Remv / { sub(/:.*/, "", $2); print $2 }' | LC_ALL=C sort -u)
    # By name: the tool chain, every new development package and the
    # requested build dependencies themselves (only packages this mod added).
    forbidden=$(comm -13 <(printf '%s\n' "$before") <(installed_packages) | \
        grep -E "$FORBIDDEN_RE|-dev\$|-dev-bin\$|-dev-tools\$|^($(IFS='|'; echo "${BUILD_DEPS[*]}"))\$" || true)
    to_purge=$( { comm -12 <(printf '%s\n' "$removable") <(printf '%s\n' "$new_pkgs" | LC_ALL=C sort -u)
                  printf '%s\n' "$forbidden"; } | sed '/^$/d' | LC_ALL=C sort -u)
    [ -n "$to_purge" ] || break
    echo "Pass $pass: purging $(wc -w <<< "$to_purge") build packages"
    # shellcheck disable=SC2086
    apt-get -y purge $to_purge
done
judge "Purge the temporary build dependencies"

print_ok "Checking the release package policy..."
violations=$(comm -13 <(printf '%s\n' "$before") <(installed_packages) | grep -E "$FORBIDDEN_RE" || true)
if [ -n "$violations" ]; then
    print_error "Build dependencies left in the image: $(echo "$violations" | xargs)"
    exit 1
fi
leftover_dev=$(comm -13 <(printf '%s\n' "$before") <(installed_packages) | grep -E -- '-dev$' || true)
if [ -n "$leftover_dev" ]; then
    print_error "Development packages left in the image: $(echo "$leftover_dev" | xargs)"
    exit 1
fi
decodium-rx --help > /dev/null
/usr/lib/decodium-rx/decodium-rx-core --version
judge "Check the release package policy"

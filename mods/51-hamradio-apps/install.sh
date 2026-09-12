#!/bin/bash

set -e                  # exit on error
set -o pipefail         # exit on pipeline error
set -u                  # treat unset variable as error

#==========================
# Ham radio applications
#==========================
# Installs the package sets named in HAM_PACKAGE_SETS (args.sh). Each set is
# sets/<name>.list: one Ubuntu package per line, '#' starts a comment.
# A package is skipped with a warning when it has no candidate for this
# release/architecture, or when it would pull a package the release policy
# forbids in the image, so one bad entry never breaks the build.

MOD_DIR="$(dirname "$(readlink -f "$0")")"
MANIFEST=/var/lib/decodiumos/hamradio-packages.list

# Subset of FORBIDDEN_IMAGE_PACKAGES in tests/assertions/install.py that a
# ham application can realistically drag in: a compiler tool chain, a second
# terminal emulator or snapd.
FORBIDDEN_RE='^(autoconf|automake|bison|build-essential|dkms|dpkg-dev|fakeroot|flex|gdb|libtool|make|make-guile|snapd|xterm|gnome-terminal|tilix|alacritty|zutty|(gcc|g\+\+)(-[0-9]+)?(-(x86-64|aarch64)-linux-gnu)?|lib(gcc|stdc\+\+)-[0-9]+-dev|libreoffice(-.*)?)$'

installed_packages() {
    dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' | \
        awk '$1 == "ii" { sub(/:.*/, "", $2); print $2 }' | sort -u
}

if [ -z "${HAM_PACKAGE_SETS:-}" ]; then
    print_warn "HAM_PACKAGE_SETS is empty — no ham radio applications will be installed."
    exit 0
fi

wait_network

print_ok "Reading ham radio package sets: $HAM_PACKAGE_SETS"
requested=()
declare -A seen=()
for set_name in $HAM_PACKAGE_SETS; do
    list="$MOD_DIR/sets/$set_name.list"
    if [ ! -f "$list" ]; then
        print_error "Unknown ham package set '$set_name' (no $list)"
        exit 1
    fi
    while read -r pkg _; do
        [ -n "${seen[$pkg]:-}" ] && continue
        seen[$pkg]=1
        requested+=("$pkg")
    done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$list")
done
judge "Read ham radio package sets"

print_ok "Resolving ${#requested[@]} packages for $TARGET_UBUNTU_VERSION/$TARGET_ARCH..."
accepted=()
skipped=()
for pkg in "${requested[@]}"; do
    if ! simulation=$(apt-get install -s -y --no-install-recommends "$pkg" 2>&1); then
        print_warn "Skipping $pkg: not installable on $TARGET_UBUNTU_VERSION/$TARGET_ARCH"
        skipped+=("$pkg")
        continue
    fi
    offenders=$(printf '%s\n' "$simulation" | \
        awk '/^Inst / { sub(/:.*/, "", $2); print $2 }' | \
        grep -E "$FORBIDDEN_RE" || true)
    if [ -n "$offenders" ]; then
        print_warn "Skipping $pkg: it would install forbidden packages: $(echo "$offenders" | xargs)"
        skipped+=("$pkg")
        continue
    fi
    accepted+=("$pkg")
done
judge "Resolve ham radio packages"

if [ "${#accepted[@]}" -eq 0 ]; then
    print_warn "No ham radio package is installable — nothing to do."
    exit 0
fi

before=$(installed_packages)

print_ok "Installing ${#accepted[@]} ham radio packages..."
apt install -y --no-install-recommends "${accepted[@]}"
judge "Install ham radio applications"

print_ok "Checking the release package policy..."
violations=$(comm -13 <(printf '%s\n' "$before") <(installed_packages) | \
    grep -E "$FORBIDDEN_RE" || true)
if [ -n "$violations" ]; then
    print_error "Ham radio packages pulled forbidden packages: $(echo "$violations" | xargs)"
    exit 1
fi
judge "Check the release package policy"

print_ok "Writing $MANIFEST..."
install -d -m 0755 "$(dirname "$MANIFEST")"
{
    echo "# Ham radio packages selected by DecodiumOS (sets: $HAM_PACKAGE_SETS)"
    printf 'installed %s\n' "${accepted[@]}"
    if [ "${#skipped[@]}" -gt 0 ]; then
        printf 'skipped %s\n' "${skipped[@]}"
    fi
} > "$MANIFEST"
judge "Write $MANIFEST"

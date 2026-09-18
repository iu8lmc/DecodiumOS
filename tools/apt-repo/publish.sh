#!/bin/bash
# Publish DecodiumOS packages to the update repository.
#
#   tools/apt-repo/publish.sh dist/packages/1.2.0-amd64 [more package dirs...]
#
# Keeps a local copy of the repository (DECODIUMOS_APT_LOCAL, default
# ~/decodiumos-apt), adds the given .deb files to its pool, regenerates and
# signs the indexes with the DecodiumOS archive key, writes setup.sh for
# systems installed before the repository existed, and uploads everything to
# the server (only new or changed files are transferred).
#
# Environment:
#   DECODIUMOS_APT_KEY      signing key fingerprint (default: ~/decodiumos-apt-key/fingerprint)
#   DECODIUMOS_APT_REMOTE   rsync destination (default: community.ft2.it downloads/decodiumos/apt)
#   DECODIUMOS_APT_SSH_KEY  ssh identity for the upload (default: ~/.ssh/ft2deploy_ed25519)
#   DECODIUMOS_APT_NO_UPLOAD=1  build and sign locally only
set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
ROOT="$(dirname "$(dirname "$HERE")")"
# shellcheck disable=SC1091
URL=$(bash -c "source '$ROOT/args.sh' >/dev/null 2>&1; echo \$DECODIUMOS_APT_URL")
SUITE=$(bash -c "source '$ROOT/args.sh' >/dev/null 2>&1; echo \$DECODIUMOS_APT_SUITE")
LOCAL="${DECODIUMOS_APT_LOCAL:-$HOME/decodiumos-apt}"
KEY="${DECODIUMOS_APT_KEY:-$(cat "$HOME/decodiumos-apt-key/fingerprint")}"
REMOTE="${DECODIUMOS_APT_REMOTE:-iu8lmc@community.ft2.it:ft2community/public/downloads/decodiumos/apt/}"
SSH_KEY="${DECODIUMOS_APT_SSH_KEY:-$HOME/.ssh/ft2deploy_ed25519}"
ARCHES=(amd64 arm64)

[ "$#" -gt 0 ] || { echo "usage: $0 PACKAGE_DIR..." >&2; exit 2; }
command -v apt-ftparchive >/dev/null || { echo "apt-ftparchive missing: sudo apt install apt-utils" >&2; exit 1; }

mkdir -p "$LOCAL/pool/main"
for dir in "$@"; do
    for deb in "$dir"/*.deb; do
        pkg=$(dpkg-deb -f "$deb" Package)
        dest="$LOCAL/pool/main/${pkg:0:1}/$pkg"
        mkdir -p "$dest"
        if [ -e "$dest/$(basename "$deb")" ] && ! cmp -s "$deb" "$dest/$(basename "$deb")"; then
            # Two builds of the same upstream version never produce two
            # identical .deb files (time stamps alone differ), so this also
            # fires when nothing really changed. It still refuses by default:
            # the published version must keep the content people downloaded.
            if [ -n "${DECODIUMOS_APT_KEEP_PUBLISHED:-}" ]; then
                echo "publish: keeping the published $(basename "$deb"); the new build of the same version is ignored" >&2
                continue
            fi
            echo "publish: $(basename "$deb") already published with different content;" \
                 "bump the version, or set DECODIUMOS_APT_KEEP_PUBLISHED=1 if only the build differs" >&2
            exit 1
        fi
        cp -p "$deb" "$dest/"
        echo "pool: $pkg $(dpkg-deb -f "$deb" Version) $(dpkg-deb -f "$deb" Architecture)"
    done
done

cd "$LOCAL"
dists="dists/$SUITE"
for arch in "${ARCHES[@]}"; do
    mkdir -p "$dists/main/binary-$arch"
    apt-ftparchive --arch "$arch" packages pool > "$dists/main/binary-$arch/Packages"
    gzip -9nkf "$dists/main/binary-$arch/Packages"
done
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=DecodiumOS \
    -o APT::FTPArchive::Release::Label=DecodiumOS \
    -o APT::FTPArchive::Release::Suite="$SUITE" \
    -o APT::FTPArchive::Release::Codename="$SUITE" \
    -o APT::FTPArchive::Release::Architectures="${ARCHES[*]}" \
    -o APT::FTPArchive::Release::Components=main \
    -o APT::FTPArchive::Release::Description="DecodiumOS updates" \
    release "$dists" > "$dists/Release.tmp"
mv "$dists/Release.tmp" "$dists/Release"
rm -f "$dists/InRelease" "$dists/Release.gpg"
gpg --batch --yes --local-user "$KEY" --clearsign -o "$dists/InRelease" "$dists/Release"
gpg --batch --yes --local-user "$KEY" --armor --detach-sign -o "$dists/Release.gpg" "$dists/Release"

gpg --export "$KEY" > decodiumos-archive-keyring.gpg
gpg --armor --export "$KEY" > decodiumos-archive-keyring.asc
sed -e "s#@URL@#$URL#g" -e "s#@SUITE@#$SUITE#g" -e "s#@FPR@#$KEY#g" \
    -e "/@KEY_BASE64@/{
r /dev/stdin
d
}" "$HERE/setup.sh.in" < <(base64 -w 76 decodiumos-archive-keyring.gpg) > setup.sh
chmod 0644 setup.sh

echo "Packages in $SUITE:"
for arch in "${ARCHES[@]}"; do
    awk -v a="$arch" '/^Package:/ {p=$2} /^Version:/ {print "  " a ": " p " " $2}' "$dists/main/binary-$arch/Packages"
done

if [ -n "${DECODIUMOS_APT_NO_UPLOAD:-}" ]; then
    echo "publish: local repository ready in $LOCAL (upload skipped)"
    exit 0
fi
ssh_cmd="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes"
# Pool first, indexes last: clients never see an index naming a missing file.
rsync -rlptv --chmod=D755,F644 -e "$ssh_cmd" "$LOCAL/pool" "$REMOTE"
rsync -rlptv --chmod=D755,F644 -e "$ssh_cmd" "$LOCAL/" "$REMOTE"
echo "publish: uploaded to $URL"

#!/bin/bash

set -e                  # exit on error
set -o pipefail         # exit on pipeline error
set -u                  # treat unset variable as error

#==========================
# Decodium AI Agent
#==========================
# Installs a local LLM agent (llama.cpp + quantized model) with a CLI wrapper
# and MCP server exposing Decodium/ham radio tools to the agent.

MOD_DIR="$(dirname "$(readlink -f "$0")")"
PACKAGE="decodium-ai"
MAINTAINER="DecodiumOS <noreply@decodiumos.invalid>"

# Model configuration (can be overridden at build time)
# Default: Qwen2.5-3B-Instruct-Q4_K_M — 2.2 GB, good tool-use, multilingual
AI_MODEL_REPO="${AI_MODEL_REPO:-Qwen/Qwen2.5-3B-Instruct-GGUF}"
AI_MODEL_FILE="${AI_MODEL_FILE:-qwen2.5-3b-instruct-q4_k_m.gguf}"
AI_MODEL_URL="https://huggingface.co/${AI_MODEL_REPO}/resolve/main/${AI_MODEL_FILE}"

# llama.cpp version to build
LLAMA_CPP_VERSION="${LLAMA_CPP_VERSION:-b4814}"  # recent stable commit
LLAMA_CPP_REPO="https://github.com/ggml-org/llama.cpp"

# Where to install
INSTALL_DIR="/usr/lib/decodium-ai"
MODEL_DIR="${INSTALL_DIR}/models"
BIN_DIR="/usr/bin"

# Same subset of the image policy as mods/51-hamradio-apps.
FORBIDDEN_RE='^(autoconf|automake|bison|build-essential|dkms|dpkg-dev|fakeroot|flex|gdb|libtool|make|make-guile|snapd|xterm|gnome-terminal|tilix|alacritty|zutty|(gcc|g\+\+)(-[0-9]+)?(-(x86-64|aarch64)-linux-gnu)?|lib(gcc|stdc\+\+)-[0-9]+-dev|libreoffice(-.*)?)$'

BUILD_DEPS=(
    git cmake ninja-build g++ pkg-config
    libcurl4-openssl-dev  # for llama.cpp HTTP download support
)

installed_packages() {
    dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' | \
        awk '$1 == "ii" { sub(/:.*/, "", $2); print $2 }' | LC_ALL=C sort -u
}

cleanup() { [ -n "${DECODIUM_AI_KEEP:-}" ] || rm -rf "$SRC" "$WORK"; }
trap cleanup EXIT

wait_network

print_ok "Installing temporary build dependencies..."
before=$(installed_packages)
apt install -y --no-install-recommends "${BUILD_DEPS[@]}"
judge "Install the temporary build dependencies"

print_ok "Building llama.cpp (${LLAMA_CPP_VERSION})..."
SRC=/tmp/decodium-ai-src
WORK=/tmp/decodium-ai-work
rm -rf "$SRC"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$LLAMA_CPP_VERSION" \
    "$LLAMA_CPP_REPO" "$SRC"
judge "Fetch llama.cpp sources"

cmake -S "$SRC" -B "$SRC/build" -G Ninja -Wno-dev \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_CURL=ON \
    > /tmp/decodium-ai-cmake.log 2>&1 \
    || { tail -40 /tmp/decodium-ai-cmake.log; exit 1; }
ninja -C "$SRC/build" -j"$(nproc)" llama-server llama-cli \
    > /tmp/decodium-ai-ninja.log 2>&1 \
    || { grep -E "error|undefined" /tmp/decodium-ai-ninja.log | head -40; exit 1; }
rm -f /tmp/decodium-ai-cmake.log /tmp/decodium-ai-ninja.log
judge "Build llama.cpp"

# Model download: optional via DECODIUM_AI_NO_MODEL env var.
# A 2.2 GB model in the ISO is heavy; users can download their own at runtime
# with decodium-ai-download-model. Skipping it here keeps the ISO lean.
if [ "${DECODIUM_AI_NO_MODEL:-0}" = "1" ]; then
    print_warn "Skipping model download (DECODIUM_AI_NO_MODEL=1)"
    print_warn "Run 'decodium-ai-download-model' on the installed system to fetch a model"
else
    print_ok "Downloading model (${AI_MODEL_FILE})..."
    mkdir -p "$MODEL_DIR"
    curl --fail --show-error --location --progress-bar \
        -o "${MODEL_DIR}/${AI_MODEL_FILE}" \
        "${AI_MODEL_URL}"
    judge "Download model"
fi

print_ok "Staging ${PACKAGE}..."
umask 022
STAGE="$WORK/pkg"
rm -rf "$WORK"
install -d -m 0755 "$STAGE/DEBIAN" "$STAGE${INSTALL_DIR}" "$STAGE${BIN_DIR}"
cp -a "$MOD_DIR/rootfs/." "$STAGE/"

# Install llama.cpp binaries
install -m 0755 "$SRC/build/bin/llama-server" "$STAGE${INSTALL_DIR}/llama-server"
install -m 0755 "$SRC/build/bin/llama-cli" "$STAGE${INSTALL_DIR}/llama-cli"

# Install model only if it was downloaded
if [ "${DECODIUM_AI_NO_MODEL:-0}" != "1" ]; then
    install -m 0644 "${MODEL_DIR}/${AI_MODEL_FILE}" "$STAGE${INSTALL_DIR}/models/${AI_MODEL_FILE}"
fi

# Install CLI wrapper, MCP server, and model downloader
chmod 0755 "$STAGE${BIN_DIR}/decodium-ai"
chmod 0755 "$STAGE${BIN_DIR}/decodium-ai-download-model"
chmod 0755 "$STAGE${INSTALL_DIR}/mcp-server.py"

# Create model config
cat > "$STAGE${INSTALL_DIR}/model.conf" <<EOF
# Decodium AI Agent model configuration
MODEL_PATH=${INSTALL_DIR}/models/${AI_MODEL_FILE}
MODEL_NAME=${AI_MODEL_FILE}
CONTEXT_SIZE=4096
THREADS=$(nproc)
EOF

# Install systemd service and sysusers.d
install -D -m 0644 "$MOD_DIR/rootfs/etc/systemd/system/decodium-ai-server.service" \
    "$STAGE/etc/systemd/system/decodium-ai-server.service"
install -D -m 0644 "$MOD_DIR/rootfs/usr/lib/sysusers.d/decodium-ai.conf" \
    "$STAGE/usr/lib/sysusers.d/decodium-ai.conf"

# Install desktop entry
install -D -m 0644 "$MOD_DIR/rootfs/usr/share/applications/decodium-ai.desktop" \
    "$STAGE/usr/share/applications/decodium-ai.desktop"

judge "Stage ${PACKAGE}"

print_ok "Self-test: running llama-cli with a simple prompt..."
if [ -f "${STAGE}${INSTALL_DIR}/models/${AI_MODEL_FILE}" ]; then
    "${STAGE}${INSTALL_DIR}/llama-cli" \
        -m "${STAGE}${INSTALL_DIR}/models/${AI_MODEL_FILE}" \
        -p "Hello, respond with just 'OK'" \
        -n 10 --temp 0.1 2>/dev/null | grep -q "OK" || true
    judge "Self-test llama-cli"
else
    print_warn "Skipping self-test: no model downloaded (DECODIUM_AI_NO_MODEL=1)"
fi

print_ok "Resolving runtime libraries..."
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
done < <(ldd "$STAGE${INSTALL_DIR}/llama-cli" | awk '/=> \// { print $3 }')
ldd "$STAGE${INSTALL_DIR}/llama-server" | awk '/=> \// { print $3 }' | while read -r lib; do
    pkg=$(dpkg -S "$lib" 2>/dev/null | head -1 | cut -d: -f1 || true)
    [ -n "$pkg" ] || pkg=$(dpkg -S "$(readlink -f "$lib")" 2>/dev/null | head -1 | cut -d: -f1 || true)
    if [ -z "$pkg" ]; then
        alt=${lib/#\/lib\//\/usr\/lib\/}
        pkg=$(dpkg -S "$alt" 2>/dev/null | head -1 | cut -d: -f1 || true)
    fi
    [ -n "$pkg" ] && runtime_pkgs+=("$pkg")
done
mapfile -t runtime_pkgs < <(printf '%s\n' "${runtime_pkgs[@]}" | sort -u)
if printf '%s\n' "${runtime_pkgs[@]}" | grep -qE -- '-dev$'; then
    print_error "llama.cpp links against a -dev package: $(printf '%s\n' "${runtime_pkgs[@]}" | grep -E -- '-dev$' | xargs)"
    exit 1
fi
echo "Runtime packages: ${runtime_pkgs[*]}"
judge "Resolve runtime libraries"

print_ok "Building the ${PACKAGE} package..."
depends="python3, $(printf '%s, ' "${runtime_pkgs[@]}" | sed 's/, $//')"
pkg_version="${TARGET_BUILD_VERSION}+decodiumos"
installed_size=$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)
cat > "$STAGE/DEBIAN/control" <<EOF
Package: ${PACKAGE}
Version: ${pkg_version}
Architecture: ${TARGET_ARCH}
Maintainer: ${MAINTAINER}
Installed-Size: ${installed_size}
Depends: ${depends}
Section: hamradio
Priority: optional
Homepage: https://github.com/iu8lmc/DecodiumOS
Description: Local LLM AI agent for DecodiumOS (llama.cpp + Qwen2.5)
 decodium-ai provides a local large language model agent that can
 interact with Decodium and ham radio tools (rigctl, decodium-rx,
 wsjtx, gpredict, hamlib) via an MCP (Model Context Protocol) server
 and a simple CLI wrapper. The model runs entirely offline on CPU.
EOF
deb="$WORK/${PACKAGE}_${pkg_version}_${TARGET_ARCH}.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$deb"
judge "Build the ${PACKAGE} package"

print_ok "Installing ${PACKAGE}..."
apt install -y --reinstall "$deb"
install -D -m 0644 "$deb" "/var/cache/decodiumos-debs/$(basename "$deb")"
judge "Install ${PACKAGE}"

# Activate systemd service and sysusers
print_ok "Activating systemd service and sysusers..."
systemctl daemon-reload
systemctl enable decodium-ai-server.service > /dev/null 2>&1 || true
systemctl disable decodium-ai-server.service > /dev/null 2>&1 || true
systemctl stop decodium-ai-server.service > /dev/null 2>&1 || true
# Create the system user for the service
if ! id decodium-ai &>/dev/null; then
    adduser --system --group --no-create-home --disabled-login \
        --home-dir=/usr/lib/decodium-ai --gecos="Decodium AI Agent" \
        decodium-ai
fi
judge "Activate systemd service and sysusers"

print_ok "Purging temporary build dependencies..."
new_pkgs=$(comm -13 <(printf '%s\n' "$before") <(installed_packages) | grep -vx "$PACKAGE" || true)
if [ -n "$new_pkgs" ]; then
    apt-mark auto $new_pkgs > /dev/null
fi
for pass in 1 2 3; do
    removable=$(apt-get -s autoremove | awk '/^Remv / { sub(/:.*/, "", $2); print $2 }' | LC_ALL=C sort -u)
    forbidden=$(comm -13 <(printf '%s\n' "$before") <(installed_packages) | \
        grep -E "$FORBIDDEN_RE|-dev\$|-dev-bin\$|-dev-tools\$|^($(IFS='|'; echo "${BUILD_DEPS[*]}"))\$" || true)
    to_purge=$( { comm -12 <(printf '%s\n' "$removable") <(printf '%s\n' "$new_pkgs" | LC_ALL=C sort -u)
                  printf '%s\n' "$forbidden"; } | sed '/^$/d' | LC_ALL=C sort -u)
    [ -n "$to_purge" ] || break
    echo "Pass $pass: purging $(wc -w <<< "$to_purge") build packages"
    apt-get -y purge $to_purge
done
judge "Purge temporary build dependencies"

print_ok "Checking release package policy..."
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
decodium-ai --help > /dev/null
judge "Check release package policy"
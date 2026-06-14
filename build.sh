#!/usr/bin/env bash
# Bakes Klyx runtime patches into Termux bootstrap zips.
# Source zips must already be built with TERMUX_APP_PACKAGE=com.klyx
# (so binaries' DT_RUNPATH + shebangs already point at com.klyx).
# This script overlays the apt/dpkg/profile.d hook scripts that run
# at package-install time to keep newly apt-installed packages working.
#
# Usage:
#   ./build.sh <aarch64-input.zip> <aarch64-output.zip>
#   ./build.sh <x86_64-input.zip>  <x86_64-output.zip>
#   ./build.sh --both <aarch64-input.zip> <x86_64-input.zip> <outdir>
#
# NOTE: com.klyx (8 chars) != com.termux (10 chars), so we cannot
# do in-place binary hex-patching of rodata. We rely on:
#   1. patchelf for DT_RUNPATH (no length constraint)
#   2. sed for text files and scripts
#   3. LD_PRELOAD=libtermux-exec.so for execve path translation
# This covers 99% of packages. The rare binary that hardcodes
# /data/data/com.termux/ in rodata file-open calls is an edge case.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES="$SCRIPT_DIR/patches"

if [ ! -d "$PATCHES" ]; then
    echo "ERROR: patches/ dir missing: $PATCHES" >&2
    exit 1
fi

patch_bootstrap() {
    local IN_ZIP="$1"
    local OUT_ZIP="$2"

    if [ ! -f "$IN_ZIP" ]; then
        echo "ERROR: input zip not found: $IN_ZIP" >&2
        return 1
    fi

    local WORK
    WORK="$(mktemp -d -t klyx-bootstrap-build.XXXXXX)"
    trap "rm -rf '$WORK'" EXIT

    echo "==> Processing: $IN_ZIP"
    echo "    Workspace:  $WORK"

    local ROOTFS="$WORK/rootfs"
    mkdir -p "$ROOTFS"

    echo "    Unzipping..."
    unzip -q "$IN_ZIP" -d "$ROOTFS"

    echo "    Copying patches..."
    cp -a "$PATCHES"/. "$ROOTFS"/

    # Rewrite com.termux in ALL text files (scripts, dpkg metadata,
    # apt configs, etc). grep -rlI skips binaries automatically.
    echo "    Rewriting com.termux in all text files..."
    grep -rlI "com\.termux" "$ROOTFS" 2>/dev/null | while IFS= read -r f; do
        sed -i 's|com\.termux|com.klyx|g' "$f" 2>/dev/null || true
    done
    echo "    Done rewriting."

    # Ensure hook scripts are executable
    chmod +x "$ROOTFS/etc/apt/klyx-patchelf-hook.sh" 2>/dev/null || true
    chmod +x "$ROOTFS/etc/apt/klyx-pre-install-rewrite.sh" 2>/dev/null || true

    echo "    Re-zipping -> $OUT_ZIP"
    rm -f "$OUT_ZIP"
    ( cd "$ROOTFS" && zip -qry "${OUT_ZIP}.tmp" . )
    mv "${OUT_ZIP}.tmp" "$OUT_ZIP"

    local SIZE_MB
    SIZE_MB=$(( $(stat -f%z "$OUT_ZIP" 2>/dev/null || stat -c%s "$OUT_ZIP") / 1024 / 1024 ))
    echo "    Done: $OUT_ZIP (${SIZE_MB} MB)"

    trap - EXIT
    rm -rf "$WORK"
}

if [ "${1:-}" = "--both" ]; then
    # ./build.sh --both bootstrap-aarch64.zip bootstrap-x86_64.zip outdir
    AARCH64_IN="${2:?missing aarch64 input zip}"
    X86_64_IN="${3:?missing x86_64 input zip}"
    OUTDIR="${4:?missing output directory}"
    mkdir -p "$OUTDIR"
    patch_bootstrap "$AARCH64_IN" "$OUTDIR/bootstrap-aarch64.zip"
    patch_bootstrap "$X86_64_IN"  "$OUTDIR/bootstrap-x86_64.zip"
    echo ""
    echo "Both bootstraps ready in $OUTDIR/"
    ls -lh "$OUTDIR"/bootstrap-*.zip
else
    # ./build.sh input.zip output.zip
    IN_ZIP="${1:?usage: $0 <input.zip> <output.zip>}"
    OUT_ZIP="${2:?usage: $0 <input.zip> <output.zip>}"
    patch_bootstrap "$IN_ZIP" "$OUT_ZIP"
fi

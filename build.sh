#!/usr/bin/env bash
# Prepare Klyx bootstrap archives by applying compatibility patches.
# The input archives must already be built for TERMUX_APP_PACKAGE=com.klyx
# so that contained binaries and scripts already reference the Klyx prefix.
# This build script does not perform binary rodata rewriting on the source
# archive. Instead it copies hook scripts into the bootstrap image and
# relies on package install-time fixes to handle freshly installed packages.
#
# Build process:
#   1. Unpack the source bootstrap archive.
#   2. Rewrite remaining com.termux text references to com.klyx.
#   3. Add the local hooks from patches/ into the extracted image.
#   4. Make the hook scripts executable.
#   5. Repack the modified image into the output archive.
#
# Usage:
#   ./build.sh <aarch64-input.zip> <aarch64-output.zip>
#   ./build.sh <x86_64-input.zip>  <x86_64-output.zip>
#   ./build.sh --both <aarch64-input.zip> <x86_64-input.zip> <outdir>
#
# The bootstrap is designed around the fact that com.klyx and com.termux
# have different lengths, so in-place binary rodata rewriting inside the
# source archive is not safe. The runtime hooks instead use patchelf,
# text rewriting, and execve translation to maintain compatibility.

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

    # Rewrite any remaining Termux path references in extracted text files.
    # grep -rlI finds filenames that contain the literal string and skips
    # binary files. This is safe for scripts, config files, and metadata.
    echo "    Rewriting com.termux in all text files..."
    grep -rlI "com\.termux" "$ROOTFS" 2>/dev/null | while IFS= read -r f; do
        sed -i 's|com\.termux|com.klyx|g' "$f" 2>/dev/null || true
    done
    echo "    Done rewriting."

    echo "    Copying patches..."
    cp -a "$PATCHES"/. "$ROOTFS"/

    # Make sure the bootstrap hooks are executable after they are copied in.
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

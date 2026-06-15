#!/data/data/com.klyx/files/usr/bin/sh
# This hook runs after dpkg unpacks new files during package install.
# It fixes compatibility issues in recently installed ELF binaries by adjusting
# their DT_RUNPATH entries.
#
# The script adjusts ELF DT_RUNPATH entries for newly installed binaries
# when patchelf is available, so dynamic loaders find libraries
# under the Klyx prefix. Path string rewriting is already handled by the
# pre-install hook before .deb files are unpacked.
#
# The hook uses ctime (-cmin) instead of file modification time,
# because dpkg preserves the original mtime from the package but
# updates ctime when it changes ownership or permissions during install.
#
# Compatibility guidance learned from testing:
#   * Do not use patchelf force-rpath. It converts DT_RUNPATH into
#     DT_RPATH and can corrupt some libraries.
#   * Avoid rewriting ELF files whose RUNPATH already points at our prefix.
#   * Avoid patching packaged runtime files that are intentionally shipped
#     with their own loader or dynamic linker.
set -u

PREFIX=/data/data/com.klyx/files/usr
WANT="$PREFIX/lib"

debug() {
    [ -n "${KLYX_DEBUG:-}" ] && printf '%s\n' "klyx-patchelf-hook: $*" >&2
}

# Choose the patchelf binary to use for runpath fixes.
# Prefer the musl-linked patchelf from the main prefix because it
# matches the bootstrap environment, and fall back to the glibc-stack
# version only if needed.
PATCHELF=""
if [ -x "$PREFIX/bin/patchelf" ]; then
    PATCHELF="$PREFIX/bin/patchelf"
elif [ -x "$PREFIX/glibc/bin/patchelf" ]; then
    PATCHELF="$PREFIX/glibc/bin/patchelf"
fi

debug "Selected patchelf: ${PATCHELF:-none}"

maybe_patchelf() {
    [ -n "$PATCHELF" ] || return 0
    file="$1"
    debug "Checking runtime path for $file"
    case "${file##*/}" in
        ld-musl-*.so.1|libc.musl-*.so.1|libc++_shared.so)
            debug "Skipping packaged runtime file that should not be rewritten: $file"
            return 0
            ;;
    esac
    current=$("$PATCHELF" --print-rpath "$file" 2>/dev/null) || {
        debug "Could not read rpath for $file"
        return 0
    }
    debug "Current rpath for $file: $current"
    [ "$current" = "$WANT" ] && {
        debug "Rpath already matches desired prefix for $file"
        return 0
    }
    case "$current" in *com.klyx*)
        debug "Binary already has Klyx path in rpath; skipping $file"
        return 0
        ;;
    esac
    debug "Updating rpath for $file to $WANT"
    if ! "$PATCHELF" --set-rpath "$WANT" "$file" 2>/dev/null; then
        debug "patchelf failed to set rpath on $file"
    fi
}
# the pre-install hook already rewrites embedded paths
# in all extracted .deb files before dpkg installs them. patchelf --set-rpath
# is sufficient for runtime library path adjustments.

# Scan files with recent ctime changes and apply compatibility fixes.
# Only files that have been created or modified in the past 10 minutes are processed.
# This ensures the hook only repairs newly installed package files, not the original
# bootstrap contents. The first loop covers executables and helper binaries; the
# second loop covers shared libraries that may need RUNPATH adjustment.
find "$PREFIX/bin" "$PREFIX/sbin" "$PREFIX/libexec" "$PREFIX/glibc/bin" "$PREFIX/glibc/sbin" "$PREFIX/glibc/libexec" -type f -cmin -10 2>/dev/null | while IFS= read -r f; do maybe_patchelf "$f"; done
find "$PREFIX/lib" "$PREFIX/glibc/lib" -type f -cmin -10 -name '*.so*' 2>/dev/null | while IFS= read -r f; do maybe_patchelf "$f"; done
exit 0

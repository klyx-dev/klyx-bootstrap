#!/data/data/com.klyx/files/usr/bin/sh
# This hook runs after dpkg unpacks new files during package install.
# It fixes compatibility issues in recently installed ELF binaries.
#
# The script performs two main recovery actions:
#   1. It rewrites embedded Termux path strings inside ELF rodata
#      so binaries and scripts installed from packages resolve to
#      the Klyx prefix.
#   2. It adjusts ELF DT_RUNPATH entries for newly installed binaries
#      when patchelf is available, so dynamic loaders find libraries
#      under the Klyx prefix.
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
# version only if needed. If neither exists, the script still performs
# the rodata path rewrite.
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
maybe_hex_patch() {
    [ -x "$PREFIX/bin/perl" ] || return 0
    # Only inspect binaries that actually contain the Termux path.
    # This avoids processing files unnecessarily.
    local has_termux=0
    grep -q -a -- '/data/data/com.termux/' "$1" 2>/dev/null && has_termux=1
    [ $has_termux -eq 0 ] && return 0

    # Perform an in-place rewrite of embedded Termux paths to Klyx paths.
    # The replacement is equal length, so the binary layout remains stable.
    # Original string: /data/data/com.termux/ is 22 bytes
    # Replacement: /data/data/com.klyx/// is also 22 bytes
    # 
    # Why exactly 22 bytes? When patching binary data in-place, we cannot
    # change the length of the string. If we reduced it to /data/data/com.klyx/
    # (20 bytes), we would need to shift all the following binary data, which
    # would corrupt section tables, symbol offsets, and the entire ELF structure.
    # 
    # Why add three slashes at the end? The Linux kernel treats consecutive
    # path separators as equivalent to a single separator. So /data/data/com.klyx///
    # resolves to /data/data/com.klyx/ during path resolution. The extra slashes
    # have no functional effect on how the path is interpreted by the system,
    # but they preserve the exact byte count needed for safe in-place patching.
    "$PREFIX/bin/perl" -e '
                my $path = $ARGV[0];
                open my $fh, "+<:raw", $path or exit 0;
                my $data = do { local $/; <$fh> };
                my $tcount = 0;
                # Pass 1: com.termux/ -> com.klyx/// (22 bytes <-> 22 bytes,
                # in-place; the equal-length property of the com.klyx
                # rename).
                while ($data =~ m{/data/data/com\.termux/}g) {
                    my $offset = $-[0];
                    seek $fh, $offset, 0;
                    print $fh "/data/data/com.klyx///";
                    $tcount++;
                }
                close $fh;
                print STDERR "klyx-rodata-hex: $tcount com.termux in $path\n" if ($tcount > 0 && $ENV{KLYX_DEBUG});
            ' "$1" 2>&1
}

# Scan files with recent ctime changes and apply compatibility fixes.
# Only files that have been created or modified in the past 10 minutes are processed.
# This ensures the hook only repairs newly installed package files, not the original
# bootstrap contents. The first loop covers executables and helper binaries; the
# second loop covers shared libraries that may need RUNPATH adjustment.
find "$PREFIX/bin" "$PREFIX/sbin" "$PREFIX/libexec" "$PREFIX/glibc/bin" "$PREFIX/glibc/sbin" "$PREFIX/glibc/libexec" -type f -cmin -10 2>/dev/null | while IFS= read -r f; do maybe_hex_patch "$f"; maybe_patchelf "$f"; done
find "$PREFIX/lib" "$PREFIX/glibc/lib" -type f -cmin -10 -name '*.so*' 2>/dev/null | while IFS= read -r f; do maybe_hex_patch "$f"; maybe_patchelf "$f"; done
exit 0

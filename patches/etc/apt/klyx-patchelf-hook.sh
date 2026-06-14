#!/data/data/com.klyx/files/usr/bin/sh
# Runs automatically after every `dpkg --unpack` on freshly-installed binaries.
#
# WHAT THIS DOES:
# Termux's upstream CI bakes `/data/data/com.termux/files/usr/...` into every
# compiled ELF binary. To make these binaries run inside the Klyx app sandbox,
# we must perform two types of binary surgery:
#
#   1. RUNPATH Patching (patchelf):
#      Updates the DT_RUNPATH header in shared libraries so the dynamic linker
#      knows where to find dependencies (changes com.termux to com.klyx).
#
#   2. RoData Hex-Patching (perl):
#      In-place rewrites of hardcoded string constants in the binary's
#      read-only data section. This fixes internal `open()` and `execve()`
#      calls that hardcode the Termux path.
#
# CRITICAL INVARIANTS:
# - Hex-patching MUST maintain exact byte lengths.
#   `/data/data/com.termux/` (22 bytes) is replaced with
#   `/data/data/com.klyx///` (22 bytes). The trailing slashes are evaluated
#   by the POSIX filesystem API as a single slash, safely padding the string.
# - We use `-cmin -10` (status change time) on `find` because `dpkg` preserves
#   mtimes (build time) but bumps ctime when it chmods the file during extraction.

set -u

PREFIX="/data/data/com.klyx/files/usr"
WANT="$PREFIX/lib"

# Locate patchelf. We prefer the musl-linked one in $PREFIX/bin,
# but fallback to the glibc-linked one if this is a glibc-stack environment.
PATCHELF=""
if [ -x "$PREFIX/bin/patchelf" ]; then
    PATCHELF="$PREFIX/bin/patchelf"
elif [ -x "$PREFIX/glibc/bin/patchelf" ]; then
    PATCHELF="$PREFIX/glibc/bin/patchelf"
fi

maybe_patchelf() {
    [ -n "$PATCHELF" ] || return 0

    # Skip files we ship pristine — patchelf grows them by tens
    # of KB to add RPATH sections, which (a) is meaningless for
    # ld-musl-*.so.1 (the dynamic linker doesn't read its
    # own RPATH) and (b) shifts section table offsets in
    # libc++_shared.so in ways that break apt's libstdc++ chain
    # on the next dpkg invocation. The dpkg.cfg.d/klyx-protect-
    # libs path-exclude prevents the libc++ package from
    # overwriting libc++_shared.so; this skip-list is
    # defense-in-depth against patchelf rewriting it after a
    # cmin-recent ctime bump.
    # NOTE: The wildcard (*) handles aarch64, x86_64, arm, and i686 automatically.
    case "${1##*/}" in
        ld-musl-*.so.1 | libc.musl-*.so.1 | libc++_shared.so) return 0 ;;
    esac

    # Check the current RUNPATH of the binary
    current=$("$PATCHELF" --print-rpath "$1" 2>/dev/null) || return 0

    # Skip if it's already exactly what we want
    [ "$current" = "$WANT" ] && return 0

    # If hex-patch already fixed the RUNPATH (com.klyx present),
    # leave it alone — for glibc-stack libs the correct RUNPATH
    # is $PREFIX/glibc/lib, NOT $PREFIX/lib, and patchelf would
    # overwrite the hex-patch's correct value with the musl-stack
    # path. Hex-patch handled this binary; trust it.
    case "$current" in *com.klyx*) return 0 ;; esac

    "$PATCHELF" --set-rpath "$WANT" "$1" 2>/dev/null || true
}

maybe_hex_patch() {
    # We require perl for safe binary stream manipulation
    [ -x "$PREFIX/bin/perl" ] || return 0

    # Rewrite paths only present in binaries that actually have
    # something to rewrite. grep -q -a treats binary input as text
    # and short-circuits per pattern.
    grep -q -a -- '/data/data/com.termux/' "$1" 2>/dev/null || return 0

    "$PREFIX/bin/perl" -e '
        my $path = $ARGV[0];
        open my $fh, "+<:raw", $path or exit 0;

        # Read the entire ELF into memory
        my $data = do { local $/; <$fh> };
        my $tcount = 0;

        # com.termux/ -> com.klyx/// (22 bytes <-> 22 bytes,
        # in-place; the equal-length property of the com.klyx
        # rename using POSIX slash padding).
        while ($data =~ m{/data/data/com\.termux/}g) {
            my $offset = $-[0];
            seek $fh, $offset, 0;
            print $fh "/data/data/com.klyx///";
            $tcount++;
        }

        close $fh;

        if ($tcount > 0) {
            print STDERR "klyx-rodata-hex: patched $tcount termux paths in $path\n";
        }
    ' "$1" 2>&1
}

# Look in all binary directories for files changed in the last 10 minutes (cmin -10).
find "$PREFIX/bin" "$PREFIX/sbin" "$PREFIX/libexec" \
     "$PREFIX/glibc/bin" "$PREFIX/glibc/sbin" "$PREFIX/glibc/libexec" \
     -type f -cmin -10 2>/dev/null | while IFS= read -r f; do
    maybe_hex_patch "$f"
    maybe_patchelf "$f"
done

# Look in all lib directories for .so files changed in the last 10 minutes.
find "$PREFIX/lib" "$PREFIX/glibc/lib" \
     -type f -name '*.so*' -cmin -10 2>/dev/null | while IFS= read -r f; do
    maybe_hex_patch "$f"
    maybe_patchelf "$f"
done

exit 0

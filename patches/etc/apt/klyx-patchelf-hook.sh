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

# Choose the patchelf binary to use.
PATCHELF=""
if [ -x "$PREFIX/bin/patchelf" ]; then
    PATCHELF="$PREFIX/bin/patchelf"
elif [ -x "$PREFIX/glibc/bin/patchelf" ]; then
    PATCHELF="$PREFIX/glibc/bin/patchelf"
fi

[ -n "$PATCHELF" ] || exit 0

NPROC=$(nproc 2>/dev/null || echo 2)

debug() {
    [ -n "${KLYX_DEBUG:-}" ] && printf '%s\n' "klyx-patchelf-hook: $*" >&2
}

debug "Selected patchelf: $PATCHELF"

# The done list tracks every ELF file that has already been patched,
# along with its size at the time. Files shipped in the bootstrap are
# pre-populated in this list during build (so the runtime hook skips them
# entirely). When a package upgrade changes a file's size, its entry no
# longer matches and it gets re-processed.
DONE="$PREFIX/var/lib/klyx/.patchelf-done"
mkdir -p "$(dirname "$DONE")" 2>/dev/null
touch "$DONE"

# Collect recently-installed ELF files into a temp list.
TMPDIR="${TMPDIR:-$PREFIX/tmp}"
flist=$(mktemp "$TMPDIR/klyx-elf.XXXXXX") || exit 0
trap 'rm -f "$flist"' EXIT

find "$PREFIX/bin" "$PREFIX/sbin" "$PREFIX/libexec" \
     "$PREFIX/glibc/bin" "$PREFIX/glibc/sbin" "$PREFIX/glibc/libexec" \
     "$PREFIX/lib" "$PREFIX/glibc/lib" \
     -type f -cmin -10 -printf '%p %s\n' 2>/dev/null >> "$flist"

[ -s "$flist" ] || exit 0

# Filter out files already in the done list with matching size.
# This skips bootstrap ELF files (pre-patched during build) and
# previously-processed files. Upgrades are caught because the
# file size changes. Uses awk for efficient single-pass matching.
flist2=$(mktemp "$TMPDIR/klyx-elf2.XXXXXX") || exit 0
trap 'rm -f "$flist2" "$flist"' EXIT

awk 'NR==FNR { done[$1]=$2; next } { if (done[$1] != $2) print }' \
    "$DONE" "$flist" > "$flist2" 2>/dev/null

[ -s "$flist2" ] || exit 0

TOTAL=$(wc -l < "$flist2")
echo " [klyx] fixing ELF runpaths for $TOTAL files..." >&2

# Process files in parallel with xargs.
# Each sh invocation receives a batch of file paths and processes them.
cut -d' ' -f1 < "$flist2" | xargs -P "$NPROC" "$PREFIX/bin/sh" -c '
PATCHELF="$1"; WANT="$2"; shift 2
for f; do
    case "${f##*/}" in
        ld-musl-*.so.1|libc.musl-*.so.1|libc++_shared.so) continue ;;
    esac
    rp=$("$PATCHELF" --print-rpath "$f" 2>/dev/null) || continue
    [ "$rp" = "$WANT" ] && continue
    case "$rp" in *com.klyx*) continue ;; esac
    "$PATCHELF" --set-rpath "$WANT" "$f" 2>/dev/null
done
' -- "$PATCHELF" "$WANT"

# Append newly processed files to the done list (with current sizes).
cat "$flist2" >> "$DONE" 2>/dev/null

echo " [klyx] done fixing ELF runpaths" >&2

exit 0

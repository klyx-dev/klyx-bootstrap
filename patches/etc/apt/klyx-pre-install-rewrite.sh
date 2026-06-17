#!/data/data/com.klyx/files/usr/bin/sh
# This hook is called by apt as DPkg::Pre-Install-Pkgs before dpkg
# unpacks each incoming package. It receives package filenames on stdin.
#
# For each .deb package, the script extracts the archive, rewrites any
# references to /data/data/com.termux/ to /data/data/com.klyx/ in text files,
# ensures maintainer scripts are executable, and then repacks the .deb.
# This avoids package install failures caused by Termux-specific paths
# and incorrect maintainer script permissions.
set -u

PREFIX=/data/data/com.klyx/files/usr
TMPDIR="${TMPDIR:-$PREFIX/tmp}"
export PATH="$PREFIX/bin:$PATH"
NPROC=$(nproc 2>/dev/null || echo 2)

NOTICE="$PREFIX/var/lib/klyx/.first-install-notice"
if [ ! -e "$NOTICE" ]; then
    mkdir -p "${NOTICE%/*}"
    echo >&2
    echo >&2 "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo >&2 " Klyx package compatibility setup"
    echo >&2
    echo >&2 " The first package installation may take"
    echo >&2 " longer than usual while compatibility"
    echo >&2 " hooks process installed packages."
    echo >&2
    echo >&2 " Future package installs should be much"
    echo >&2 " faster."
    echo >&2 "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo >&2
    touch "$NOTICE"
fi

[ -x "$PREFIX/bin/dpkg-deb" ] || exit 0

# collect valid .deb filenames from stdin.
WRK=$(mktemp -d "$TMPDIR/klyx-preinst.XXXXXX") || exit 0
trap 'rm -rf "$WRK"' EXIT

while IFS= read -r line; do
    case "$line" in *.deb) ;; *) continue ;; esac
    [ -f "$line" ] || continue
    echo "$line" >> "$WRK/debs.txt"
done

[ -s "$WRK/debs.txt" ] || exit 0

TOTAL=$(wc -l < "$WRK/debs.txt")
mkdir -p "$WRK/done"

# a self-contained helper to process one .deb in parallel.
cat > "$WRK/helper.sh" << HELPER
#!/data/data/com.klyx/files/usr/bin/sh
set -u
WRK="\$1"
deb="\$2"
PREFIX=/data/data/com.klyx/files/usr
export PATH="\$PREFIX/bin:\$PATH"

deb_bn=\$(basename "\$deb")
tmp=""
trap 'rm -rf "\$tmp"; touch "\$WRK/done/\$deb_bn"' EXIT

# Already rewritten?  Skip.
grep -q '/data/data/com\.klyx/' "\$deb" 2>/dev/null && exit 0

needs_repack=false

# streaming check: does the data payload contain Termux paths?
data_needs_rewrite=false
if ar p "\$deb" data.tar.gz 2>/dev/null | gunzip -c 2>/dev/null | grep -q '/data/data/com\.termux/' 2>/dev/null; then
    data_needs_rewrite=true
elif ar p "\$deb" data.tar.xz 2>/dev/null | xz -dc 2>/dev/null | grep -q '/data/data/com\.termux/' 2>/dev/null; then
    data_needs_rewrite=true
fi

# check control files for Termux paths and permissions
ctrl_needs_rewrite=false
ctrl_needs_perm=false
ctrl_has_files=false

tmp=\$(mktemp -d "\$PREFIX/tmp/klyx-pkg.XXXXXX") || exit 0
if "\$PREFIX/bin/dpkg-deb" -e "\$deb" "\$tmp/DEBIAN" 2>/dev/null; then
    ctrl_has_files=true
    ctrl_matches=\$(grep -rlI '/data/data/com\.termux/' "\$tmp/DEBIAN" 2>/dev/null)
    if [ -n "\$ctrl_matches" ]; then
        ctrl_needs_rewrite=true
    fi
    for s in preinst postinst prerm postrm; do
        if [ -f "\$tmp/DEBIAN/\$s" ] && [ ! -x "\$tmp/DEBIAN/\$s" ]; then
            ctrl_needs_perm=true
        fi
    done
fi

# decide: repack needed?
if [ "\$data_needs_rewrite" = true ] || [ "\$ctrl_needs_rewrite" = true ] || [ "\$ctrl_needs_perm" = true ]; then
    needs_repack=true
fi

# remove the control-only extraction (we'll re-extract fully below if needed)
rm -rf "\$tmp/DEBIAN" 2>/dev/null

if [ "\$needs_repack" = true ]; then
    # Full extract, rewrite, repack using dpkg-deb (well-tested path)
    if "\$PREFIX/bin/dpkg-deb" -R "\$deb" "\$tmp" 2>/dev/null; then
        matches=\$(grep -rlI '/data/data/com\.termux/' "\$tmp" 2>/dev/null)
        if [ -n "\$matches" ]; then
            printf '%s\n' "\$matches" | xargs sed -i 's|/data/data/com\.termux/|/data/data/com.klyx/|g' 2>/dev/null
        fi
        for s in preinst postinst prerm postrm; do
            [ -f "\$tmp/DEBIAN/\$s" ] && chmod 0755 "\$tmp/DEBIAN/\$s" 2>/dev/null
        done
        "\$PREFIX/bin/dpkg-deb" -b "\$tmp" "\$deb" >/dev/null 2>&1 || true
    fi
fi
HELPER
chmod +x "$WRK/helper.sh"

# show progress if there are multiple packages.
if [ "$TOTAL" -gt 1 ]; then
    echo >&2
    echo " [klyx] processing $TOTAL packages..." >&2
    (
        while true; do
            done_count=$(ls "$WRK/done" 2>/dev/null | wc -l)
            printf '\r  [klyx] processed %d/%d packages' "$done_count" "$TOTAL" >&2
            [ "$done_count" -ge "$TOTAL" ] && break
            sleep 2
        done
    ) &
    progress_pid=$!
fi

xargs -P "$NPROC" -L 1 -a "$WRK/debs.txt" "$WRK/helper.sh" "$WRK" 2>/dev/null

if [ -n "${progress_pid:-}" ]; then
    wait "$progress_pid" 2>/dev/null
    echo >&2
fi

exit 0

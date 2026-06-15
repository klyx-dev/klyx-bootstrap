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

NOTICE="$PREFIX/var/lib/klyx/.first-install-notice"

PREFIX=/data/data/com.klyx/files/usr
export PATH="$PREFIX/bin:$PATH"

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

# Only proceed if the package manager helper is available.
[ -x "$PREFIX/bin/dpkg-deb" ] || exit 0
while IFS= read -r line; do
    # Accept only valid .deb filenames from stdin.
    case "$line" in *.deb) ;; *) continue ;; esac
    deb="$line"
    [ -f "$deb" ] || continue

    # Extract the package contents into a temporary directory.
    tmp=$(mktemp -d 2>/dev/null) || continue
    if "$PREFIX/bin/dpkg-deb" -R "$deb" "$tmp" 2>/dev/null; then
        # Find all extracted text files that still contain the Termux path.
        # grep -rlI returns matching filenames and skips binary data.
        matches=$(grep -rlI '/data/data/com\.termux/' "$tmp" 2>/dev/null)
        if [ -n "$matches" ]; then
            # Rewrite Termux-specific paths to Klyx paths in every matching file.
            printf '%s\n' "$matches" | while IFS= read -r f; do
                sed -i 's|/data/data/com\.termux/|/data/data/com.klyx/|g' "$f" 2>/dev/null
            done
            [ -n "${KLYX_DEBUG:-}" ] && echo "Processing $deb" >&2

            # Maintainer scripts are extracted non-executable by dpkg-deb.
            # Make them executable again so the package can be rebuilt.
            for s in preinst postinst prerm postrm; do
                [ -f "$tmp/DEBIAN/$s" ] && chmod 0755 "$tmp/DEBIAN/$s" 2>/dev/null
            done

            # Repack the package after rewriting paths and fixing modes.
            "$PREFIX/bin/dpkg-deb" -b "$tmp" "$deb" >/dev/null 2>&1 || true
        fi
    fi
    rm -rf "$tmp"
done
exit 0

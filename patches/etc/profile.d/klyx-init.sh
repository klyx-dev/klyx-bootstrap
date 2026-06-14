# Self-bootstrap PREFIX/PATH/HOME for any bash -l whose parent
# didn't already set them (adb run-as, SSH subprocess, etc.).
if [ -z "$PREFIX" ]; then
    export PREFIX="/data/data/com.klyx/files/usr"
fi
if [ -z "$TERMUX__PREFIX" ]; then
    export TERMUX__PREFIX="$PREFIX"
fi
if [ -z "$TERMUX__ROOTFS" ]; then
    export TERMUX__ROOTFS="/data/data/com.klyx/files"
fi

# Set HOME if empty or pointing at an Android app-data dir
case "$HOME" in
    "$TERMUX__ROOTFS/home"|"$TERMUX__ROOTFS/home/"*) ;;
    ""|/data/user/0/*|/data/data/*) export HOME="$TERMUX__ROOTFS/home" ;;
esac

if [ -z "$TMPDIR" ]; then
    export TMPDIR="$PREFIX/tmp"
fi
if [ -z "$LANG" ]; then
    export LANG="en_US.UTF-8"
fi

# Add PREFIX/bin to PATH if not already there
case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) export PATH="$PREFIX/bin:$PATH" ;;
esac

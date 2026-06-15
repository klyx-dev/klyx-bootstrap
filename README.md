# klyx-bootstrap

This repository contains the Klyx bootstrap build overlay and runtime compatibility patches.
The build pipeline starts from an existing Termux bootstrap archive that has been built with
`TERMUX_APP_PACKAGE="com.klyx"` and produces a patched bootstrap archive with Klyx-specific
hooks, package manager configuration, and compatibility fixes.

## Overview

`build.sh` is the entrypoint for producing a Klyx bootstrap archive.
It expects a source Termux bootstrap zip that already targets the `com.klyx` prefix.
The script unpacks that archive, rewrites any remaining Termux text references,
copies the additional Klyx patch files into the extracted image, ensures hook scripts
are executable, and then repacks the archive.

## Input requirement

The source bootstrap archive passed to `build.sh` must have been built from termux-packages
with `TERMUX_APP_PACKAGE="com.klyx"`.
That means the core bootstrap files, binary RUNPATHs, and shebangs are already aligned with
`/data/data/com.klyx/files/usr` before this repository's overlay patches are applied.

## Build workflow

`build.sh` performs the following steps for each input archive:

1. Verify the source archive exists.
2. Create a temporary working directory.
3. Unzip the source bootstrap contents into the temporary root filesystem.
4. Rewrite any remaining `com.termux` literals in extracted text files to `com.klyx`.
5. Copy the `patches/` directory contents into the extracted root filesystem.
6. Make the Klyx hook scripts executable.
7. Repack the modified root filesystem into the output archive.

The script also supports a `--both` mode for patching both an aarch64 and x86_64 bootstrap
archive in one invocation.

## Repository layout

- `build.sh`
  - Main bootstrap packaging script.
  - Requires a source archive built for `TERMUX_APP_PACKAGE="com.klyx"`.
  - Outputs patched bootstrap zip(s).

- `patches/`
  - Files that are copied into the bootstrap image as runtime hooks,
    package manager configuration, and environment initialization.

- `termux-patches/`
  - Source patch files for dpkg/dpkg-deb path rewriting when installing
    upstream Termux packages under the Klyx prefix.

## Patches and hook behavior

### `patches/etc/apt/apt.conf.d/97-klyx-pre-install`

This Apt hook runs before `dpkg --unpack` on incoming packages.
It invokes `klyx-pre-install-rewrite.sh` to rewrite Termux path literals inside
`.deb` maintainer scripts before the package is unpacked.

### `patches/etc/apt/apt.conf.d/98-klyx-patchelf`

This Apt hook runs after package invocations.
It invokes `klyx-patchelf-hook.sh` after every `apt` action, allowing newly unpacked
ELF binaries to have their runtime paths corrected immediately.

### `patches/etc/apt/apt.conf.d/99-klyx-rewrite-postinst`

This Apt hook rewrites package manager state files and installed package metadata
under `/data/data/com.klyx/files/usr/var/lib/dpkg/info/`.
It converts any remaining `/data/data/com.termux/` references in the package database
and maintainer script metadata to the Klyx prefix after package operations.

### `patches/etc/apt/klyx-pre-install-rewrite.sh`

This script is called before `dpkg --unpack` for each incoming `.deb`.
It:

- extracts the `.deb` contents to a temporary directory using `dpkg-deb -R`
- searches extracted text files for `/data/data/com.termux/`
- rewrites those occurrences to `/data/data/com.klyx/`
- ensures maintainer scripts in `DEBIAN/` are executable again
- repacks the `.deb` using `dpkg-deb -b`

This avoids package install failures caused by bare Termux path literals and
incorrect script permissions.

### `patches/etc/apt/klyx-patchelf-hook.sh`

This script is called after `apt` package operations to repair recently installed
binary files.
It keeps the following compatibility behavior:

- finds files with recent ctime changes in the bootstrap runtime directories
- performs in-place rodata rewrites for binaries that still contain
  `/data/data/com.termux/`
- uses `patchelf` when available to update ELF `DT_RUNPATH` entries to
  `$PREFIX/lib`
- skips protected runtime files such as `ld-musl-*.so.1`, `libc.musl-*.so.1`,
  and `libc++_shared.so`

When `KLYX_DEBUG` is set, this script logs detailed decisions around
patchelf selection, RPATH checks, and update attempts.

### `patches/etc/apt/preferences.d/klyx-pin-dpkg`

This apt pin file forces `dpkg` and `patchelf` to remain installed.
It is important because:

- the bootstrap ships a patched `dpkg` and `dpkg-deb` that understands Klyx path
  rewriting
- `patchelf` is required for runtime `DT_RUNPATH` repair on freshly installed
  ELF binaries

Without these pins, apt could remove or replace `dpkg` or `patchelf` and break
future package installations.

### `patches/etc/dpkg/dpkg.cfg.d/klyx-protect-libs`

This dpkg configuration excludes `/data/data/com.klyx/files/usr/lib/libc++_shared.so`
from extraction by any package.
The bootstrap supplies its own copy of `libc++_shared.so`, and allowing upstream
packages to overwrite it can break apt, `claude`, and `patchelf`.

### `patches/etc/profile.d/klyx-init.sh`

This profile script ensures the Klyx runtime environment variables are set for
login shells that start without the expected environment already configured.
It sets:

- `PREFIX`
- `TERMUX__PREFIX`
- `TERMUX__ROOTFS`
- `HOME`
- `TMPDIR`
- `LANG`

It also ensures `$PREFIX/bin` is available on `PATH`.

### `patches/etc/motd` and `patches/etc/motd.sh`

These files provide the login message shown when a Klyx shell session starts.
They are intended to display Klyx-specific guidance and a friendly welcome.

## Termux dpkg patch

### `termux-patches/dpkg/klyx-path-rewrite.patch`

This patch modifies Termux's `dpkg` and `dpkg-deb` extraction logic to translate
upstream package paths at extract time based on the environment variable
`TERMUX_APP__PACKAGE_NAME`.

It includes two key changes:

- `lib/dpkg/tarfn.c`
  - Rewrites tar entry paths that begin with `data/data/com.termux`
    to `data/data/<env>/...` during package extraction.
  - Accepts leading forms `data/data/...`, `./data/data/...`, and `/data/data/...`.
  - Uses a boundary check so it only rewrites the exact `com.termux` package
    name and does not confuse similarly prefixed package names.

- `src/deb/extract.c`
  - Adds support for `tar --transform` when `dpkg-deb` invokes tar directly.
  - Provides a transform expression that matches the same path forms and
    rewrites them to the configured package prefix.

This patch enables a Klyx environment to install upstream Termux packages
without rebuilding each package for a different app package name.

## Usage

To build a patched bootstrap archive:

```bash
./build.sh <input-bootstrap.zip> <output-bootstrap.zip>
```

To build both architectures in one pass:

```bash
./build.sh --both <aarch64-input.zip> <x86_64-input.zip> <outdir>
```

## Notes

- The repository does not recreate the full Termux bootstrap from scratch.
  It assumes the source bootstrap is already built for `com.klyx`.
- The runtime hooks are designed to make newly installed packages behave correctly
  under the Klyx prefix.
- The dpkg patch is a companion compatibility layer for packages that still
  contain `com.termux` paths inside their data archives.

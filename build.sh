#!/usr/bin/env bash
# Rebuild Ondřej Surý's php7.4 packages (ppa:ondrej/php) with the PHP security team's
# official minimal backport for CVE-2026-109618 / CVE-2026-109619 ("php2shell").
#
# The result is a drop-in replacement: same package names, paths, php7.4-fpm service
# and FPM socket, so Laravel Forge keeps managing PHP 7.4 exactly as before.
#
# Run as root on a SEPARATE amd64 build host (not a production server, not Apple Silicon)
# running the SAME Ubuntu release as the target servers (compare `lsb_release -cs`).
#
# Usage:
#   ./build.sh                       # uses patches/<PATCH_NAME> next to this script,
#                                    # or downloads it from GitHub if not present
#   ./build.sh <path-or-https-url>   # explicit patch location
#
# Output: /build/*.deb
set -euo pipefail

PATCH_NAME="0139-CVE-2026-109618-109619-bailout-state-corruption.patch"
PATCH_SHA256="12e7b88fa3775e6cdeac787f139ff2cbe63954d68e6284f109505a5ec561f8f6"
PATCH_URL="https://raw.githubusercontent.com/barnabas-szekeres/forge-php-74/main/patches/${PATCH_NAME}"
BUILD_DIR="/build"
WORK_DIR="/root/forge-php-74-work"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run this script as root."; exit 1; }
[ "$(dpkg --print-architecture)" = "amd64" ] || echo "WARNING: build host is not amd64 – packages will not match amd64 servers."

# --- Fetch and verify the patch --------------------------------------------
SRC="${1:-}"
if [ -z "$SRC" ]; then
  if [ -f "$SCRIPT_DIR/patches/$PATCH_NAME" ]; then SRC="$SCRIPT_DIR/patches/$PATCH_NAME"; else SRC="$PATCH_URL"; fi
fi
mkdir -p "$WORK_DIR"
case "$SRC" in
  https://*) echo "Downloading patch: $SRC"; curl -fsSL -o "$WORK_DIR/$PATCH_NAME" "$SRC" ;;
  *)         cp "$(readlink -f "$SRC")" "$WORK_DIR/$PATCH_NAME" ;;
esac
PATCH="$WORK_DIR/$PATCH_NAME"
echo "$PATCH_SHA256  $PATCH" | sha256sum -c - || { echo "ERROR: patch SHA256 mismatch, aborting."; exit 1; }

# --- Environment -------------------------------------------------------------
. /etc/os-release
REL="$VERSION_ID"              # e.g. 24.04
CODENAME="$VERSION_CODENAME"   # e.g. noble
export DEBIAN_FRONTEND=noninteractive
export DEBEMAIL="${DEBEMAIL:-support@kuix.hu}" DEBFULLNAME="${DEBFULLNAME:-KUIX}"

# Forge installs PHP from ppa:ondrej/php, so we bump the version following the PPA's own
# scheme. apt then treats our build as an upgrade (not a downgrade), and the future official
# 7.4.33-31 package will still supersede it.
NEWVER="1:7.4.33-30+ubuntu${REL}.1+deb.sury.org+1+kuixcve1"

apt-get update
apt-get install -y software-properties-common devscripts equivs quilt curl
add-apt-repository -y -s ppa:ondrej/php     # -s: also enable deb-src (source packages)
apt-get update

# --- Get the php7.4 source (Debian patches are applied automatically) -------
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
if ! apt-get source php7.4; then
  # Launchpad may be overloaded (HTTP 503); fall back to the identical 7.4.33-30 source on packages.sury.org
  case "$REL" in
    22.04|24.04) dget -u "https://packages.sury.org/php/pool/main/p/php7.4/php7.4_7.4.33-30%2B0~20260703.120%2Bubuntu${REL}~1.gbp1cce3b.dsc" ;;
    *) echo "ERROR: no fallback source configured for Ubuntu $REL."; exit 1 ;;
  esac
fi
cd php7.4-7.4.33

SRCVER="$(dpkg-parsechangelog -S Version)"
case "$SRCVER" in
  1:7.4.33-30*) ;;
  *) echo "ERROR: source version is $SRCVER (expected 7.4.33-30)."
     echo "A newer official package may already contain the fix – check its changelog before patching."
     exit 1 ;;
esac

# --- Apply the fix and set the version ---------------------------------------
cp "$PATCH" debian/patches/
echo "$PATCH_NAME" >> debian/patches/series
QUILT_PATCHES=debian/patches quilt push -a  # applies only the new patch; stops here on failure

dch -v "$NEWVER" --force-bad-version --distribution "$CODENAME" \
  "Backport CVE-2026-109618 / CVE-2026-109619 fix (php-src PHP-7.4-CVE-2026-109618-109619, 712e60f9)"

# --- Build ------------------------------------------------------------------
mk-build-deps -i -r -t 'apt-get -y --no-install-recommends' debian/control
DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us

echo
echo "Built packages:"
ls -1 "$BUILD_DIR"/*.deb

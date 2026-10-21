#!/usr/bin/env bash
# Install Ondřej Surý's official php7.4 7.4.33-31 packages on a Laravel Forge server.
# 7.4.33-31 contains the PHP security team's backport for CVE-2026-109618 / CVE-2026-109619
# ("php2shell").
#
# Forge installs PHP from ppa:ondrej/php, but Launchpad is overloaded (HTTP 503), so the
# packages are taken from Ondřej's own repository, packages.sury.org. They are a drop-in
# replacement: same package names, paths, php7.4-fpm service and FPM socket, so Forge keeps
# managing PHP 7.4 exactly as before.
#
# Run as the `forge` user – isolated site users cannot use `sudo apt`.
# php7.4-fpm is shared by every site on the server, so installing on a server that also
# hosts a staging site affects production too. Use a low-traffic window.
#
# Usage:
#   ./install.sh
set -euo pipefail

MIN_VERSION="1:7.4.33-31"     # first official build with the fix
REPO_LIST="/etc/apt/sources.list.d/sury-php74-temp.list"
REPO_PIN="/etc/apt/preferences.d/sury-php74-temp"
KEYRING="/usr/share/keyrings/deb.sury.org-php.gpg"
ROLLBACK_DIR="$HOME/php74-rollback"

. /etc/os-release
CODENAME="$VERSION_CODENAME"   # e.g. noble

# Replace only packages built from the php7.4 source that are installed now.
# PECL extension packages built from other sources (php7.4-memcache(d), -redis, -imagick, ...)
# stay ABI-compatible and are left untouched.
mapfile -t pkgs < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${source:Package}\n' 'php7.4*' 2>/dev/null \
  | awk 'substr($1,2,1)=="i" && $3=="php7.4" {print $2}')   # "ii", or "hi" when on hold
[ "${#pkgs[@]}" -gt 0 ] || { echo "ERROR: no php7.4 packages are installed."; exit 1; }

curl -fsS -o /dev/null "https://packages.sury.org/php/dists/$CODENAME/Release" \
  || { echo "ERROR: packages.sury.org has no packages for Ubuntu $CODENAME."; exit 1; }

# --- Add packages.sury.org ----------------------------------------------------
# Pin priority 100: apt takes nothing from this repository unless asked for an exact version,
# so the rest of the server keeps following ppa:ondrej/php.
tmp=$(mktemp -d)
curl -fsSL -o "$tmp/debsuryorg-archive-keyring.deb" https://packages.sury.org/debsuryorg-archive-keyring.deb
sudo dpkg -i "$tmp/debsuryorg-archive-keyring.deb"
rm -rf "$tmp"
echo "deb [signed-by=$KEYRING] https://packages.sury.org/php/ $CODENAME main" | sudo tee "$REPO_LIST" >/dev/null
printf 'Package: *\nPin: origin "packages.sury.org"\nPin-Priority: 100\n' | sudo tee "$REPO_PIN" >/dev/null

# Refresh only this repository: Launchpad answers 503 and its retries would only slow us down.
sudo apt-get update -o Dir::Etc::sourcelist="$REPO_LIST" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0

ver=$(apt-cache madison php7.4-common | awk '/packages\.sury\.org/ {print $3; exit}')
[ -n "$ver" ] || { echo "ERROR: php7.4 not found on packages.sury.org."; exit 1; }
dpkg --compare-versions "$ver" ge "$MIN_VERSION" \
  || { echo "ERROR: packages.sury.org offers $ver, which is older than $MIN_VERSION."; exit 1; }

echo "Packages to replace with $ver:"; printf '  %s\n' "${pkgs[@]}"
read -r -p "Proceed? [y/N] " ok; [ "$ok" = "y" ] || exit 1

# Rollback backup of the currently installed packages. They are repacked locally,
# so rollback works even if the PPA is unreachable. An older backup is kept aside.
if compgen -G "$ROLLBACK_DIR/*.deb" >/dev/null; then mv "$ROLLBACK_DIR" "$ROLLBACK_DIR.$(date +%Y%m%d%H%M%S)"; fi
mkdir -p "$ROLLBACK_DIR"
sudo apt-get install -y dpkg-repack
( cd "$ROLLBACK_DIR" && sudo dpkg-repack "${pkgs[@]}" )
echo "Rollback packages saved to $ROLLBACK_DIR"

targets=(); for p in "${pkgs[@]}"; do targets+=("$p=$ver"); done
sudo apt-mark unhold "${pkgs[@]}" >/dev/null   # an earlier build from this repository was put on hold
sudo apt-get install -y "${targets[@]}"
sudo systemctl restart php7.4-fpm   # restart, not reload, so every worker runs the new binary

echo
echo "Done. Run ./verify.sh to check the result."
echo "Also restart long-running PHP CLI processes (queue workers, daemons) so they pick up the new binary."

# Rollback, if needed:
#   sudo apt-get install -y --allow-downgrades ~/php74-rollback/*.deb
#   sudo systemctl restart php7.4-fpm

#!/usr/bin/env bash
# Install the patched php7.4 packages (built by build.sh) on a Laravel Forge server.
#
# Run as the `forge` user – isolated site users cannot use `sudo apt`.
# php7.4-fpm is shared by every site on the server, so installing on a server that also
# hosts a staging site affects production too. Use a low-traffic window.
#
# Usage:
#   ./install.sh [directory-with-debs]   # default: current directory
set -euo pipefail

DEB_DIR="${1:-.}"
ROLLBACK_DIR="$HOME/php74-rollback"
cd "$DEB_DIR"

# Replace only packages that are installed now AND have a patched .deb.
# PECL extension packages built from other sources (php7.4-memcache(d), -redis, -imagick, ...)
# stay ABI-compatible and are left untouched.
installed=$(dpkg-query -W -f='${Package} ${Status}\n' 'php7.4*' 2>/dev/null | awk '/install ok installed/{print $1}')
debs=(); pkgs=()
for p in $installed; do
  f=$(ls ./"${p}"_7.4.33-*kuixcve*_*.deb 2>/dev/null | head -1 || true)
  if [ -n "$f" ]; then debs+=("$f"); pkgs+=("$p"); fi
done
[ "${#pkgs[@]}" -gt 0 ] || { echo "ERROR: no matching patched .deb files found in $(pwd)."; exit 1; }

echo "Packages to replace:"; printf '  %s\n' "${pkgs[@]}"
read -r -p "Proceed? [y/N] " ok; [ "$ok" = "y" ] || exit 1

# Rollback backup of the currently installed packages. They are repacked locally,
# so rollback works even if the PPA is unreachable.
mkdir -p "$ROLLBACK_DIR"
sudo apt-get install -y dpkg-repack
( cd "$ROLLBACK_DIR" && sudo dpkg-repack "${pkgs[@]}" )
echo "Rollback packages saved to $ROLLBACK_DIR"

sudo apt-get install -y "${debs[@]}"
sudo apt-mark hold "${pkgs[@]}"     # keep the PPA / Forge "Update" button from replacing them
sudo systemctl restart php7.4-fpm   # restart, not reload, so every worker runs the new binary

echo
echo "Done. Run ./verify.sh to check the result."
echo "Also restart long-running PHP CLI processes (queue workers, daemons) so they pick up the new binary."

# Rollback, if needed:
#   sudo apt-mark unhold $(ls ~/php74-rollback/*.deb | xargs -n1 basename | cut -d_ -f1)
#   sudo apt-get install -y --allow-downgrades ~/php74-rollback/*.deb
#   sudo systemctl restart php7.4-fpm

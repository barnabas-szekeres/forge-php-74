#!/usr/bin/env bash
# Install Ondřej Surý's fixed PHP packages for CVE-2026-109618 / CVE-2026-109619 ("php2shell")
# on a Laravel Forge server, for every installed PHP version (5.6–8.5).
#
# Forge installs PHP from ppa:ondrej/php, but Launchpad is overloaded (HTTP 503), so the
# packages are taken from Ondřej's own repository, packages.sury.org. They are drop-in
# replacements: same package names, paths, phpX.Y-fpm services and FPM sockets, so Forge keeps
# managing PHP exactly as before.
#
# Run as the `forge` user – isolated site users cannot use `sudo apt`.
# A phpX.Y-fpm service is shared by every site on the server that uses that version, so
# installing on a server that also hosts a staging site affects production too. Use a
# low-traffic window.
#
# Usage:
#   ./install.sh
set -Eeuo pipefail
trap 'rc=$?; echo "ERROR: line $LINENO: \"$BASH_COMMAND\" failed (exit $rc)." >&2' ERR   # never stop silently

# First build of each branch with the fix, from the changelogs on packages.sury.org.
# ppa:ondrej/php uses the same Debian revisions. Keep in sync with verify.sh.
declare -A FIXED=(
  [php5.6]=5.6.40-104  [php7.0]=7.0.33-92    [php7.1]=7.1.33-80    [php7.2]=7.2.34-66
  [php7.3]=7.3.33-35   [php7.4]=1:7.4.33-31  [php8.0]=1:8.0.30-25  [php8.1]=8.1.34-9
  [php8.2]=8.2.35-1    [php8.3]=8.3.36-1     [php8.4]=8.4.27-1     [php8.5]=8.5.12-1
)
REPO_LIST="/etc/apt/sources.list.d/sury-php74-temp.list"
REPO_PIN="/etc/apt/preferences.d/sury-php74-temp"
KEYRING="/usr/share/keyrings/deb.sury.org-php.gpg"
ROLLBACK_DIR="$HOME/php74-rollback"

. /etc/os-release
CODENAME="$VERSION_CODENAME"   # e.g. noble

# Installed packages built from a phpX.Y source, as "source package version".
# PECL extension packages built from other sources (phpX.Y-memcache(d), -redis, -imagick, ...)
# stay ABI-compatible and are left untouched.
installed=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${source:Package} ${Version}\n' 2>/dev/null \
  | awk 'substr($1,2,1)=="i" && $3 ~ /^php[0-9]+\.[0-9]+$/ {print $3, $2, $4}')   # "ii", or "hi" when on hold
[ -n "$installed" ] || { echo "ERROR: no PHP packages are installed."; exit 1; }

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

# --- Decide what to replace, per PHP version ----------------------------------
# Every package of a version is replaced together, because they depend on each other's exact version.
pkgs=(); targets=(); services=(); unfixed=()
echo
echo "PHP versions on this server:"
for src in $(awk '{print $1}' <<<"$installed" | sort -uV); do
  min=${FIXED[$src]:-}
  mapfile -t src_pkgs < <(awk -v s="$src" '$1==s {print $2}' <<<"$installed")
  if [ -z "$min" ]; then echo "  $src: no known fixed version, skipped (check it manually)"; unfixed+=("$src"); continue; fi
  # Fixed already: every package is at least the first fixed build (the earlier +kuixcve1
  # php7.4 build from this repository is replaced by the official one).
  todo=$(awk -v s="$src" '$1==s {print $2, $3}' <<<"$installed" | while read -r pkg ver; do
           dpkg --compare-versions "$ver" ge "$min" && [[ "$ver" != *kuixcve* ]] || echo "$pkg"
         done)
  if [ -z "$todo" ]; then echo "  $src: already fixed (${#src_pkgs[@]} package(s))"; continue; fi
  ver=$(apt-cache madison "$src-common" | awk '/packages\.sury\.org/ && !v {v=$3} END {print v}')   # read all input: no SIGPIPE under pipefail
  if [ -z "$ver" ] || ! dpkg --compare-versions "$ver" ge "$min"; then
    echo "  $src: NOT fixed, packages.sury.org offers ${ver:-nothing}, older than $min – skipped"; unfixed+=("$src"); continue
  fi
  echo "  $src: replace ${#src_pkgs[@]} package(s) with $ver"
  printf '      %s\n' "${src_pkgs[@]}"
  for p in "${src_pkgs[@]}"; do pkgs+=("$p"); targets+=("$p=$ver"); done
  [[ " ${src_pkgs[*]} " == *" $src-fpm "* ]] && services+=("$src-fpm")
done
echo

if [ "${#pkgs[@]}" -eq 0 ]; then
  if [ "${#unfixed[@]}" -gt 0 ]; then echo "ERROR: nothing to install, and these versions are not fixed: ${unfixed[*]}"; exit 1; fi
  echo "All PHP versions already contain the fix. Nothing to do."
  exit 0
fi
read -r -p "Proceed? [y/N] " ok; [ "$ok" = "y" ] || exit 1

# Rollback backup of the currently installed packages. They are repacked locally,
# so rollback works even if the PPA is unreachable. An older backup is kept aside.
if compgen -G "$ROLLBACK_DIR/*.deb" >/dev/null; then mv "$ROLLBACK_DIR" "$ROLLBACK_DIR.$(date +%Y%m%d%H%M%S)"; fi
mkdir -p "$ROLLBACK_DIR"
sudo apt-get install -y dpkg-repack
( cd "$ROLLBACK_DIR" && sudo dpkg-repack "${pkgs[@]}" )
echo "Rollback packages saved to $ROLLBACK_DIR"

sudo apt-mark unhold "${pkgs[@]}" >/dev/null   # an earlier build from this repository was put on hold
sudo apt-get install -y "${targets[@]}"
for s in "${services[@]}"; do
  sudo systemctl restart "$s"   # restart, not reload, so every worker runs the new binary
done
if [[ " ${pkgs[*]} " == *" libapache2-mod-php"* ]] && systemctl is-active --quiet apache2; then
  sudo systemctl restart apache2   # mod_php runs inside Apache
fi

echo
echo "Done. Run ./restart-workers.sh so queue workers and daemons pick up the new binaries,"
echo "then ./verify.sh to check the result."
if [ "${#unfixed[@]}" -gt 0 ]; then echo; echo "WARNING: these PHP versions are still not fixed: ${unfixed[*]}"; exit 1; fi

# Rollback, if needed:
#   sudo apt-get install -y --allow-downgrades ~/php74-rollback/*.deb
#   sudo systemctl restart 'php*-fpm'

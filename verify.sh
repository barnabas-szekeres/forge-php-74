#!/usr/bin/env bash
# Quick post-install checks on the target server. Run as the `forge` user.
set -uo pipefail
FAIL=0
ok()   { echo "[OK]   $*"; }
bad()  { echo "[FAIL] $*"; FAIL=1; }
info() { echo "[INFO] $*"; }

# 1. Every installed PHP version contains the fix: each package built from a phpX.Y source is at
#    least the first build with the CVE-2026-109618 / CVE-2026-109619 fix (ppa:ondrej/php and
#    packages.sury.org use the same Debian revisions), or the +kuixcve1 php7.4 build from an
#    earlier version of this repository
declare -A FIXED=(
  [php5.6]=5.6.40-104  [php7.0]=7.0.33-92    [php7.1]=7.1.33-80    [php7.2]=7.2.34-66
  [php7.3]=7.3.33-35   [php7.4]=1:7.4.33-31  [php8.0]=1:8.0.30-25  [php8.1]=8.1.34-9
  [php8.2]=8.2.35-1    [php8.3]=8.3.36-1     [php8.4]=8.4.27-1     [php8.5]=8.5.12-1
)
installed=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${source:Package} ${Version}\n' 2>/dev/null \
  | awk 'substr($1,2,1)=="i" && $3 ~ /^php[0-9]+\.[0-9]+$/ {print $3, $2, $4}')   # "ii", or "hi" when on hold
[ -n "$installed" ] || bad "no PHP packages are installed"
for src in $(awk '{print $1}' <<<"$installed" | sort -uV); do
  min=${FIXED[$src]:-}
  n=$(awk -v s="$src" '$1==s {n++} END {print n}' <<<"$installed")
  if [ -z "$min" ]; then info "$src: no known fixed version, check it manually"; continue; fi
  old=$(awk -v s="$src" '$1==s {print $2, $3}' <<<"$installed" | while read -r pkg ver; do
          dpkg --compare-versions "$ver" ge "$min" || [[ "$ver" == *kuixcve* ]] || echo "$pkg $ver"
        done)
  if [ -z "$old" ]; then ok "$src contains the fix ($n package(s), fixed in $min)"
  else bad "$src does NOT contain the fix, these packages are older than $min:"; echo "$old" | sed 's/^/         /'; fi
done

# 2. The php7.4 binaries contain symbols that only exist in the patched code
for bin in /usr/sbin/php-fpm7.4 /usr/bin/php7.4; do
  [ -x "$bin" ] || continue
  if grep -q zend_new_array_singleton "$bin" && grep -q zend_mm_safe_error_ex "$bin"; then
    ok "$bin contains the fix"
  else
    bad "$bin does NOT contain the fix"
  fi
done

# 3. No running process still uses a deleted (old) PHP binary
stale=$(sudo grep -lE 'php.*\(deleted\)$' /proc/[0-9]*/maps 2>/dev/null)
if [ -z "$stale" ]; then ok "no process runs an old PHP binary"; else bad "processes still running an old PHP binary (restart them, e.g. with ./restart-workers.sh):"; echo "$stale" | sed 's/^/         /'; fi

# 4. Which PHP versions serve sites
info "PHP-FPM sockets used by nginx sites:"
grep -rhoE 'php[0-9.]+-fpm\.sock' /etc/nginx/sites-enabled 2>/dev/null | sort | uniq -c | sed 's/^/         /'

# 5. Interim mitigation (recommended even after patching)
for dir in /etc/php/*/fpm; do
  [ -d "$dir" ] || continue
  v=$(basename "$(dirname "$dir")")
  if grep -rqE 'session\.upload_progress\.enabled\]?\s*=\s*(0|off|Off)' "$dir" 2>/dev/null; then
    ok "session.upload_progress.enabled is disabled for php$v-fpm"
  else
    info "session.upload_progress.enabled is not disabled for php$v-fpm (recommended)"
  fi
done

exit $FAIL

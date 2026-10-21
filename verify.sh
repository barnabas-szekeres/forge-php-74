#!/usr/bin/env bash
# Quick post-install checks on the target server. Run as the `forge` user.
set -uo pipefail
FAIL=0
ok()   { echo "[OK]   $*"; }
bad()  { echo "[FAIL] $*"; FAIL=1; }
info() { echo "[INFO] $*"; }

# 1. Every installed package built from the php7.4 source is the official 7.4.33-31 or later,
#    or the +kuixcve1 build from an earlier version of this repository
unpatched=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${source:Package} ${Version}\n' 'php7.4*' 2>/dev/null \
  | while read -r st pkg src ver; do
      [[ "$st" == ?i* ]] && [ "$src" = "php7.4" ] || continue   # "ii", or "hi" when on hold
      dpkg --compare-versions "$ver" ge 1:7.4.33-31 || [[ "$ver" == *kuixcve* ]] || echo "$pkg $ver"
    done)
if [ -z "$unpatched" ]; then ok "all php7.4 core packages contain the fix"; else bad "unpatched php7.4 packages:"; echo "$unpatched" | sed 's/^/         /'; fi

# 2. The binaries contain symbols that only exist in the patched code
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

# 4. Which PHP versions serve sites (every one of them must be patched)
info "PHP-FPM sockets used by nginx sites:"
grep -rhoE 'php[0-9.]+-fpm\.sock' /etc/nginx/sites-enabled 2>/dev/null | sort | uniq -c | sed 's/^/         /'
if grep -rqE 'php(5\.[0-9]|7\.[0-3]|8\.[01])-fpm\.sock' /etc/nginx/sites-enabled 2>/dev/null; then
  bad "some sites use a PHP version this repository does not cover (5.x, 7.0–7.3, 8.0, 8.1)"
fi
for v in 8.2 8.3 8.4 8.5; do
  command -v "php-fpm$v" >/dev/null && info "php-fpm$v: $(php-fpm$v -v 2>/dev/null | head -1)  (fixed: 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12)"
done

# 5. Interim mitigation (recommended even after patching)
if grep -rqE 'session\.upload_progress\.enabled\]?\s*=\s*(0|off|Off)' /etc/php/7.4/fpm/ 2>/dev/null; then
  ok "session.upload_progress.enabled is disabled for php7.4-fpm"
else
  info "session.upload_progress.enabled is not disabled for php7.4-fpm (recommended)"
fi

exit $FAIL

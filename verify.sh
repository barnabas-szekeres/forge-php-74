#!/usr/bin/env bash
# Quick post-install checks on the target server. Run as the `forge` user.
#
# Usage:
#   ./verify.sh [days]   # days to scan the logs for exploitation attempts (default: 5)
#
# Exit code: 1 if a check failed, 2 if only warnings were found, 0 otherwise.
set -uo pipefail
DAYS=${1:-5}
[[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "Usage: $0 [days]"; exit 64; }
FAIL=0; WARN=0
ok()   { echo "[OK]   $*"; }
bad()  { echo "[FAIL] $*"; FAIL=1; }
warn() { echo "[WARN] $*"; WARN=1; }
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
if sudo grep -rqE '^\s*fastcgi_param\s+PHP_(ADMIN_)?VALUE' /etc/nginx/ 2>/dev/null; then
  warn "nginx passes PHP_VALUE / PHP_ADMIN_VALUE to PHP-FPM; a value that raises a warning exposes CVE-2026-109619:"
  sudo grep -rnE '^\s*fastcgi_param\s+PHP_(ADMIN_)?VALUE' /etc/nginx/ 2>/dev/null | sed 's/^/         /'
fi

# 6. Signs of exploitation attempts in the last $DAYS days. Heuristic: the logs only keep traces,
#    and finding nothing does not prove that there was no attempt.
echo
info "Signs of exploitation attempts in the last $DAYS day(s) (heuristic):"
since=$(date -d "-$DAYS days" +%Y-%m-%d)
logs() { sudo zcat -f -- "$@" 2>/dev/null || true; }   # current and rotated (.1, .gz) logs
count() { grep -c . <<<"$1"; }
clients() { grep -oE 'client: [0-9a-fA-F.:]+' <<<"$1" | sort | uniq -c | sort -rn | head -5 | awk '{printf "%s%s (%dx)", sep, $3, $1; sep=", "}'; }

# PHP errors raised while FPM parses a request reach nginx as "FastCGI sent in stderr" (one error log per Forge site)
nginx=$(logs /var/log/nginx/*error.log* | awk -v c="${since//-//}" 'substr($0, 1, 10) >= c')
oom=$(grep -E 'Allowed memory size of [0-9]+ bytes exhausted.* in Unknown on line 0' <<<"$nginx")
if [ -n "$oom" ]; then
  warn "$(count "$oom") request(s) ran out of memory while PHP parsed them, before any application code (the CVE-2026-109618 pattern). Clients: $(clients "$oom")"
else
  ok "no request ran out of memory while PHP parsed it"
fi
limits=$(grep -E 'Unknown: (Input variables exceeded|Input variable nesting level exceeded|Multipart body parts limit exceeded|Maximum number of allowable file uploads)|POST Content-Length of [0-9]+ bytes exceeds' <<<"$nginx")
[ -z "$limits" ] || info "$(count "$limits") request(s) hit PHP's input limits (variables, nesting, multipart parts, uploads, POST size). Clients: $(clients "$limits")"
lost=$(grep -E 'upstream prematurely closed connection while reading response header from upstream.*upstream: "fastcgi://' <<<"$nginx")
[ -z "$lost" ] || info "$(count "$lost") request(s) lost their PHP-FPM worker mid-request. Clients: $(clients "$lost")"

fpm=$(logs /var/log/php*-fpm.log* | awk -v c="${since//-/}" '
  BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m); for (i = 1; i <= 12; i++) mon[m[i]] = sprintf("%02d", i) }
  /^\[[0-9][0-9]-[A-Z][a-z][a-z]-[0-9][0-9][0-9][0-9] / { if (substr($0, 9, 4) mon[substr($0, 5, 3)] substr($0, 2, 2) >= c) print }')
startup=$(grep -E 'child [0-9]+ exited with code 70 after' <<<"$fpm")   # FPM_EXIT_SOFTWARE: request startup failed
if [ -n "$startup" ]; then
  warn "$(count "$startup") PHP-FPM worker(s) exited because a request failed during startup (exit code 70), the FPM side of the same pattern"
else
  ok "no PHP-FPM worker exited because of a failed request startup"
fi
crashed=$(grep -E 'child [0-9]+ exited on signal (4|6|7|8|11) ' <<<"$fpm")
if command -v journalctl >/dev/null; then
  crashed+=$'\n'$(sudo journalctl -k -q --no-pager --since "-${DAYS}d" 2>/dev/null | grep -E 'php[^ ]*\[[0-9]+\]: (segfault|general protection)')
fi
crashed=$(grep . <<<"$crashed")
if [ -n "$crashed" ]; then
  warn "$(count "$crashed") PHP process crash(es) (SIGSEGV, SIGABRT, ...); attempts to corrupt memory look like this:"
  head -5 <<<"$crashed" | cut -c1-160 | sed 's/^/         /'
else
  ok "no PHP process crashed"
fi

# Out-of-memory errors and timeouts inside the application can start the FPM variant
for f in $(sudo find /home -mindepth 5 -maxdepth 5 -path '*/storage/logs/*.log' -newermt "$since" 2>/dev/null); do
  n=$(sudo awk -v c="$since" 'substr($0, 2, 10) >= c && /Allowed memory size of|Maximum execution time of/' "$f" | grep -c .)
  [ "$n" -eq 0 ] || info "$n out-of-memory or timeout error(s) in the application: $f"
done

# Signs of a successful attack: shells spawned by PHP-FPM, PHP files in web-reachable folders
procs=$(ps -eo pid=,ppid=,user=,comm=,args=)
spawned=$(awk 'NR == FNR { comm[$1] = $4; next }
  comm[$2] ~ /^php-fpm/ && $4 ~ /^(sh|bash|dash|zsh|nc|ncat|netcat|socat|python[0-9.]*|perl|ruby|telnet|curl|wget)$/' <(echo "$procs") <(echo "$procs"))
if [ -n "$spawned" ]; then
  warn "PHP-FPM workers run shell or network tools right now, check them:"; cut -c1-160 <<<"$spawned" | sed 's/^/         /'
else
  ok "no shell or network tool runs under a PHP-FPM worker"
fi
uploaded=$(sudo find /home -mindepth 4 -maxdepth 8 -path '*/storage/app/public/*' -name '*.php' 2>/dev/null)
if [ -n "$uploaded" ]; then
  warn "PHP files in the public upload folder (storage/app/public), check them:"; head -10 <<<"$uploaded" | sed 's/^/         /'
fi
changed=$(sudo find /home -mindepth 4 -maxdepth 8 -path '*/public/*' ! -path '*/storage/app/public/*' ! -path '*/public/index.php' ! -path '*/vendor/*' ! -path '*/node_modules/*' -name '*.php' -newermt "$since" 2>/dev/null)
[ -z "$changed" ] || { info "PHP files changed in public folders in the last $DAYS day(s), check that they come from a deployment:"; head -10 <<<"$changed" | sed 's/^/         /'; }

[ "$FAIL" -eq 0 ] || exit 1
[ "$WARN" -eq 0 ] || exit 2
exit 0

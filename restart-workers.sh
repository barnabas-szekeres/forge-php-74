#!/usr/bin/env bash
# Restart every queue worker and daemon on a Laravel Forge server, so long-running PHP
# processes pick up the new php7.4 binary after install.sh.
#
# Forge runs queue workers (worker-<id>) and daemons (daemon-<id>) under Supervisor.
# The script lists the running ones first and asks before restarting them. Supervisor stops
# each process with SIGTERM, so Laravel queue workers and Horizon finish their current job
# first; this can take up to the worker's graceful shutdown time.
#
# Run as the `forge` user.
#
# Usage:
#   ./restart-workers.sh
set -Eeuo pipefail
trap 'rc=$?; echo "ERROR: line $LINENO: \"$BASH_COMMAND\" failed (exit $rc)." >&2' ERR   # never stop silently

command -v supervisorctl >/dev/null || { echo "Supervisor is not installed, so there are no queue workers or daemons."; exit 0; }

# `supervisorctl status` exits non-zero when any process is not running, so its status is ignored.
status=$(sudo supervisorctl status 2>&1 || true)
running=$(awk '$2=="RUNNING"' <<<"$status")
if [ -z "$running" ]; then
  echo "No queue workers or daemons are running."
  if [ -n "$status" ]; then echo; echo "Supervisor status:"; sed 's/^/  /' <<<"$status"; fi
  exit 0
fi

echo "Running queue workers and daemons:"
while read -r name _ _ pid _; do
  pid=${pid%,}
  exe=$(sudo readlink "/proc/$pid/exe" 2>/dev/null || echo "?")
  mark=""; [[ "$exe" == *" (deleted)" ]] && mark="   <- old binary"
  printf '  %-36s pid %-8s %s%s\n' "$name" "$pid" "${exe% (deleted)}" "$mark"
  printf '  %-36s %s\n' "" "$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-100 || true)"
done <<<"$running"

# Restart whole program groups (worker-<id>:*), so every process of a worker restarts.
mapfile -t groups < <(awk '{split($1, a, ":"); print a[1]}' <<<"$running" | sort -u)
echo
read -r -p "Restart ${#groups[@]} program group(s): ${groups[*]}? [y/N] " ok; [ "$ok" = "y" ] || exit 1

failed=()
for g in "${groups[@]}"; do
  echo "Restarting $g ..."
  sudo supervisorctl restart "$g:*" || failed+=("$g")
done

echo
echo "Supervisor status:"
sudo supervisorctl status 2>&1 | sed 's/^/  /' || true

# PHP processes outside Supervisor are not restarted here (php-fpm, manually started scripts, ...).
echo
stale=$(sudo grep -lE 'php.*\(deleted\)$' /proc/[0-9]*/maps 2>/dev/null | cut -d/ -f3 || true)
if [ -z "$stale" ]; then
  echo "No process runs an old PHP binary."
else
  echo "Still running an old PHP binary (not restarted by this script):"
  for pid in $stale; do ps -o pid=,user=,args= -p "$pid" 2>/dev/null | cut -c1-120 | sed 's/^/  /' || true; done
fi

if [ "${#failed[@]}" -gt 0 ]; then echo; echo "ERROR: could not restart: ${failed[*]}"; exit 1; fi

# forge-php-74

Fixes **CVE-2026-109618** and **CVE-2026-109619** ("php2shell") for **every PHP version (5.6–8.5)** on **Laravel Forge** servers. The repository started with PHP 7.4, hence its name.

The PHP project released fixed versions for the supported branches only (8.2.35, 8.3.36, 8.4.27, 8.5.12) on 21 October 2026. For the end-of-life branches, the PHP security team published a minimal backport. Ondřej Surý shipped fixed builds of every branch the same day, for example `php7.4` **7.4.33-31**.

Forge installs PHP from `ppa:ondrej/php` on Launchpad, which is currently overloaded and answers with HTTP 503. `install.sh` therefore installs the fixed build of every PHP version on the server from Ondřej's own repository, [packages.sury.org](https://packages.sury.org/php/).

The result is a **drop-in replacement**: same package names, paths, `phpX.Y-fpm` services and FPM sockets. Forge keeps managing PHP exactly as before, and no site configuration changes are needed.

> **Unofficial helper.** The packages are Ondřej Surý's builds; this repository only installs them. It is not affiliated with the PHP project or deb.sury.org. Test it on a non-production machine first.

## Contents

| File | Purpose |
|---|---|
| `install.sh` | Adds packages.sury.org and installs the fixed build of every installed PHP version, with a rollback backup |
| `restart-workers.sh` | Lists the running queue workers and daemons, then restarts them so they pick up the new binary |
| `verify.sh` | Post-install checks |

## About the fix

- **Fixed builds:** on 21 October 2026, Ondřej shipped the fix for every branch: the new upstream releases for 8.2–8.5, and backports for the end-of-life 5.6–8.1. Each branch's changelog mentions CVE-2026-109618. The first fixed build of each branch is:

  | Branch | First fixed build | Branch | First fixed build |
  |---|---|---|---|
  | 5.6 | `5.6.40-104` | 8.0 | `1:8.0.30-25` |
  | 7.0 | `7.0.33-92` | 8.1 | `8.1.34-9` |
  | 7.1 | `7.1.33-80` | 8.2 | `8.2.35-1` |
  | 7.2 | `7.2.34-66` | 8.3 | `8.3.36-1` |
  | 7.3 | `7.3.33-35` | 8.4 | `8.4.27-1` |
  | 7.4 | `1:7.4.33-31` | 8.5 | `8.5.12-1` |

  `ppa:ondrej/php` and packages.sury.org use the same Debian revisions, so the PPA's builds compare the same way.
- **PHP 7.4 upstream fix:** php-src branch [`PHP-7.4-CVE-2026-109618-109619`](https://github.com/php/php-src/tree/PHP-7.4-CVE-2026-109618-109619), commit [`712e60f9`](https://github.com/php/php-src/commit/712e60f9edfd03f0960fc4fc3c2c375f42b90aa2) ("Avoid state corruption via bailout").
- **In the 7.4 package:** `debian/patches/0164-Avoid-state-corruption-via-bailout.patch`, listed in the changelog as `[CVE-2026-109618, CVE-2026-109619]: Avoid state corruption via bailout`.
- **Other fixes in 7.4.33-31:** it also backports about a dozen other security fixes from 8.2.34 (FastCGI ACL, mysqlnd, OpenSSL hostname checks, phar, SOAP, HTTP stream wrapper and more). The package changelog has the full list.
- **Earlier builds from this repository:** a previous version of this repository rebuilt 7.4.33-30 with the same patch (`+kuixcve1` packages). Those servers are already protected. `install.sh` replaces that build with the official package.
- **PECL extensions:** packages built from other sources (`phpX.Y-memcache(d)`, `-redis`, `-imagick`, ...) stay compatible and are left untouched.

## Requirements

- A Forge server with PHP installed from `ppa:ondrej/php`.
- An Ubuntu release that packages.sury.org serves: 22.04 jammy, 24.04 noble or 26.04 resolute.
- An **amd64** server. On 21 October 2026, packages.sury.org had the fixed builds for amd64 only. For arm64, every branch was still one build behind (for example 7.4.33-30, 8.3.35-1). On arm64, `install.sh` skips the versions that have no fixed build there and replaces no package until one appears.
- Outbound HTTPS access to packages.sury.org.

Check the server:

```bash
lsb_release -cs     # jammy = 22.04, noble = 24.04
dpkg -l 'php*-common' | awk '/^ii/{print $2, $3}'
```

## Usage

### 1. Copy the scripts to the server

```bash
# from your machine
ssh forge@<SERVER_IP> 'mkdir -p ~/php74-cve'
scp install.sh restart-workers.sh verify.sh forge@<SERVER_IP>:~/php74-cve/
```

Or download them on the server:

```bash
mkdir -p ~/php74-cve && cd ~/php74-cve
curl -fsSLO https://raw.githubusercontent.com/barnabas-szekeres/forge-php-74/main/install.sh
curl -fsSLO https://raw.githubusercontent.com/barnabas-szekeres/forge-php-74/main/restart-workers.sh
curl -fsSLO https://raw.githubusercontent.com/barnabas-szekeres/forge-php-74/main/verify.sh
```

### 2. Install (on the server, as the `forge` user)

```bash
cd ~/php74-cve
chmod +x install.sh restart-workers.sh verify.sh
./install.sh
```

Use the `forge` user, not an isolated site user: isolated users cannot run `sudo apt`.

The script performs these steps:

1. Finds the installed packages built from a `phpX.Y` source, for every PHP version on the server.
2. Adds packages.sury.org with its keyring (`/etc/apt/sources.list.d/sury-php74-temp.list`), pinned to priority 100 (`/etc/apt/preferences.d/sury-php74-temp`). apt takes nothing from it unless asked for an exact version, so the rest of the server keeps following the PPA.
3. Refreshes only that repository, so Launchpad's 503 errors neither slow it down nor get in the way.
4. Decides for each PHP version:
   - **Already fixed:** every package is at least the first fixed build in the table above. The version is left alone.
   - **To replace:** it is replaced with the packages.sury.org build. The earlier `+kuixcve1` php7.4 build is replaced with the official one as well.
   - **Not fixed:** packages.sury.org offers no fixed build, for example on arm64, or the branch is unknown. The version is skipped with a warning.

   It then lists the plan and asks for confirmation.
5. Backs up the packages it will replace with `dpkg-repack` to `~/php74-rollback`. An older backup there is moved aside to `~/php74-rollback.<timestamp>`.
6. Installs exactly the packages.sury.org version of every package of each version it replaces. All packages of a version are replaced together, because they depend on each other's exact version. Any hold left by an earlier build from this repository is lifted first. The install runs non-interactively and keeps the local configuration files, such as Forge's changes to `php.ini` and the FPM pools. Where a package ships a changed `php.ini`, its new version is saved next to the kept file as `php.ini.ucf-dist`.
7. Restarts the `phpX.Y-fpm` service of each replaced version, and Apache if it is running and a replaced `libapache2-mod-php` package is installed.

If some versions could not be fixed, the script ends with a warning and exit code 1.

Afterwards, restart the queue workers and daemons as well (step 3).

Each `phpX.Y-fpm` service is shared by **every site on the server that uses that version**. If a staging site lives on the same server as production, installing there affects production too, so use a low-traffic window.

The packages are **not put on hold**. The PPA still offers the older builds, so neither apt nor Forge's PHP **Update** button downgrades them. Once the PPA publishes its own fixed builds, apt sees them as newer (their `+ubuntu<release>.1+deb.sury.org+1` suffix sorts above the `+0~<date>` suffix of packages.sury.org), and a normal upgrade switches to them.

### 3. Restart queue workers and daemons

Long-running PHP processes keep running the old binary until they restart.

```bash
./restart-workers.sh
```

The script performs these steps:

1. Lists the queue workers (`worker-<id>`) and daemons (`daemon-<id>`) that Supervisor runs. For each one it shows the PID, the binary (marked `<- old binary` if it has been replaced since the process started) and the command line. If nothing is running, it says so and exits.
2. Asks for confirmation, then restarts each program group (`supervisorctl restart <group>:*`).
3. Lists the PHP processes that still run an old binary but are not managed by Supervisor (for example a manually started script). Restart those yourself.

Supervisor stops each process with SIGTERM, so Laravel queue workers and Horizon finish their current job before restarting. This can take up to the worker's graceful shutdown time set in Forge.

### 4. Verify

```bash
./verify.sh          # scans the last 5 days of logs for exploitation attempts
./verify.sh 14       # or another number of days
```

It checks these things:

- Every installed PHP version contains the fix: each package built from a `phpX.Y` source is at least the first fixed build in the table above. For php7.4 the earlier `+kuixcve1` build also passes.
- `php-fpm7.4` and `php7.4` contain the fix: they export `zend_new_array_singleton` and `zend_mm_safe_error_ex`, which only exist in the patched code.
- No process still runs an old binary.
- Which PHP versions serve sites (for information).
- Whether `session.upload_progress.enabled` is disabled, for every installed PHP-FPM version, and whether nginx passes `PHP_VALUE` / `PHP_ADMIN_VALUE` to PHP-FPM (one of the CVE-2026-109619 paths).
- Signs of exploitation attempts in the last 5 days (see below).

The exit code is 1 if a check failed, 2 if there were only warnings, and 0 otherwise.

#### Signs of exploitation attempts

This part is **heuristic**. It reads the current and rotated logs, so it can only see as far back as the logs reach, and finding nothing does not prove that there was no attempt. It is based on the attack paths in the two GitHub advisories:

| Sign | Where | Level |
|---|---|---|
| A request ran out of memory while PHP parsed it, before any application code ran (`Allowed memory size … in Unknown on line 0`). This is the CVE-2026-109618 pattern: oversized or deeply nested multipart bodies. | nginx error logs (`FastCGI sent in stderr`), with the client IPs | WARN |
| A PHP-FPM worker exited with code 70. FPM ends a worker this way when a request fails during startup. | `/var/log/phpX.Y-fpm.log` | WARN |
| A PHP process crashed (SIGSEGV, SIGABRT, SIGBUS, ...). Attempts to corrupt memory look like this. | FPM logs, kernel log (`journalctl -k`) | WARN |
| A request hit PHP's input limits (variables, nesting, multipart parts, uploads, POST size). | nginx error logs, with the client IPs | INFO |
| A request lost its PHP-FPM worker mid-request. | nginx error logs, with the client IPs | INFO |
| Out-of-memory errors or timeouts inside the application. These can start the FPM variant of the attack. | `storage/logs/*.log` of each site | INFO |
| A shell or network tool runs under a PHP-FPM worker right now. | process list | WARN |
| A PHP file is in the public upload folder (`storage/app/public`). | site folders | WARN |
| A PHP file in a `public` folder changed within the window (apart from `index.php`). | site folders | INFO |

A WARN is a reason to look closer, not proof of an attack. If one comes up, review the listed client IPs and requests and the site's files. If the server ran an unfixed PHP at the time, treat it as possibly compromised.

The version check assumes PHP comes from Ondřej's builds, as on Forge. Ubuntu's own `php8.x` packages fix security issues without raising the upstream version, so the check would fail them.

For the end-of-life branches (5.6–8.1), `php -v` still reports the old upstream version (for example `7.4.33`). Version-based scanners will therefore keep flagging the host; this is expected.

### Rollback

```bash
sudo apt-get install -y --allow-downgrades ~/php74-rollback/*.deb
sudo systemctl restart 'php*-fpm'
./restart-workers.sh
```

Rolling back to the PPA's older builds makes the server vulnerable again.

### Removing the temporary repository

The repository can be removed at any time; the installed packages stay:

```bash
sudo rm /etc/apt/sources.list.d/sury-php74-temp.list /etc/apt/preferences.d/sury-php74-temp
sudo apt-get update
```

Once `ppa:ondrej/php` is reachable again and serves the fixed builds, switch to them:

```bash
sudo apt-get install --only-upgrade 'php*'
sudo systemctl restart 'php*-fpm'
```

## Interim mitigations

The [official advisory](https://www.php.net/archive/2026.php#2026-10-21-5) lists configuration workarounds. They reduce exposure but do not replace the patch:

- `session.upload_progress.enabled = 0` in `php.ini` or the FPM pool, followed by a full FPM restart. The advisory recommends keeping this even after patching if the feature is not used.
- Conservative `post_max_size` and `upload_max_filesize`, a lower `max_input_nesting_level`, and request size limits at the web server or proxy.
- Make sure nginx does not pass `PHP_VALUE` / `PHP_ADMIN_VALUE` FastCGI parameters.
- If you put the sites behind Cloudflare, restrict ports 80 and 443 on the origin to Cloudflare IP ranges, otherwise the WAF can be bypassed.

## What was tested

- The `0164-Avoid-state-corruption-via-bailout.patch` in the 7.4.33-31 source touches the same files and has the same added and removed lines as the patch this repository used before (the upstream fix rebased onto 7.4.33-30).
- A simulated install (`apt-get install -s`) of every binary package of all 12 branches, at the packages.sury.org version, resolved with Ubuntu's own dependencies plus Ondřej's `php-common`.
- `install.sh` in an `ubuntu:24.04` amd64 container. The container simulated a server with the earlier, held `+kuixcve1` php7.4 build, an unfixed php8.1, an already fixed php8.3 (PPA build) and a PECL package, with `php-common` from Ondřej's builds as on a Forge server:
  - It replaced the php7.4 and php8.1 packages with the fixed builds, left php8.3 and the PECL package untouched, and restarted `php7.4-fpm` and `php8.1-fpm`.
  - `verify.sh` confirmed the fix for all three versions and in both php7.4 binaries.
  - A second run found nothing to do. With an unknown php9.0 added, it skipped that version and exited with an error.
- `install.sh` on a php7.4 whose Forge-modified `php.ini` came from an older package template, the case where `ucf` would ask. There were no debconf warnings and no questions. The modified `php.ini` was kept, and the package's new version was saved as `php.ini.ucf-dist`.
- An earlier test of the same backup code: a second run moved the earlier backup aside, and the rollback command restored the backed-up packages.
- On arm64, `install.sh` skipped php7.4 and php8.1, because packages.sury.org had no fixed builds there yet, and replaced nothing.
- `verify.sh` in an `ubuntu:24.04` container with dummy packages for php5.6, 7.4, 8.1, 8.3 and an unknown 9.0, in both PPA and packages.sury.org version styles:
  - It flagged an unfixed `php8.1-common` and an unfixed `libapache2-mod-php7.4`, and passed the fixed branches.
  - It ignored PECL packages and `php-common`, and reported the unknown branch for a manual check.
- The exploitation-signs part of `verify.sh` in an `ubuntu:24.04` container. Traces were planted in nginx, FPM and Laravel logs (current and gzipped rotated logs, inside and outside the window), along with a PHP file in `storage/app/public`, a changed PHP file in `public`, a shell under a process named `php-fpm8.3`, and a `PHP_VALUE` line in the nginx configuration:
  - Every planted sign was reported with the right count and client IPs.
  - Lines outside the window and an ordinary SIGTERM were ignored. A 1-day window dropped the rotated line from 2 days earlier.
  - A clean server passed with exit code 0, the planted traces gave exit code 2, and a bad argument gave exit code 64.
- `restart-workers.sh` in an `ubuntu:24.04` container with Supervisor. The setup had a 2-process queue worker and a daemon running, a stopped worker, and a PHP process outside Supervisor, and the php7.4 binary had been replaced under them:
  - It marked the old binary and restarted the running groups only.
  - It then listed the PHP process outside Supervisor as still running the old binary.
  - With Supervisor stopped, or with nothing running, it said so and exited.
- **Not yet tested:** a real Forge server (with the PPA, nginx and systemd) and runtime tests on your applications. Test both on a non-production machine before installing.

## References

- [PHP security advisory, 21 Oct 2026](https://www.php.net/archive/2026.php#2026-10-21-5)
- [GHSA-w8hw-w9fx-j79w – CVE-2026-109618, RCE via OOM corruption](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w)
- [GHSA-6wmf-4rv5-p3rp – CVE-2026-109619, RCE via stale global state](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp)
- [packages.sury.org – PHP repository](https://packages.sury.org/php/)
- [Laravel Forge – PHP](https://forge.laravel.com/docs/servers/php)

## License

The scripts are provided as-is, without warranty of any kind.

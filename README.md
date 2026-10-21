# forge-php-74

Fixes **CVE-2026-109618** and **CVE-2026-109619** ("php2shell") for **PHP 7.4** on **Laravel Forge** servers.

The PHP project released fixed versions for the supported branches only (8.2.35, 8.3.36, 8.4.27, 8.5.12) on 21 October 2026. PHP 7.4 is end-of-life, but the PHP security team published a minimal backport for it, and Ondřej Surý shipped that backport the same day in the official `php7.4` **7.4.33-31** package.

Forge installs PHP from `ppa:ondrej/php` on Launchpad, which is currently overloaded and answers with HTTP 503. `install.sh` therefore installs 7.4.33-31 from Ondřej's own repository, [packages.sury.org](https://packages.sury.org/php/).

The result is a **drop-in replacement**: same package names, paths, `php7.4-fpm` service and FPM socket. Forge keeps managing PHP 7.4 exactly as before, and no site configuration changes are needed.

> **Unofficial helper.** The packages are Ondřej Surý's builds; this repository only installs them. It is not affiliated with the PHP project or deb.sury.org. Test it on a non-production machine first.

## Contents

| File | Purpose |
|---|---|
| `install.sh` | Adds packages.sury.org and installs php7.4 7.4.33-31 on a Forge server, with a rollback backup |
| `verify.sh` | Post-install checks |

## About the fix

- **Upstream fix:** php-src branch [`PHP-7.4-CVE-2026-109618-109619`](https://github.com/php/php-src/tree/PHP-7.4-CVE-2026-109618-109619), commit [`712e60f9`](https://github.com/php/php-src/commit/712e60f9edfd03f0960fc4fc3c2c375f42b90aa2) ("Avoid state corruption via bailout").
- **In the package:** `debian/patches/0164-Avoid-state-corruption-via-bailout.patch`, listed in the changelog as `[CVE-2026-109618, CVE-2026-109619]: Avoid state corruption via bailout`.
- **Other fixes:** 7.4.33-31 also backports about a dozen other security fixes from 8.2.34 (FastCGI ACL, mysqlnd, OpenSSL hostname checks, phar, SOAP, HTTP stream wrapper and more). The package changelog has the full list.
- **Earlier builds from this repository:** a previous version of this repository rebuilt 7.4.33-30 with the same patch (`+kuixcve1` packages). Those servers are already protected. `install.sh` replaces that build with the official package.
- **PECL extensions:** packages built from other sources (`php7.4-memcache(d)`, `-redis`, `-imagick`, ...) stay compatible and are left untouched.

## Requirements

- A Forge server with `php7.4` installed from `ppa:ondrej/php`.
- An Ubuntu release that packages.sury.org serves: 22.04 jammy, 24.04 noble or 26.04 resolute.
- An **amd64** server. On 21 October 2026, packages.sury.org had 7.4.33-31 for amd64 only, and arm64 was still at 7.4.33-30. On arm64, `install.sh` stops before replacing any PHP package until the fixed build appears there.
- Outbound HTTPS access to packages.sury.org.

Check the server:

```bash
lsb_release -cs     # jammy = 22.04, noble = 24.04
dpkg -l 'php7.4*' | awk '/^ii/{print $2, $3}'
```

## Usage

### 1. Copy the scripts to the server

```bash
# from your machine
ssh forge@<SERVER_IP> 'mkdir -p ~/php74-cve'
scp install.sh verify.sh forge@<SERVER_IP>:~/php74-cve/
```

Or download them on the server:

```bash
mkdir -p ~/php74-cve && cd ~/php74-cve
curl -fsSLO https://raw.githubusercontent.com/barnabas-szekeres/forge-php-74/main/install.sh
curl -fsSLO https://raw.githubusercontent.com/barnabas-szekeres/forge-php-74/main/verify.sh
```

### 2. Install (on the server, as the `forge` user)

```bash
cd ~/php74-cve
chmod +x install.sh verify.sh
./install.sh
```

Use the `forge` user, not an isolated site user: isolated users cannot run `sudo apt`.

The script performs these steps:

1. Finds the installed packages built from the `php7.4` source.
2. Adds packages.sury.org with its keyring (`/etc/apt/sources.list.d/sury-php74-temp.list`), pinned to priority 100 (`/etc/apt/preferences.d/sury-php74-temp`). apt takes nothing from it unless asked for an exact version, so the rest of the server keeps following the PPA.
3. Refreshes only that repository, so Launchpad's 503 errors neither slow it down nor get in the way.
4. Checks that the offered version is 7.4.33-31 or later, lists the packages it will replace and asks for confirmation.
5. Backs up the currently installed packages with `dpkg-repack` to `~/php74-rollback`. An older backup there is moved aside to `~/php74-rollback.<timestamp>`.
6. Installs exactly that version of every package found in step 1, first lifting the hold an earlier build from this repository left behind.
7. Restarts `php7.4-fpm`.

Afterwards, restart long-running PHP CLI processes as well (queue workers, daemons).

`php7.4-fpm` is shared by **every site on the server**. If a staging site lives on the same server as production, installing there affects production too, so use a low-traffic window.

The packages are **not put on hold**. The PPA still offers 7.4.33-30, which is older, so neither apt nor Forge's PHP **Update** button downgrades them. Once the PPA publishes its own 7.4.33-31 build, apt sees it as newer (its `+ubuntu<release>.1+deb.sury.org+1` suffix sorts above the `+0~<date>` suffix of packages.sury.org), and a normal upgrade switches to it.

### 3. Verify

```bash
./verify.sh
```

It checks five things:

- Every php7.4 core package is 7.4.33-31 or later, or the earlier `+kuixcve1` build.
- `php-fpm7.4` and `php7.4` contain the fix: they export `zend_new_array_singleton` and `zend_mm_safe_error_ex`, which only exist in the patched code.
- No process still runs the old binary.
- Which PHP versions serve sites (every one must be patched).
- Whether `session.upload_progress.enabled` is disabled.

`php -v` still reports `7.4.33`. Version-based scanners will therefore keep flagging the host; this is expected.

### Rollback

```bash
sudo apt-get install -y --allow-downgrades ~/php74-rollback/*.deb
sudo systemctl restart php7.4-fpm
```

Rolling back to the PPA's 7.4.33-30 makes the server vulnerable again.

### Removing the temporary repository

The repository can be removed at any time; the installed packages stay:

```bash
sudo rm /etc/apt/sources.list.d/sury-php74-temp.list /etc/apt/preferences.d/sury-php74-temp
sudo apt-get update
```

Once `ppa:ondrej/php` is reachable again and serves 7.4.33-31 or later, switch to its build:

```bash
sudo apt-get install --only-upgrade 'php7.4*'
sudo systemctl restart php7.4-fpm
```

## Interim mitigations

The [official advisory](https://www.php.net/archive/2026.php#2026-10-21-5) lists configuration workarounds. They reduce exposure but do not replace the patch:

- `session.upload_progress.enabled = 0` in `php.ini` or the FPM pool, followed by a full FPM restart. The advisory recommends keeping this even after patching if the feature is not used.
- Conservative `post_max_size` and `upload_max_filesize`, a lower `max_input_nesting_level`, and request size limits at the web server or proxy.
- Make sure nginx does not pass `PHP_VALUE` / `PHP_ADMIN_VALUE` FastCGI parameters.
- If you put the sites behind Cloudflare, restrict ports 80 and 443 on the origin to Cloudflare IP ranges, otherwise the WAF can be bypassed.

## What was tested

TESTED_PLACEHOLDER

## References

- [PHP security advisory, 21 Oct 2026](https://www.php.net/archive/2026.php#2026-10-21-5)
- [GHSA-w8hw-w9fx-j79w – CVE-2026-109618, RCE via OOM corruption](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w)
- [GHSA-6wmf-4rv5-p3rp – CVE-2026-109619, RCE via stale global state](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp)
- [packages.sury.org – PHP repository](https://packages.sury.org/php/)
- [Laravel Forge – PHP](https://forge.laravel.com/docs/servers/php)

## License

The scripts are provided as-is, without warranty of any kind.

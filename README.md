# forge-php-74

Patched **PHP 7.4** packages for **Laravel Forge** servers, fixing **CVE-2026-109618** and **CVE-2026-109619** ("php2shell").

The PHP project released fixed versions for the supported branches only (8.2.35, 8.3.36, 8.4.27, 8.5.12) on 21 October 2026. PHP 7.4 is end-of-life, so there are no official packages for it. The PHP security team did, however, publish a minimal source backport for 7.4. This repository rebuilds Ondřej Surý's `php7.4` packages (`ppa:ondrej/php`, which Forge uses) with that backport.

The result is a **drop-in replacement**: same package names, paths, `php7.4-fpm` service and FPM socket. Forge keeps managing PHP 7.4 exactly as before, and no site configuration changes are needed.

> **Unofficial.** This is not a PHP project or deb.sury.org release. Review the patch, test it on a non-production machine first, and switch to the official package as soon as Ondřej Surý ships a fixed php7.4 build.

## Contents

| File | Purpose |
|---|---|
| `patches/0139-CVE-2026-109618-109619-bailout-state-corruption.patch` | The official 7.4 fix, rebased onto the sury `php7.4` 7.4.33-30 Debian source |
| `build.sh` | Builds the patched `.deb` packages on a separate build host |
| `install.sh` | Installs them on a Forge server, with a rollback backup |
| `verify.sh` | Post-install checks |
| `SHA256SUMS` | Checksum of the patch (also pinned inside `build.sh`) |

## About the patch

- **Upstream fix:** php-src branch [`PHP-7.4-CVE-2026-109618-109619`](https://github.com/php/php-src/tree/PHP-7.4-CVE-2026-109618-109619), commit [`712e60f9`](https://github.com/php/php-src/commit/712e60f9edfd03f0960fc4fc3c2c375f42b90aa2) ("Avoid state corruption via bailout").
- **Why a rebased copy:** the upstream commit does not apply cleanly on top of the sury 7.4.33-30 source.
  - Sury already ships the `max_multipart_body_parts` backport, so that `main/main.c` hunk is omitted.
  - Sury uses `(unsigned char)` casts in `main/rfc1867.c`, and these are kept.
  - All other changes are identical to upstream.
- **ABI:** the header changes are additive only (new functions and a macro fix, no struct layout changes). PECL extension packages built from other sources (`php7.4-memcache(d)`, `-redis`, `-imagick`, ...) stay compatible and do not need rebuilding.
- **SHA256:** `12e7b88fa3775e6cdeac787f139ff2cbe63954d68e6284f109505a5ec561f8f6`

## Requirements

- **Build host:** a separate **amd64** machine running the **same Ubuntu release** as the target servers (22.04 jammy or 24.04 noble), with root access.
  - Do not build on a production server: the build installs many development packages and loads the CPU for 30–60 minutes.
  - Do not build on Apple Silicon: it produces arm64 packages.
  - A temporary VPS or an `ubuntu:24.04` Docker container on an amd64 host works.
- **Target:** a Forge server with `php7.4` installed from `ppa:ondrej/php` (version `7.4.33-30`).

Check the Ubuntu release on the target:

```bash
lsb_release -cs     # jammy = 22.04, noble = 24.04
dpkg -l 'php7.4*' | awk '/^ii/{print $2, $3}'
```

## Usage

### 1. Build (on the build host, as root)

With git:

```bash
git clone https://github.com/barnabas-szekeres/forge-php-74.git
cd forge-php-74
./build.sh
```

Or with curl only:

```bash
curl -fsSLO https://raw.githubusercontent.com/barnabas-szekeres/forge-php-74/main/build.sh
chmod +x build.sh
./build.sh   # downloads the patch from this repository and verifies its SHA256
```

The script performs these steps:

1. Verifies the patch checksum.
2. Downloads the sury `php7.4` source. If Launchpad is overloaded, it falls back to packages.sury.org.
3. Checks that the source is still `7.4.33-30`.
4. Applies the patch.
5. Sets the version to `1:7.4.33-30+ubuntu<release>.1+deb.sury.org+1+kuixcve1`.
6. Builds the packages into `/build/*.deb`.

The version is chosen so that apt treats it as an upgrade over the installed package, while a future official `7.4.33-31` still supersedes it.

### 2. Copy the packages to the server

```bash
# from your machine
mkdir -p php74-debs
scp 'root@<BUILD_HOST>:/build/*.deb' ./php74-debs/
ssh forge@<SERVER_IP> 'mkdir -p ~/php74-cve'
scp ./php74-debs/*.deb install.sh verify.sh forge@<SERVER_IP>:~/php74-cve/
```

Copying all `.deb` files is fine: `install.sh` only replaces packages that are already installed.

### 3. Install (on the server, as the `forge` user)

```bash
cd ~/php74-cve
chmod +x install.sh verify.sh
./install.sh
```

Use the `forge` user, not an isolated site user: isolated users cannot run `sudo apt`.

The script performs these steps:

1. Lists the packages it will replace and asks for confirmation.
2. Backs up the currently installed packages with `dpkg-repack` to `~/php74-rollback`.
3. Installs the patched packages.
4. Puts them on hold, so neither the PPA nor Forge's PHP **Update** button replaces them.
5. Restarts `php7.4-fpm`.

Afterwards, restart long-running PHP CLI processes as well (queue workers, daemons).

`php7.4-fpm` is shared by **every site on the server**. If a staging site lives on the same server as production, installing there affects production too, so use a low-traffic window.

### 4. Verify

```bash
./verify.sh
```

It checks five things:

- Every php7.4 core package is the patched build.
- `php-fpm7.4` and `php7.4` contain the fix: they export `zend_new_array_singleton` and `zend_mm_safe_error_ex`, which only exist in the patched code.
- No process still runs the old binary.
- Which PHP versions serve sites (every one must be patched).
- Whether `session.upload_progress.enabled` is disabled.

`php -v` still reports `7.4.33`. Version-based scanners will therefore keep flagging the host; this is expected.

### Rollback

```bash
sudo apt-mark unhold $(ls ~/php74-rollback/*.deb | xargs -n1 basename | cut -d_ -f1)
sudo apt-get install -y --allow-downgrades ~/php74-rollback/*.deb
sudo systemctl restart php7.4-fpm
```

### When the official package arrives

Once Ondřej Surý publishes a fixed `php7.4` (7.4.33-31 or later), check its changelog for CVE-2026-109618 / CVE-2026-109619, then switch to it:

```bash
sudo apt-mark unhold $(dpkg-query -W -f='${Package} ${source:Package}\n' 'php7.4*' | awk '$2=="php7.4"{print $1}')
sudo apt-get update && sudo apt-get install --only-upgrade 'php7.4*'
sudo systemctl restart php7.4-fpm
```

## Interim mitigations

The [official advisory](https://www.php.net/archive/2026.php#2026-10-21-5) lists configuration workarounds. They reduce exposure but do not replace the patch:

- `session.upload_progress.enabled = 0` in `php.ini` or the FPM pool, followed by a full FPM restart. The advisory recommends keeping this even after patching if the feature is not used.
- Conservative `post_max_size` and `upload_max_filesize`, a lower `max_input_nesting_level`, and request size limits at the web server or proxy.
- Make sure nginx does not pass `PHP_VALUE` / `PHP_ADMIN_VALUE` FastCGI parameters.
- If you put the sites behind Cloudflare, restrict ports 80 and 443 on the origin to Cloudflare IP ranges, otherwise the WAF can be bypassed.

## What was tested

- The patch applies cleanly on the sury `php7.4` 7.4.33-30 (ubuntu24.04) source after all Debian patches.
- A minimal build (CLI + FPM) on Ubuntu 24.04 amd64 compiles, and the two new symbols are present.
- `Zend/tests`, `ext/session/tests` and `ext/standard/tests/array`: 3799 passed, 2 failed (`bug74936`, `bug74514`). Both failures come from Debian's default `session.save_path` (`0011-session_save_path.patch`) and also occur without this fix.
- **Not yet tested:** the full `dpkg-buildpackage` run and runtime tests on your applications. Test both on a non-production machine before installing.

## References

- [PHP security advisory, 21 Oct 2026](https://www.php.net/archive/2026.php#2026-10-21-5)
- [GHSA-w8hw-w9fx-j79w – CVE-2026-109618, RCE via OOM corruption](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w)
- [GHSA-6wmf-4rv5-p3rp – CVE-2026-109619, RCE via stale global state](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp)
- [Laravel Forge – PHP](https://forge.laravel.com/docs/servers/php)

## License

The patch is derived from [php-src](https://github.com/php/php-src) and is covered by the PHP License v3.01. The scripts are provided as-is, without warranty of any kind.

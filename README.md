# dev-stack

A safe, single-command **local development stack for macOS** — nginx + Apache, PHP-FPM (multiple
versions), MySQL, PostgreSQL, Redis and Mailpit — with a native GUI app to start/stop everything and
`*.test` hostnames that just work. No MAMP, no Valet, no GUI environment managers.

```
browser → yourapp.test :80 (nginx)
              └── proxy → 127.0.0.1:8081 (Apache, per-site vhosts, AllowOverride All → real .htaccess)
                              └── php-fpm unix sockets (one per PHP version)

services: mysql@8.4 · postgresql@18 · redis · mailpit · php 8.5 / 8.3 / 7.4 · apache · nginx
```

## Why
- **One public port (80), clean `*.test` URLs**, real Apache `.htaccess`/`mod_rewrite` underneath.
- **Multiple PHP versions** side by side (8.5 / 8.3 / 7.4) — each site picks its own.
- **DNS with no daemon**: `*.test` entries are written to a managed block in `/etc/hosts` and regenerated from
  your nginx vhosts (no dnsmasq, no port 53, nothing to keep alive).
- **A native app** (SwiftUI) to start/stop the whole stack or any single module, with live status.
- **Safe install**: dry-run, backups before every overwrite, idempotent, and a clean uninstall.

## Requirements
- macOS 12+ (Apple Silicon or Intel)
- [Homebrew](https://brew.sh) (the installer offers to install it)
- Xcode Command Line Tools (`xcode-select --install`) — only needed to build the GUI app

## Install
This repository is **private**, so a raw `curl | bash` won't work — clone with auth instead:

```bash
gh repo clone itsmeshafat/dev-stack
cd dev-stack
./install.sh --dry-run     # see exactly what will happen
./install.sh               # do it (asks for your password once, for the scoped helper)
```

Then define your sites and bring the stack up:

```bash
$EDITOR ~/.config/devstack/sites.conf     # host | docroot | php | kind
devstack restart web
devstack doctor
```

Prefer clicking? Open **Dev Stack** (installed to `/Applications`) → **Start All**.

## Configuration
`~/.config/devstack/sites.conf` — one site per line:

```
host | docroot | php | kind | aliases(optional)
casepilot.test | ~/Developer/CasePilot/public | 8.3 | laravel
jd-blog.test   | ~/Developer/jd-blog/public   | 8.5 | php
wptest.test    | ~/Sites/wptest               | 8.5 | wp
myapp.test     | ~/Sites/myapp                | 8.5 | laravel | www.myapp.test
```

`~/.config/devstack/config` (optional) — overrides:

```
NGINX_PORT=80
APACHE_PORT=8081
```

## Usage
```
devstack status            # every module + state
devstack start | stop | restart [module]
devstack sites             # list configured sites
devstack add-site          # interactive
devstack doctor            # verify formulae, services, configs, helper, and every site
```

Modules: `mysql postgres redis mail php85 php83 php74 apache web`.

## Uninstall
```bash
./uninstall.sh            # stops services, removes helper + hosts block, restores backups
```

## Docs
- [`docs/INSTALL.md`](docs/INSTALL.md) — detailed install & troubleshooting
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the pieces fit
- [`docs/SAFETY.md`](docs/SAFETY.md) — exactly what it touches on your machine

## License
MIT — see [LICENSE](LICENSE).

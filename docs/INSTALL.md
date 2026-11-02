# Install

## Requirements
| | |
|---|---|
| macOS | 12+ (Apple Silicon `/opt/homebrew` or Intel `/usr/local`) |
| Homebrew | required — the installer offers to install it if missing |
| Xcode CLT | required only to build the GUI app (`xcode-select --install`) |

## Steps
```bash
git clone https://github.com/itsmeshafat/dev-stack.git
cd dev-stack
./install.sh --dry-run                 # prints every action, changes nothing
./install.sh                           # real install
```

The installer:
1. **Preflight** — checks macOS, CLT, Homebrew, architecture.
2. **Backs up** `/etc/hosts`, nginx/apache config and each `php-fpm.d/www.conf` to
   `~/.local/share/devstack/backups/<timestamp>/`.
3. Installs the Homebrew formulae (`--no-brew` to skip).
4. Points each php-fpm version at its own socket (`/tmp/devstack-php-<ver>.sock`).
5. Generates nginx + Apache vhosts from your `sites.conf`.
6. Writes `nginx.conf` (nginx on `:80`, reverse-proxying to Apache) and `httpd.conf` (Apache on `:8081`).
7. Installs the CLI to `~/.local/bin/devstack` and the scoped privileged helper
   (`/usr/local/sbin/devstack-web` + one `NOPASSWD` sudoers rule) — **one password prompt**.
8. Builds and installs the **Dev Stack** app.

Flags: `--dry-run` · `--yes` · `--no-brew` · `--ssl` · `--helper-only` · `--app-only` · `--uninstall`.

## HTTPS
```bash
devstack ssl enable     # issue *.test cert (mkcert), redirect :80 → :443, update app URLs
devstack ssl status     # cert expiry, CA trust, :443 listener
devstack ssl renew      # re-issue for the current site list
devstack ssl disable    # back to http only
```
Installing with `--ssl` enables it during setup. Laravel `APP_URL` and WordPress `siteurl`/`home` are
rewritten automatically; other app kinds are left untouched.

## After install
```bash
$EDITOR ~/.config/devstack/sites.conf   # add your projects
devstack restart web
devstack doctor                         # expect all-green
```

Installed tooling also includes **Composer** and **wp-cli**. Run Composer with the PHP a site declares:

```bash
devstack composer --site casepilot.test -- install    # explicit site
devstack composer install                             # auto-detected from $PWD
devstack composer --php 7.4 -- --version              # explicit PHP
```

## Adding a project

No fixed web root — register the site and apply:

```bash
devstack add-site     # host, docroot, php, kind
devstack sync         # regenerate vhosts + /etc/hosts, reload nginx/apache
devstack doctor       # verify
```

Or add a line to `~/.config/devstack/sites.conf`:

```ini
myapp.test | ~/Sites/myapp/public | 8.5 | laravel
```

| Project type | Document root |
|---|---|
| Laravel / Symfony | `<project>/public` |
| WordPress | folder containing `wp-config.php` |
| Plain PHP / legacy | folder containing `index.php` |
| Root `.htaccess` forwarding into `public/` | the project root |

Existing projects are pointed the same way — nothing is moved or copied. `kind` only affects the URL rewrite
done by `devstack ssl enable/disable`.

## Updates

```bash
devstack update --check     # newer release available?
devstack update             # download, verify, swap, rebuild the app
devstack update --rollback  # restore the previous version
```

The app shows an **Update available** banner at launch (and **Check for Updates…** in the menu, ⌘U).
An update replaces only the installed package, the app bundle, and — if it changed — the privileged helper
(one admin prompt). It never touches `sites.conf`, config, certificates, `/etc/hosts`, vhosts, databases or
running services. Version is verified before the swap; the last 3 versions are kept for rollback.

## Troubleshooting
| Symptom | Fix |
|---|---|
| `devstack: command not found` | add `~/.local/bin` to `PATH` |
| site returns **502** | Apache isn't running → `devstack start apache` |
| site returns **404** via port 80 but works on `:8081` | nginx has stale vhosts → `devstack restart web` |
| site doesn't resolve | `/etc/hosts` block missing → `devstack restart web` (or re-run `install.sh`) |
| helper button does nothing | run `sudo bash bin/install-helper-root "$USER" "$PWD"` |
| PHP version wrong for a site | check the `php` column in `sites.conf`, then `devstack restart web` |

## Verify
```bash
devstack doctor          # formulae, services, nginx -t, httpd -t, helper, every site
scripts/smoke-test.sh    # ports + HTTP status for all sites
```

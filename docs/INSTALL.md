# Install

## Requirements
| | |
|---|---|
| macOS | 12+ (Apple Silicon `/opt/homebrew` or Intel `/usr/local`) |
| Homebrew | required — the installer offers to install it if missing |
| Xcode CLT | required only to build the GUI app (`xcode-select --install`) |

## Steps
```bash
gh repo clone itsmeshafat/dev-stack    # private repo — gh (or git) auth required
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

Flags: `--dry-run` · `--yes` · `--no-brew` · `--helper-only` · `--app-only` · `--uninstall`.

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

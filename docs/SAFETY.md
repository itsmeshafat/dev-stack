# Safety

dev-stack is designed to be safe to install, inspect and remove on a working machine.

## What it touches
| Path | Change |
|---|---|
| `/etc/hosts` | adds/rewrites a clearly delimited `# devstack-begin … # devstack-end` block **only** |
| `$HOMEBREW_PREFIX/etc/nginx/{nginx.conf,servers/*.conf}` | backed up first |
| `$HOMEBREW_PREFIX/etc/httpd/{httpd.conf,vhosts/*.conf}` | backed up first |
| `$HOMEBREW_PREFIX/etc/php/*/php-fpm.d/www.conf` | only the `listen` line + socket perms; backed up first |
| `~/.config/devstack/` | your config (never committed) |
| `~/.local/share/devstack/` | installed package, log, backups |
| `/usr/local/sbin/devstack-web` | the helper (single file) |
| `/etc/sudoers.d/devstack` | one rule: `NOPASSWD: /usr/local/sbin/devstack-web` |
| `/Applications/Dev Stack.app` (or `~/Desktop`) | the app |
| `~/.local/share/devstack/certs/` | TLS cert + private key (mode 0600), only when HTTPS is enabled |
| `~/.local/share/devstack/pkg-backups/` | previous versions kept for `devstack update --rollback` (last 3) |

**Updates** (`devstack update`) replace only `~/.local/share/devstack/pkg` and the app bundle (and the helper
if it changed). They do **not** touch `~/.config/devstack`, certificates, `/etc/hosts`, vhosts, databases or
running services. The version is verified before an atomic swap; the previous version is retained.

**mkcert CA** — if you enable HTTPS, `mkcert -install` adds a *local development CA* to your login/system
keychain so browsers trust `*.test` certificates. That's standard for local dev. `uninstall.sh` removes the
dev-stack certificates but leaves the CA in place (other tools may use it); remove it yourself with
`mkcert -uninstall` if you want it gone.

It **never** touches files outside these paths.

## Your data
dev-stack **does not copy your databases or project files**. Its backups cover only the configuration it
rewrites (`/etc/hosts`, nginx/Apache configs, php-fpm `www.conf`). Before anything destructive — database
migrations, `uninstall.sh`, `DROP`, `rm` — take your own dump/backup (`mysqldump`, `pg_dump`,
`redis-cli --rdb`) and keep projects in version control. Provided **as is**, no warranty — see the
[README disclaimer](../README.md#disclaimer).

## Guardrails
- **`--dry-run`** prints every action and changes nothing (verify before trusting).
- **Backups** — every file that would be overwritten is copied to
  `~/.local/share/devstack/backups/<timestamp>/` before any change.
- **Idempotent** — re-running reconciles; it does not duplicate or nest.
- **Least privilege** — the *only* privileged surface is one script that can restart nginx and rewrite the
  hosts block. No general `sudo`. The sudoers file is validated with `visudo -cf` and removed on failure.
- **Loopback only** — Apache listens on `127.0.0.1:8081`; only nginx is on `:80`.
- **Config validation** — `nginx -t` and `httpd -t` run after generation.
- **Clean removal** — `uninstall.sh` stops services, deletes the helper + sudo rule, removes the hosts block,
  and restores the most recent backup.

## Notes
- The installer runs `brew install` for the formulae; use `--no-brew` if you manage packages yourself.
- If your Git has `filter.lfs.required=true`, note this repo contains only small text/config files — no LFS objects.
- The helper script is small and readable: [`bin/devstack-web`](../bin/devstack-web). Read it before installing.

## Manual helper install (without the app)
```bash
sudo bash bin/install-helper-root "$USER" "$PWD"
```

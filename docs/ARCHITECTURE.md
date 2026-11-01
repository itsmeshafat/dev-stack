# Architecture

```
                      ┌──────────────── yourapp.test :80 ───────────────┐
   browser ──────────▶│ nginx ($HOMEBREW_PREFIX/etc/nginx)              │
                      │   servers/<host>.conf → proxy_pass 127.0.0.1:8081
                      └───────────────────────┬─────────────────────────┘
                                              ▼
                      ┌────────── Apache 127.0.0.1:8081 ────────────────┐
                      │ httpd/vhosts/<host>.conf                        │
                      │   AllowOverride All  → .htaccess / mod_rewrite   │
                      │   <FilesMatch \.php$> SetHandler proxy:unix:…    │
                      └───────────────────────┬─────────────────────────┘
                                              ▼
              /tmp/devstack-php-85.sock · -83.sock · -74.sock  (php-fpm per version)

   data:    mysql@8.4 :3306   postgresql@18 :5432   redis :6379   mailpit :1025/:8025
   DNS:     managed block in /etc/hosts (127.0.0.1 <host>) generated from nginx server_name
```

## Pieces
| Path | Role |
|---|---|
| `bin/devstack` | user CLI — start/stop/restart/status/sites/add-site/doctor |
| `bin/devstack-web` | privileged helper (root) — restarts nginx + regenerates `/etc/hosts`; **only** these two things |
| `bin/install-helper-root` | installs the helper + the single sudoers rule (run as root) |
| `lib/common.sh` | env detection (brew prefix, arch, user), config, logging, dry-run |
| `lib/modules.sh` | the service table (module → brew formula, socket, port) |
| `lib/sites.sh` | parses `sites.conf`; generates nginx + Apache vhosts |
| `lib/hosts.sh` | managed `/etc/hosts` block |
| `app/` | SwiftUI control app + icon generator + build script |

## Why nginx *and* Apache
`.htaccess`/`mod_rewrite` projects (legacy PHP, WordPress quirks, Laravel) behave correctly under Apache;
nginx is a thin, fast front door that keeps a single public port and clean URLs. Apache is bound to
**127.0.0.1 only**, so nothing is exposed beyond the loopback interface.

## Ports
`80` (nginx) · `8081` (Apache) · `3306` (MySQL) · `5432` (PostgreSQL) · `6379` (Redis) ·
`1025`/`8025` (Mailpit SMTP/UI). All overridable in `~/.config/devstack/config`.

## DNS without a daemon
`devstack-web start` reads every `server_name` from the generated nginx vhosts and writes:

```
# devstack-begin
127.0.0.1 yourapp.test
# devstack-end
```

so resolution needs no dnsmasq and survives reboots. Add a site → restart `web` → it resolves.

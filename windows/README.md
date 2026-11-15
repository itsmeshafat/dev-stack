# dev-stack for Windows

A complete local development stack for Windows 10/11 (x64): **nginx -> Apache -> PHP (php-cgi)**, plus
MySQL, PostgreSQL, Redis and Mailpit, clean `*.test` URLs, trusted HTTPS and a desktop control app. No
containers, no VM, no DNS daemon.

> The macOS implementation lives at the repository root. This folder is the Windows implementation and
> has its own documentation under [`docs/`](docs/). The two share the same command surface and config
> format, so `sites.conf` is portable between them.

## Requirements
| | |
|---|---|
| Windows | 10 or 11, x64 |
| PowerShell | 5.1+ (built in) |
| Package manager | [Scoop](https://scoop.sh) (recommended) or Chocolatey |
| .NET SDK | not required - the app builds with the in-box .NET Framework compiler |

## Quick start
```powershell
# from the repository root
powershell -File windows\install.ps1 -DryRun    # prints every action, changes nothing
powershell -File windows\install.ps1            # install (one UAC prompt for the hosts helper)

# open a new terminal, then
devstack status
devstack start
devstack doctor
```

Add a site with one line (nothing is moved or copied):
```powershell
notepad $env:USERPROFILE\.config\devstack\sites.conf
# host | docroot | php | kind | aliases
myapp.test | C:\Sites\myapp\public | 8.5 | laravel

devstack sync
devstack doctor
```

## How it works
```
browser -> nginx :80/:443 -> proxy_pass 127.0.0.1:8081 -> Apache (AllowOverride All)
        -> <FilesMatch \.php$> -> proxy:fcgi://127.0.0.1:9085|9083|9074 -> php-cgi
data:   mysql :3306 - postgres :5432 - redis :6379 - mailpit :1025/:8025
DNS:    managed block in C:\Windows\System32\drivers\etc\hosts (127.0.0.1 <host>)
TLS:    mkcert wildcard *.test, trusted in the Windows certificate store
```
nginx is the only public entry point. Apache binds to loopback only. PHP runs as php-cgi in FastCGI mode
(Windows has no php-fpm), one listener per version.

## Commands
| Command | What it does |
|---|---|
| `devstack status` | show every module and its state |
| `devstack start \| stop \| restart [module]` | control all modules, or one |
| `devstack sites` | list configured sites |
| `devstack add-site` | add a site interactively |
| `devstack sync` | regenerate vhosts + `/etc/hosts` equivalent, reload |
| `devstack ssl {enable\|disable\|status\|renew}` | trusted HTTPS for all sites |
| `devstack phpmyadmin [status\|install]` | optional phpMyAdmin at `https://phpmyadmin.test` |
| `devstack php [status\|list\|default V]` | show or set the default PHP for the `php` command |
| `devstack migrate [--apply]` | import sites from XAMPP/WAMP/Laragon/Herd |
| `devstack migrate db FILE` | import a `mysqldump` / `pg_dump` into dev-stack |
| `devstack update [--check\|--rollback]` | check for / apply a release safely |
| `devstack composer [--site H \| --php V] ...` | run Composer with the site's PHP |
| `devstack doctor` | verify binaries, services, configs, helper, sites |

## Migrating from XAMPP / WAMP / Laragon / Herd
```powershell
devstack migrate                 # read-only scan of installed tools
devstack migrate --apply         # import the sites it finds (nothing is moved)
devstack sync
```
Databases move separately (stop the other tool's MySQL first):
```powershell
mysqldump -u root --all-databases > backup.sql
devstack migrate db backup.sql
```

## Running in the background
Closing the window keeps the app running in the **notification area** (system tray). Right-click the tray
icon to Open, Start All / Stop All / Restart All, start or stop one module, or Quit. The window's close
button hides to the tray; use the tray's **Quit Dev Stack** (or File > Exit) to exit fully.

## Configuration
- `%USERPROFILE%\.config\devstack\sites.conf` - one site per line, `|` separated.
- `%USERPROFILE%\.config\devstack\config` - optional port overrides (`NGINX_PORT`, `APACHE_PORT`, `SSL_PORT`).
- Data, logs, backups, certs and the installed package live in `%LOCALAPPDATA%\devstack`.

## Docs
| Document | Contents |
|---|---|
| [`docs/INSTALL.md`](docs/INSTALL.md) | install, flags, Scoop/Chocolatey, troubleshooting |
| [`docs/HELP.md`](docs/HELP.md) | the in-app guide (bundled into the app) |
| [`docs/DATABASES.md`](docs/DATABASES.md) | creating databases/users, dumps, restores, troubleshooting |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | how the pieces fit together |
| [`docs/SAFETY.md`](docs/SAFETY.md) | exactly what it touches on your machine |
| [`docs/SECURITY.md`](docs/SECURITY.md) | privileged surface, threat model, reporting |
| [`docs/NOTICE.md`](docs/NOTICE.md) | originality, asset and dependency licensing |

## Disclaimer
dev-stack is a **local development tool**, provided **as is**, without warranty of any kind (MIT License).
It runs services, edits the hosts file and registers one scheduled task. **It does not back up your
databases or project files** - keep your own dumps and use version control.

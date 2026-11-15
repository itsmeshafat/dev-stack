# Install (Windows)

## Requirements
| | |
|---|---|
| Windows | 10 or 11, x64 (Apple Silicon/Intel distinction does not apply) |
| PowerShell | 5.1+ (shipped with Windows) |
| Scoop | recommended - install from <https://scoop.sh> |
| Chocolatey | alternative, if you prefer it (see below) |
| .NET SDK | not required - the app builds with the in-box .NET Framework compiler (`csc.exe`) |

## Steps
```powershell
# from the repository root
powershell -File windows\install.ps1 -DryRun    # prints every action, changes nothing
powershell -File windows\install.ps1            # real install
```

The installer:
1. Checks Windows and architecture.
2. Backs up the hosts file and any existing dev-stack config to `%LOCALAPPDATA%\devstack\backups\<ts>`.
3. Installs the Scoop packages (skip with `-NoScoop`).
4. Writes the base nginx + Apache configs and generates vhosts from `sites.conf`.
5. Copies the CLI to `%LOCALAPPDATA%\devstack\pkg` and writes `devstack.cmd` on your user PATH.
6. Registers the **DevStackHelper** scheduled task (one UAC prompt) - used only to write the hosts file.
7. Builds the desktop app, installs it to `%LOCALAPPDATA%\Programs\DevStack`, and registers it in the
   Start Menu and **Apps & features** (with a standard uninstaller).

Flags: `-DryRun` - `-Yes` - `-NoScoop` - `-Ssl` - `-PhpMyAdmin` - `-HelperOnly` - `-AppOnly` - `-Uninstall`.

> PowerShell uses single-dash switches. `-NoScoop` is an alias for `-NoBrew`, for parity with macOS.

## Scoop packages
> If Scoop's `apache` package fails (its mirror can return 401), the installer automatically fetches
> the current **Apache Lounge** Win64 build plus `mod_fcgid` and installs it where the stack expects it.
> PHP runs through `mod_fcgid`, so a per-site `FcgidWrapper` points at that site's `php-cgi.exe`.

The installer requests:
```powershell
scoop install nginx apache php php83 php74 mysql postgresql redis mailpit mkcert composer wp-cli
```
- `php` is the default (8.5); `php83` and `php74` come from the `versions` bucket. If a package is missing,
  run `scoop bucket add versions` then `scoop install php83 php74`.
- Each PHP version runs `php-cgi.exe` in FastCGI mode on its own port (9085, 9083, 9074).
- `devstack doctor` reports any binary it cannot find, and you can override paths with
  `DEVSTACK_NGINX`, `DEVSTACK_HTTPD`, `DEVSTACK_MYSQLD`, `DEVSTACK_POSTGRES`, `DEVSTACK_REDIS`,
  `DEVSTACK_MAILPIT`, `DEVSTACK_PHP85` / `DEVSTACK_PHP83` / `DEVSTACK_PHP74`, `DEVSTACK_MKCERT`.

### Chocolatey alternative
If you use Chocolatey instead of Scoop, install equivalent packages (`nginx`, `apache-httpd`, `php`,
`mysql`, `postgresql`, `redis`, `mailpit`, `mkcert`, `composer`) and point dev-stack at the binaries with
the `DEVSTACK_*` environment variables above, then run `install.ps1 -NoScoop`.

## HTTPS
```powershell
devstack ssl enable     # issue a *.test cert (mkcert), redirect :80 -> :443, update app URLs
devstack ssl status     # cert expiry, CA presence, :443 listener
devstack ssl renew      # re-issue for the current site list
devstack ssl disable    # back to http only
```
Laravel `APP_URL` and WordPress `siteurl`/`home` are rewritten automatically; other kinds are left untouched.

## Migrating from XAMPP / WAMP / Laragon / Herd
Import existing sites without touching the other tool:
```powershell
devstack migrate                  # dry run: list discovered sites
devstack migrate --apply          # add them to sites.conf
devstack migrate --source wamp --apply
devstack sync
```
Nothing is copied or moved; imported sites point at your existing folders. PHP versions are mapped to the
nearest installed one (8.4+ -> 8.5, 8.x -> 8.3, 7.x -> 7.4); edit the `php` column if you want something
else. Herd discovery is best-effort.

Databases are **not** copied automatically, and the old server must be stopped first (both use `:3306` /
`:5432`):
```powershell
mysqldump -u root --all-databases > backup.sql
devstack migrate db backup.sql

pg_dumpall -U postgres > backup.sql
devstack migrate db backup.sql --engine pgsql
```

## PHP versions
- **Per site:** set the `php` column in `sites.conf` (e.g. `8.3`) and run `devstack sync`. That version
  serves that site.
- **Command line default** (`php`, Composer): `devstack php default 8.3` (or `7.4` / `8.5`), then open a
  new terminal. `devstack php status` shows the current choice; `devstack php list` lists installed
  versions. `devstack composer` still uses the site's declared PHP.

## After install
```powershell
notepad $env:USERPROFILE\.config\devstack\sites.conf   # add your projects
devstack sync
devstack doctor                                          # expect all green
```
Open a **new** terminal so the updated user PATH includes the CLI.

## Adding a project
There is no fixed web root - a site is just one line:
```ini
myapp.test | C:\Sites\myapp\public | 8.5 | laravel
```
| Project type | Document root |
|---|---|
| Laravel / Symfony | `<project>\public` |
| WordPress | the folder containing `wp-config.php` |
| Plain PHP / legacy | the folder containing `index.php` |
| Root `.htaccess` forwarding into `public\` | the project root |

`kind` only controls what `devstack ssl enable` rewrites. Then:
```powershell
devstack add-site     # interactive alternative
devstack sync
devstack doctor
```

## Updates
```powershell
devstack update --check
devstack update
devstack update --rollback
```
An update downloads the release source archive, verifies the version, and swaps the package **out of
process** (the running CLI locks its own files on Windows). It never touches `sites.conf`, config,
certificates, the hosts file, vhosts, databases or running services. The last three versions are kept for
rollback.

## Troubleshooting
| Symptom | Fix |
|---|---|
| `devstack: command not found` | open a new terminal; check `%LOCALAPPDATA%\devstack\bin` is on PATH |
| site returns **502** | Apache isn't running -> `devstack start apache` |
| site returns **404** on `:80` but works on `:8081` | stale vhosts -> `devstack sync` |
| site doesn't resolve | hosts block missing -> `devstack sync` (needs the helper task) |
| helper "not installed" | run `install.ps1` again, or `powershell -File %LOCALAPPDATA%\devstack\pkg\bin\Install-HelperTask.ps1` elevated |
| wrong PHP version | fix the `php` column, then `devstack sync` |
| `running scripts is disabled` | the CLI shim already uses `-ExecutionPolicy Bypass`; run scripts the same way |
| Apache/nginx config problem | `devstack doctor` prints the failing check; inspect under `%LOCALAPPDATA%\devstack\conf` |

## Verify
```powershell
devstack doctor          # binaries, services, config syntax, helper, every site
devstack status
```

# Safety (Windows)

dev-stack is designed to be safe to install, inspect and remove on a working machine.

## What it touches
| Path | Change |
|---|---|
| `C:\Windows\System32\drivers\etc\hosts` | adds/rewrites a delimited `# devstack-begin ... # devstack-end` block **only** |
| `%LOCALAPPDATA%\devstack\conf\nginx` | generated nginx config (owned by dev-stack) |
| `%LOCALAPPDATA%\devstack\conf\apache` | generated Apache config (owned by dev-stack) |
| `%USERPROFILE%\.config\devstack` | your config (never committed) |
| `%LOCALAPPDATA%\devstack` | installed package, log, backups, runtime PID files, certs |
| `Scheduled Task: DevStackHelper` | one task, highest privileges, hosts sync only |
| `%LOCALAPPDATA%\dev-stack-app` | the WPF app |
| `%LOCALAPPDATA%\devstack\certs` | TLS cert + private key, only when HTTPS is enabled |
| `%LOCALAPPDATA%\devstack\pkg-backups` | previous versions kept for `devstack update --rollback` (last 3) |

**Updates** replace only `%LOCALAPPDATA%\devstack\pkg` and the app bundle. They do **not** touch
`%USERPROFILE%\.config\devstack`, certificates, the hosts file, vhosts, databases or running services. The
version is verified before an atomic swap; the previous version is retained.

**mkcert CA** - enabling HTTPS runs `mkcert -install`, which adds a *local development CA* to the Windows
certificate store so browsers trust `*.test` certificates. That is standard for local dev.
`uninstall.ps1` removes the dev-stack certificates but leaves the CA in place; remove it yourself with
`mkcert -uninstall` if you want it gone.

It **never** touches files outside these paths.

## Reinstall and uninstall
- **Reinstalling** replaces only the application (`%LOCALAPPDATA%\devstack\pkg`, the app and its
  registration). Your `sites.conf`, settings, certificates, databases and backups are **left in place**.
- **Uninstalling** removes the app, CLI, helper task, hosts block, generated web configs and certs, but
  **keeps** `%USERPROFILE%\.config\devstack` (sites + settings), `%LOCALAPPDATA%\devstack\data`
  (MySQL/PostgreSQL data) and `%LOCALAPPDATA%\devstack\backups`. Add `-Purge` to delete config and
  database data too.
- Before every install/reinstall the hosts file and your config are copied to
  `%LOCALAPPDATA%\devstack\backups\<ts>`.

## Your data
dev-stack **does not copy your databases or project files**. Its backups cover only the configuration it
rewrites. Before anything destructive - database migrations, `uninstall.ps1`, `DROP` - take your own
dump/backup (`mysqldump`, `pg_dump`, `redis-cli --rdb`) and keep projects in version control. Provided
**as is**, no warranty - see the README disclaimer.

## Guardrails
- **`-DryRun`** prints every action and changes nothing (verify before trusting).
- **Backups** - the hosts file and config are copied to `%LOCALAPPDATA%\devstack\backups\<ts>` before any change.
- **Idempotent** - re-running reconciles; it does not duplicate or nest.
- **Least privilege** - the *only* privileged action is the hosts write, via one scheduled task. No general admin.
- **Loopback only** - Apache listens on `127.0.0.1:8081`; only nginx is on `:80`.
- **Config validation** - `nginx -t` and `httpd -t` are available via `devstack doctor`.
- **Clean removal** - `uninstall.ps1` stops services, removes the helper task, strips the hosts block and
  restores backups (run it elevated to remove the task and hosts block).

## Notes
- The installer runs `scoop install` for the packages; use `-NoScoop` if you manage packages yourself.
- The app is built with the in-box .NET Framework compiler (`csc.exe`) - no SDK download is required.
- The helper script is small and readable: [`../bin/DevStackWeb.ps1`](../bin/DevStackWeb.ps1). Read it before installing.

## Manual helper install (without the app)
```powershell
# run in an elevated PowerShell
powershell -File windows\bin\Install-HelperTask.ps1 -PackageRoot "$env:LOCALAPPDATA\devstack\pkg"
```

# Security (Windows)

dev-stack manages **local development services on your own Windows machine**. It is not hardened for
exposed or multi-user servers - do not run it on a shared/production host.

## Reporting a vulnerability
This repository is public. Please **do not** open a public issue or PR for security problems - use GitHub's
**Security -> Report a vulnerability** (private advisory) instead. Include steps to reproduce and the
affected script/version.

## Privileged surface (the whole of it)
Exactly one scheduled task runs with elevated rights:

```
Task name: DevStackHelper
Principal: <you>, LogonType Interactive, RunLevel Highest
Action:    powershell.exe -File <pkg>\bin\DevStackWeb.ps1
Trigger:   on demand (schtasks /run)
```

`DevStackWeb.ps1` can **only**:
- read generated nginx `server_name` values from `%LOCALAPPDATA%\devstack\conf\nginx\servers`, and
- rewrite a delimited block (`# devstack-begin ... # devstack-end`) in the hosts file.

It **never** runs arbitrary commands, and it never evaluates user-controlled content.

## Hardening in the helper
- No `Invoke-Expression`, no dot-sourcing of anything from your home directory.
- It processes request files that contain only an `id` and an `action`; the only accepted action is `sync-hosts`.
- Hostnames are **charset-validated** (`^[A-Za-z0-9][A-Za-z0-9._-]*$`) before being written to the hosts
  file, so a crafted vhost cannot inject host entries.
- The hosts block is replaced wholesale; unrelated lines are preserved.

## Input validation
`%USERPROFILE%\.config\devstack\sites.conf` is parsed with validation: hosts must be hostname-safe,
docroots may not contain quotes or semicolons, and `php` must be numeric. Invalid lines are skipped with a
warning instead of being written into nginx/Apache configuration.

## Secrets & files
- TLS private keys live in `%LOCALAPPDATA%\devstack\certs` and are never committed.
- No credentials are stored by dev-stack. Database/API credentials remain in your projects' own `.env` files.
- The installer backs up the hosts file and configuration before touching them.

## Updates
`devstack update` downloads the release source archive over HTTPS, checks that the archive's
`DevStackVersion` matches the release tag **before** swapping anything, and keeps the previous version for
rollback. The swap runs in a **detached process** because Windows locks the running script's files. It never
writes to `%USERPROFILE%\.config\devstack`, certificates, the hosts file, vhosts or databases. Windows
Defender may prompt on a downloaded update; code signing is out of scope for a local dev tool.

## Local certificate authority
Enabling HTTPS installs **mkcert's local development CA** into the Windows certificate store (standard for
local dev). It is a *development* CA, trusted only on this machine. Remove it with `mkcert -uninstall`.

## Dependencies
All dependencies are installed via **Scoop** (or Chocolatey) and are **not redistributed** by this project;
each keeps its own license and security posture. Keep them updated (`scoop update *`).

## Supported versions
Security fixes target the latest release (`main`). Report against the version shown by `devstack version`.

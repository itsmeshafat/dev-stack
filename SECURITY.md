# Security

dev-stack manages **local development services on your own Mac**. It is not hardened for exposed or
multi-user servers — do not run it on a shared/production host.

## Reporting a vulnerability
Please **do not** open a public issue. Use GitHub's **Security → Report a vulnerability** (private advisory)
on this repository. Include steps to reproduce and the affected script/version.

## Privileged surface (the whole of it)
Exactly one script runs as root, via a single sudoers rule:

```
/etc/sudoers.d/devstack
  <you> ALL=(root) NOPASSWD: /usr/local/sbin/devstack-web
```

`devstack-web` can **only**:
- start / stop / restart **nginx** (`brew services`), and
- rewrite a delimited block (`# devstack-begin … # devstack-end`) in `/etc/hosts`.

It **never** runs arbitrary commands, and it never executes or sources user-controlled files.

## Hardening in the helper
- No `eval`, no `.`/`source` of anything in your home directory.
- Only two **numeric** config keys (`NGINX_PORT`, `SSL_PORT`) are read; values must match `[0-9]+`.
- Hostnames are **charset-validated** (`^[A-Za-z0-9][A-Za-z0-9._-]*$`) before being written to
  `/etc/hosts`, so a crafted vhost cannot inject host entries.
- The user name comes from `SUDO_USER` and is validated with `id`; home dir is resolved via `dscl`.

## Input validation
`~/.config/devstack/sites.conf` is parsed with validation: hosts must be hostname-safe, docroots may not
contain quotes/semicolons or newlines, and `php` must be numeric. Invalid lines are skipped with a warning
instead of being written into nginx/Apache configuration.

## Secrets & files
- TLS private keys live in `~/.local/share/devstack/certs/` with mode `0600` and are never committed
  (`.gitignore` excludes `*.pem`).
- No credentials are stored by dev-stack. Database/API credentials remain in your projects' own `.env` files.
- The installer backs up every file it changes before touching it.

## Local certificate authority
Enabling HTTPS installs **mkcert's local development CA** into your keychain (standard for local dev). It is
a *development* CA, trusted only on this machine. Remove it with `mkcert -uninstall`.

## Dependencies
All dependencies are installed via **Homebrew** and are **not redistributed** by this project; each keeps its
own license and security posture. Keep them updated (`brew upgrade`).

## Supported versions
Security fixes target the latest release (`main`). Report against the version shown by `devstack version`.

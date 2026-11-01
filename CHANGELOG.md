# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and the project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-11-01

### Added
- **One-command local stack for macOS**: nginx on `:80` fronting Apache on `127.0.0.1:8081`, with per-site
  vhosts, `AllowOverride All` (real `.htaccess`/`mod_rewrite`) and PHP-FPM over unix sockets.
- **Multiple PHP versions**: 8.5, 8.3 and 7.4 side by side; each site selects its own.
- **Services**: MySQL 8.4 (LTS), PostgreSQL 18, Redis, Mailpit — managed as start/stop modules.
- **Trusted HTTPS**: mkcert wildcard `*.test` certificate, `http://` → `https://` redirect, per-site SANs,
  with automatic Laravel `APP_URL` / WordPress `siteurl` sync (`devstack ssl enable|disable|status|renew`).
- **DNS without a daemon**: managed `/etc/hosts` block generated from the nginx vhosts.
- **Native SwiftUI control app** with live status, per-module control and an in-app privileged-helper installer.
- **`devstack` CLI**: `status`, `start|stop|restart`, `sites`, `add-site`, `sync`, `composer`, `ssl`, `doctor`.
- **`devstack composer`**: runs Composer with the PHP version a site declares.
- **Safe installer**: `--dry-run`, automatic backups, idempotent, scoped privileged helper, clean `uninstall.sh`.
- Original generated app icon and README banner (vector, no third-party assets).

### Security
- Privileged helper reads only numeric config keys, never sources user files, and validates hostnames.
- `sites.conf` input is validated before being written into web-server configuration.

[1.0.0]: https://github.com/itsmeshafat/dev-stack/releases/tag/v1.0.0

# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and the project adheres to [Semantic Versioning](https://semver.org/).

## [1.3.5] — 2026-11-02

### Changed
- **`devstack.log` now records the caller** of every service action, e.g.
  `stop all [pid=8467 via=DevStack<launchd>]` vs `via=zsh<Terminal>`, so it is unambiguous whether a start/stop
  came from the app, a terminal, or an automation.

## [1.3.4] — 2026-11-02

### Added
- Donate link in more places: the `devstack --help` footer, the installer summary, `docs/INSTALL.md`, and a
  **Donate…** item in the app menu (the app footer button and the Help guide already had it).

### Changed
- `.github/FUNDING.yml` now points only at <https://www.itsmeshafat.com/donate> — the old supportkori link was
  removed.

## [1.3.3] — 2026-11-02

### Added
- **Donate link** — a subtle **♥ Donate** button on the right side of the app footer opens
  <https://www.itsmeshafat.com/donate>. The README and the in-app Help guide link to it too.

## [1.3.2] — 2026-11-02

### Added
- **Disclaimer** — README, `docs/NOTICE.md`, `docs/SAFETY.md`, the in-app Help guide, the installer summary and
  a footer line in the app now state that dev-stack is provided **as-is, without warranty**, and that it
  **does not back up databases or project files** (only the configuration it rewrites).

## [1.3.1] — 2026-11-02

### Fixed
- **Reinstalling no longer downgrades HTTPS.** `install.sh` did not load
  `~/.config/devstack/config`, so re-running it regenerated HTTP-only vhosts even when `SSL=1`
  (sites stayed up but lost `:443`). The installer now honours the existing settings.

## [1.3.0] — 2026-11-02

### Added
- **Update pipeline** — the app checks for a new release when it launches and shows an **Update available**
  banner (Update now · Release notes · Dismiss), plus **Check for Updates…** (⌘U) in the app menu.
- **Safe self-update** — `devstack update` downloads the release tarball, verifies the version, atomically
  swaps the installed package (keeping the last 3 backups), rebuilds the app, and updates the privileged
  helper **only if it changed** (a single admin prompt). Sites, config, certificates, hosts, vhosts,
  databases and running services are never touched.
- `devstack update --check [--json]` and `devstack update --rollback`.

### Safety
- Version is verified **before** the swap; the swap is an atomic rename (no partial state, the running
  script stays valid), and the previous version is retained for rollback.
- Vhost-template changes stay opt-in via `devstack sync`.

## [1.2.0] — 2026-11-02

### Added
- **Help menu item** — *Dev Stack Help* in the macOS Help menu (**⌘?**) opens the guide from anywhere in the app.
- **Docs-driven help** — the in-app guide is now rendered from **`docs/HELP.md`**, bundled into the app at build
  time, so the documentation and the app stay in sync from a single file.

## [1.1.0] — 2026-11-02

### Added
- **In-app Help** — a **Help** button in the app opens a scrollable guide (quick start, adding a site,
  document-root rules, commands, troubleshooting) with a **Close** button, so the docs are available without
  opening the README.
- Documentation: an **“Adding a site”** section in the README and `docs/INSTALL.md` covering new and existing
  projects and which folder should be the document root.

## [1.0.2] — 2026-11-02

### Fixed
- **Service failures are no longer silent.** `devstack start`/`stop` now surface the underlying
  `brew services` error instead of appearing to do nothing. (A stale `my.cnf` include directory made MySQL
  refuse to start while the CLI printed nothing.)

### Verified
- Full start/stop matrix: every module stops and starts cleanly; **Stop All** closes all listeners
  (`:80/:443/:8081/:3306/:5432/:6379`); **Start All** brings all 9 modules back and sites serve 200/302.

## [1.0.1] — 2026-11-01

### Fixed
- **"Stop All" now stops every module.** The reverse-order loop used `tac` (GNU coreutils, not present on
  macOS), so it expanded to nothing and only nginx stopped. Replaced with an explicit `MODULES_STOP` order.
- ShellCheck findings (`A && B || C`, `ls | head`, unquoted vars) so the CI gate is clean.

### Added
- **CI** (GitHub Actions): `shellcheck` + `bash -n`; on macOS a `/bin/bash` 3.2 parse, Swift app build,
  icon/banner render, and `install.sh --dry-run`. CI badge in the README.
- Repository is **public**: install instructions, live release/stars badges, public security-reporting guidance.

### Changed
- Release notes and install docs updated for a public repository.

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
[1.0.1]: https://github.com/itsmeshafat/dev-stack/releases/tag/v1.0.1
[1.0.2]: https://github.com/itsmeshafat/dev-stack/releases/tag/v1.0.2
[1.1.0]: https://github.com/itsmeshafat/dev-stack/releases/tag/v1.1.0
[1.2.0]: https://github.com/itsmeshafat/dev-stack/releases/tag/v1.2.0
[1.3.0]: https://github.com/itsmeshafat/dev-stack/releases/tag/v1.3.0
[1.3.1]: https://github.com/itsmeshafat/dev-stack/releases/tag/v1.3.1
[1.3.2]: https://github.com/itsmeshafat/dev-stack/releases/tag/v1.3.2
[1.3.3]: https://github.com/itsmeshafat/dev-stack/releases/tag/v1.3.3
[1.3.4]: https://github.com/itsmeshafat/dev-stack/releases/tag/v1.3.4
[1.3.5]: https://github.com/itsmeshafat/dev-stack/releases/tag/v1.3.5

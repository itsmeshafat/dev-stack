# Legal / notice

## Originality
All source code in this repository — the shell scripts (`install.sh`, `bin/`, `lib/`, `scripts/`), the
Swift/SwiftUI application (`app/`), the configuration templates and the documentation — was written for this
project and is licensed under the [MIT License](LICENSE).

**No third-party source code is vendored or copied.** Apache/nginx directives used here are standard,
functional configuration, not copied application logic.

## Assets
The application icon and the README banner are **generated from original vector code**
(`app/makeicon.swift`, `app/makebanner.swift`) and contain:

- no SF Symbols or other Apple-provided glyphs,
- no stock art, icon packs, or third-party images,
- no fonts beyond the macOS system font, rendered at build time (fonts are not redistributed).

The screenshot in `docs/` depicts this project's own app.

## Dependencies (not redistributed)
dev-stack installs its dependencies through **Homebrew** at install time. They are **not bundled** with this
repository and each remains under its own license and copyright, including (verify upstream for current terms):

| Dependency | Project |
|---|---|
| nginx | BSD-2-Clause |
| Apache httpd | Apache-2.0 |
| MySQL | GPL-2.0 |
| PostgreSQL | PostgreSQL License |
| Redis | BSD-3-Clause / RSALv2 / SSPLv1 (per version) |
| Mailpit | MIT |
| PHP | PHP License 3.01 |
| Composer | MIT |
| WP-CLI | MIT |
| mkcert | BSD-3-Clause |

## Trademarks
"Apple", "macOS", "Homebrew", "Laravel", "WordPress", "nginx", "Apache", "MySQL", "PostgreSQL", "Redis" and
other names are trademarks of their respective owners. This project is not affiliated with or endorsed by them.

## Disclaimer
Provided **“as is”**, without warranty of any kind, express or implied. The authors are **not liable** for data
loss, service interruption, or any other damage arising from use — see [LICENSE](../LICENSE) and the
[README disclaimer](../README.md#disclaimer).

dev-stack **does not back up your databases or project files**. Its automatic backups cover only the
configuration it rewrites (`/etc/hosts`, nginx/Apache configs, php-fpm `www.conf`). Keep your own database
dumps and keep projects in version control.

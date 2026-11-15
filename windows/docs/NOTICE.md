# Legal / notice (Windows)

## Originality
All source code in the Windows implementation - the PowerShell CLI (`windows\devstack.ps1`, `windows\lib\`,
`windows\bin\`, `windows\install.ps1`, `windows\uninstall.ps1`), the WPF application (`windows\app\`), the
configuration templates and the documentation - was written for this project and is licensed under the
[MIT License](../../LICENSE).

**No third-party source code is vendored or copied.**

## Dependencies (not redistributed)
dev-stack installs its dependencies through **Scoop** (or Chocolatey) at install time. They are **not
bundled** with this repository and each remains under its own license and copyright. Verify upstream for
current terms.

| Dependency | Project |
|---|---|
| nginx | BSD-2-Clause |
| Apache httpd (Apache Lounge build) | Apache-2.0 |
| MySQL | GPL-2.0 |
| PostgreSQL | PostgreSQL License |
| Redis | BSD-3-Clause / RSALv2 / SSPLv1 (per version) |
| Mailpit | MIT |
| PHP | PHP License 3.01 |
| Composer | MIT |
| WP-CLI | MIT |
| mkcert | BSD-3-Clause |

## Trademarks
"Microsoft", "Windows", "Scoop", "Chocolatey", "Laravel", "WordPress", "nginx", "Apache", "MySQL",
"PostgreSQL", "Redis" and other names are trademarks of their respective owners. This project is not
affiliated with or endorsed by them.

## Disclaimer
Provided **"as is"**, without warranty of any kind, express or implied. The authors are **not liable** for
data loss, service interruption, or any other damage arising from use - see the
[LICENSE](../../LICENSE) and the README disclaimer.

dev-stack **does not back up your databases or project files**. Its automatic backups cover only the
configuration it rewrites. Keep your own database dumps and keep projects in version control.

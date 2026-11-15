# Architecture (Windows)

```
                      +---------------- yourapp.test :80 ----------------+
   browser ---------->| nginx  (%LOCALAPPDATA%\devstack\conf\nginx)      |
                      |   servers\<host>.conf -> proxy_pass 127.0.0.1:8081
                      +----------------------+---------------------------+
                                             v
                      +-------- Apache 127.0.0.1:8081 ------------------+
                      | vhosts\<host>.conf                              |
                      |   AllowOverride All -> .htaccess / mod_rewrite   |
                      |   <FilesMatch \.php$> SetHandler proxy:fcgi://   |
                      +----------------------+---------------------------+
                                             v
              php-cgi FastCGI: 127.0.0.1:9085 - :9083 - :9074 (one per PHP version)

   data:   mysql :3306 - postgres :5432 - redis :6379 - mailpit :1025/:8025
   DNS:    managed block in C:\Windows\System32\drivers\etc\hosts
           (127.0.0.1 <host>, generated from nginx server_name)
```

## Pieces
| Path | Role |
|---|---|
| `windows\devstack.ps1` | user CLI - status/start/stop/restart/sites/add-site/sync/ssl/doctor |
| `windows\lib\Common.psm1` | paths, config, logging, dry-run, backups, port/process utilities |
| `windows\lib\Modules.psm1` | the service table (module -> binary, port, detail) and process lifecycle |
| `windows\lib\Sites.psm1` | parses `sites.conf`; generates nginx + Apache vhosts and base configs |
| `windows\lib\Hosts.psm1` | managed hosts block + helper IPC |
| `windows\lib\Ssl.psm1` | mkcert certificate issue, app URL rewrite |
| `windows\lib\Update.psm1` | release check + out-of-process self-update + rollback |
| `windows\lib\PhpMyAdmin.psm1` | optional phpMyAdmin provisioning |
| `windows\bin\Install-HelperTask.ps1` | (elevated) registers the DevStackHelper scheduled task |
| `windows\bin\DevStackWeb.ps1` | helper body - hosts sync only |
| `windows\bin\Update-Swap.ps1` | detached package swapper |
| `windows\app\` | Windows Forms control app + build/uninstall scripts |

## Why nginx *and* Apache
`.htaccess`/`mod_rewrite` projects (legacy PHP, WordPress quirks, Laravel) behave correctly under Apache;
nginx is a thin, fast front door that keeps a single public port and clean URLs. Apache binds to
**127.0.0.1 only**, so nothing is exposed beyond loopback.

## Why php-cgi
Windows has no php-fpm. Each PHP version runs `php-cgi.exe -b 127.0.0.1:<port>` as a persistent FastCGI
worker, and Apache's `mod_proxy_fcgi` forwards `.php` requests to it. This avoids the per-request overhead
of plain CGI. Note that a single Windows php-cgi process serves one request at a time; that is fine for
local development.

## Privilege model
Windows does not restrict binding to ports below 1024 for normal users, so nginx, Apache, php-cgi and the
databases all run **unelevated** as you, managed by the CLI. The only privileged operation is writing the
system hosts file. That is done by the **DevStackHelper** scheduled task, registered once with a single
UAC prompt and triggered on demand with `schtasks /run` (no repeated prompts).

## Ports
`80` (nginx) - `443` (nginx TLS, when enabled) - `8081` (Apache) - `9085/9083/9074` (php-cgi) -
`3306` (MySQL) - `5432` (PostgreSQL) - `6379` (Redis) - `1025`/`8025` (Mailpit).
Ports are overridable in `%USERPROFILE%\.config\devstack\config`.

## DNS without a daemon
After `sync`, the helper reads every `server_name` from the generated nginx vhosts and writes:

```
# devstack-begin
127.0.0.1 yourapp.test
# devstack-end
```

so resolution needs no DNS server and survives reboots. Add a site -> `devstack sync` -> it resolves.

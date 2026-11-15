# Dev Stack - Help (Windows)

## Quick start
Start or stop everything - or a single module - with the buttons in the main window, or from a terminal.

```
devstack status
devstack start | stop | restart [module]
devstack doctor
```

## Add a new project
1. Put the project anywhere (e.g. C:\Sites\myapp).
2. Register it - interactively, or add one line to %USERPROFILE%\.config\devstack\sites.conf.

```
devstack add-site

# host | docroot | php | kind | aliases
myapp.test | C:\Sites\myapp\public | 8.5 | laravel
```

3. Apply and verify.

```
devstack sync
devstack doctor
```

## Point an existing project here
Nothing is moved or copied. Add one line pointing at its document root and run devstack sync - that is all.

## Which folder is the document root?
| Project type | Docroot |
|---|---|
| Laravel / Symfony | <project>\public |
| WordPress | the folder containing wp-config.php |
| Plain PHP / legacy | the folder containing index.php |
| Root .htaccess forwarding to public\ | the project root |

The "kind" column only controls what SSL toggling rewrites: Laravel APP_URL, WordPress siteurl/home.

## Databases
MySQL 8.4 (:3306), PostgreSQL 18 (:5432) and Redis (:6379) run as local processes. dev-stack does not
create databases, users or passwords for you - and it never backs up your data. Full guide: docs/DATABASES.md.

### MySQL
```
mysql -u root
```
```
CREATE DATABASE myapp CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER 'myapp'@'localhost' IDENTIFIED BY 'STRONG-PASSWORD';
CREATE USER 'myapp'@'127.0.0.1' IDENTIFIED BY 'STRONG-PASSWORD';
GRANT ALL PRIVILEGES ON myapp.* TO 'myapp'@'localhost';
GRANT ALL PRIVILEGES ON myapp.* TO 'myapp'@'127.0.0.1';
FLUSH PRIVILEGES;
```
localhost (socket) and 127.0.0.1 (TCP) count as different accounts, so create both.

Prefer a GUI? phpMyAdmin is opt-in - install it, then log in with a MySQL account.

```
devstack phpmyadmin install
```

https://phpmyadmin.test - installed on PHP 8.3, cookie auth, so no password is stored.

### PostgreSQL
Your Windows user is a superuser and local connections are trusted.

```
psql -U postgres
```
```
CREATE ROLE myapp LOGIN PASSWORD 'STRONG-PASSWORD';
CREATE DATABASE myapp OWNER myapp;
```

### Redis
No users or passwords by default, and "databases" are numbered keyspaces 0-15.

```
redis-cli -n 1        # keyspace 1
redis-cli FLUSHDB     # wipe the current keyspace (destructive)
```

### Back up before you migrate
dev-stack never backs up databases, so dump them yourself first.

```
mysqldump -u root --all-databases > $env:USERPROFILE\Backups\mysql.sql
pg_dumpall -U postgres > $env:USERPROFILE\Backups\postgres.sql
```

## Updates
The app checks for a newer release at launch and shows an Update banner (Update now - Dismiss). You can also
check from the menu.

```
devstack update --check
devstack update
devstack update --rollback
```

An update replaces only the app code and the app bundle. Sites, config, certificates, hosts and running
services are never touched.

## Migrating from XAMPP / WAMP / Laragon / Herd
dev-stack can discover the sites you already have (read-only - the other tool is not modified):

```
devstack migrate                    # show what it can see, changes nothing
devstack migrate --apply            # add new sites to sites.conf
devstack migrate --source laragon --apply
devstack sync
```

Files are never copied or moved - each imported site points at your existing folder. PHP versions are
mapped to the nearest installed version (8.4+ -> 8.5, 8.x -> 8.3, 7.x -> 7.4); adjust the `php` column if
needed. Herd detection is best-effort.

Databases are not copied automatically. Both stacks use port 3306/5432, so stop the other tool's MySQL
first, dump, then import:

```
mysqldump -u root --all-databases > backup.sql
devstack migrate db backup.sql                 # into dev-stack MySQL

pg_dumpall -U postgres > backup.sql
devstack migrate db backup.sql --engine pgsql  # into dev-stack PostgreSQL
```

## PHP versions
Each site chooses its PHP in sites.conf (the `php` column) - that is the version its web requests use:

```
myapp.test | C:\Sites\myapp\public | 8.3 | laravel
devstack sync
```

For the command line (`php`, Composer), pick the default:

```
devstack php status
devstack php default 8.3      # or 7.4 / 8.5
```

Open a new terminal afterwards. `devstack composer` still uses the site's PHP (auto-detected, or
`--site myapp.test`), regardless of the CLI default.

## Running in the background
Closing the window (X or Alt+F4) does not quit - the app keeps running in the notification area next to
the clock. Click the tray icon to reopen it, or right-click it for:

- Open Dev Stack - reopen the window
- Start All / Stop All / Restart All - control the whole stack
- Modules - start or stop a single module
- Quit Dev Stack - really exit

Polling pauses while the window is hidden, so it stays light in the background. Use the tray's
Quit Dev Stack (or File > Exit) when you want to shut the app down completely.

## Commands
| Command | Does |
|---|---|
| devstack status | every module and its state |
| devstack start / stop / restart [module] | control all modules, or one |
| devstack sites | list configured sites |
| devstack add-site | add a site interactively |
| devstack sync | regenerate vhosts + hosts, reload |
| devstack composer --site HOST | run Composer with the site's PHP |
| devstack migrate [--apply] | import sites from XAMPP/WAMP/Laragon/Herd |
| devstack migrate db FILE | import a mysqldump / pg_dump |
| devstack ssl enable / disable | trusted HTTPS for all sites |
| devstack doctor | verify services, configs, sites |

## Looks broken?
| Symptom | Fix |
|---|---|
| 502 Bad Gateway | Apache is down - devstack start apache |
| 404 on :80 but works on :8081 | stale vhosts - devstack sync |
| Site name doesn't resolve | hosts entry missing - devstack sync |
| Wrong PHP version | fix the php column, then devstack sync |
| A module won't start | the console shows the underlying error |

## Disclaimer
This is a local development tool, provided as-is with no warranty (MIT license). It does not back up your
databases or project files - keep your own dumps and use version control. Its automatic backups cover only
the configuration it rewrites, under %LOCALAPPDATA%\devstack\backups.

## Where things live
| What | Path |
|---|---|
| sites | %USERPROFILE%\.config\devstack\sites.conf |
| settings | %USERPROFILE%\.config\devstack\config |
| activity log | %LOCALAPPDATA%\devstack\devstack.log |
| config backups | %LOCALAPPDATA%\devstack\backups |
| web configs | %LOCALAPPDATA%\devstack\conf |

## Removing dev-stack
Uninstall from **Settings > Apps > Installed apps > Dev Stack**, or run `uninstall.ps1`. Your `sites.conf`,
settings and databases are **kept** so a reinstall keeps working; add `-Purge` to delete them too.
dev-stack never backs up your databases or project files - keep your own dumps.

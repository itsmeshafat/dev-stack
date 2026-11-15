# Databases (Windows)

dev-stack runs the database servers as local processes. It does **not** create databases, users or
passwords for you, and it **never backs them up**. This page is the cookbook.

## What's running where
| Engine | Module | Address | Admin account | Data directory |
|---|---|---|---|---|
| MySQL | `mysql` | `127.0.0.1:3306` | `root` (no password on first init) | `%LOCALAPPDATA%\devstack\data\mysql` |
| PostgreSQL | `postgres` | `127.0.0.1:5432` | your Windows username (superuser) | `%LOCALAPPDATA%\devstack\data\postgres` |
| Redis | `redis` | `127.0.0.1:6379` | none (no password by default) | in-memory |

```powershell
devstack status          # is the engine you need actually running?
devstack start mysql     # or: postgres - redis
```

---

## MySQL
On first start dev-stack initializes the data directory with `mysqld --initialize-insecure`, so `root` has
**no password** initially.

```powershell
mysql -u root
```
```sql
CREATE DATABASE myapp CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

CREATE USER 'myapp'@'localhost' IDENTIFIED BY 'STRONG-PASSWORD';
CREATE USER 'myapp'@'127.0.0.1' IDENTIFIED BY 'STRONG-PASSWORD';

GRANT ALL PRIVILEGES ON myapp.* TO 'myapp'@'localhost';
GRANT ALL PRIVILEGES ON myapp.* TO 'myapp'@'127.0.0.1';
FLUSH PRIVILEGES;
```

> `localhost` and `127.0.0.1` are different accounts to MySQL - `localhost` uses a socket, `127.0.0.1` uses
> TCP. Laravel connects over TCP while the `mysql` CLI usually uses the socket, so create both.

Verify: `mysql -u myapp -p -h 127.0.0.1 myapp -e "SELECT 1;"`

### Everyday SQL
| Task | Statement |
|---|---|
| list databases | `SHOW DATABASES;` |
| list accounts | `SELECT user, host FROM mysql.user;` |
| change a password | `ALTER USER 'myapp'@'127.0.0.1' IDENTIFIED BY 'new';` |
| grants for one database | `SHOW GRANTS FOR 'myapp'@'127.0.0.1';` |
| drop a database (destructive) | `DROP DATABASE myapp;` |

### Back up and restore
```powershell
mysqldump -u root myapp > $env:USERPROFILE\Backups\myapp.sql
mysqldump -u root --all-databases > $env:USERPROFILE\Backups\all.sql
mysql -u root myapp < $env:USERPROFILE\Backups\myapp.sql
```

### GUI - phpMyAdmin (optional)
```powershell
devstack phpmyadmin install
devstack phpmyadmin status
```
Downloads the current phpMyAdmin, verifies the published SHA-256, installs it under
`%USERPROFILE%\Sites\phpmyadmin`, registers `phpmyadmin.test` on **PHP 8.3**, and reloads. Open
**https://phpmyadmin.test** and log in with a MySQL account. Authentication is `cookie`, so **no database
password is written to disk**. An existing install dev-stack did not create is never overwritten unless you
pass `--force` (it is backed up first).

### Troubleshooting
| Error | Meaning / fix |
|---|---|
| `ERROR 1045 Access denied for user 'root'` | wrong password or wrong host - try `-h 127.0.0.1` |
| `ERROR 1049 Unknown database` | typo, or the app's `.env` names a database that does not exist |
| `ERROR 1044 Access denied ... to database` | missing `GRANT` for that database/host |
| `SQLSTATE[HY000] [2002]` | MySQL isn't running -> `devstack start mysql` |

---

## PostgreSQL
Local connections are trusted; connect as your Windows user (superuser).

```powershell
psql -U postgres
```
```sql
CREATE ROLE myapp LOGIN PASSWORD 'STRONG-PASSWORD';
CREATE DATABASE myapp OWNER myapp;
```

### Everyday
| Task | Command |
|---|---|
| list databases | `\l` |
| list roles | `\du` |
| connect | `psql -U myapp -d myapp` |
| change a password | `ALTER ROLE myapp PASSWORD 'new';` |
| drop a database (destructive) | `DROP DATABASE myapp;` |

### Back up and restore
```powershell
pg_dump -U postgres -d myapp > $env:USERPROFILE\Backups\myapp.sql
pg_dump -U postgres -d myapp -Fc -f $env:USERPROFILE\Backups\myapp.dump
pg_restore -U postgres -d myapp --clean $env:USERPROFILE\Backups\myapp.dump
```

### Troubleshooting
| Error | Meaning / fix |
|---|---|
| `role "x" does not exist` | `CREATE ROLE x LOGIN PASSWORD '...';` |
| `database "x" does not exist` | `CREATE DATABASE x OWNER x;` |
| `could not connect to server` | PostgreSQL isn't running -> `devstack start postgres` |

---

## Redis
No users or passwords by default; "databases" are numbered keyspaces (0-15).

```powershell
redis-cli                 # keyspace 0
redis-cli -n 1            # keyspace 1
redis-cli FLUSHDB         # wipe the current keyspace (destructive)
redis-cli FLUSHALL        # wipe every keyspace (destructive)
```

---

## Backups - yours to own
dev-stack backs up only the configuration it rewrites. It cannot undo a dropped database. Before migrating,
importing over something, or uninstalling:

```powershell
mkdir $env:USERPROFILE\Backups -Force
mysqldump -u root --all-databases > $env:USERPROFILE\Backups\mysql.sql
pg_dumpall -U postgres > $env:USERPROFILE\Backups\postgres.sql
```

## Using a database from an app
Laravel `.env`:
```ini
DB_CONNECTION=mysql          # or: pgsql
DB_HOST=127.0.0.1
DB_PORT=3306                 # 5432 for PostgreSQL
DB_DATABASE=myapp
DB_USERNAME=myapp
DB_PASSWORD=STRONG-PASSWORD
```
WordPress `wp-config.php`:
```php
define('DB_NAME', 'myapp');
define('DB_USER', 'myapp');
define('DB_PASSWORD', 'STRONG-PASSWORD');
define('DB_HOST', '127.0.0.1:3306');
```

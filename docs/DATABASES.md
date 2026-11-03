# Databases

dev-stack runs the database servers as plain Homebrew services. It does **not** create databases, users or
passwords for you, and it **never backs them up**. This page is the cookbook.

> `$(brew --prefix)` is `/opt/homebrew` on Apple Silicon and `/usr/local` on Intel — swap accordingly.

## What's running where

| Engine | Service | Address | Admin account | Data directory |
|---|---|---|---|---|
| MySQL | `mysql@8.4` | `127.0.0.1:3306` | `root` | `$(brew --prefix)/var/mysql` |
| PostgreSQL | `postgresql@18` | `127.0.0.1:5432` | your macOS username (superuser) | `$(brew --prefix)/var/postgresql@18` |
| Redis | `redis` | `127.0.0.1:6379` | none (no password by default) | `$(brew --prefix)/var/db/redis` |

```bash
devstack status          # is the engine you need actually running?
devstack start mysql     # or: postgres · redis
```

---

## MySQL

Open an admin shell:

```bash
mysql -u root -p            # then type the root password
```

> **Where's the root password?** It's the one set when MySQL was configured on this machine. If you added the
> phpMyAdmin site, it stores the password for its `config` auth type in
> `~/Sites/phpmyadmin/config.inc.php` — `grep password ~/Sites/phpmyadmin/config.inc.php`. Forgotten it?
> See [Reset the MySQL root password](#reset-the-mysql-root-password).

### Create a database, user and password

```sql
CREATE DATABASE myapp CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

CREATE USER 'myapp'@'localhost' IDENTIFIED BY 'STRONG-PASSWORD';
CREATE USER 'myapp'@'127.0.0.1' IDENTIFIED BY 'STRONG-PASSWORD';

GRANT ALL PRIVILEGES ON myapp.* TO 'myapp'@'localhost';
GRANT ALL PRIVILEGES ON myapp.* TO 'myapp'@'127.0.0.1';
FLUSH PRIVILEGES;
```

One-shot from the shell (no interactive session):

```bash
mysql -u root -p <<'SQL'
CREATE DATABASE myapp CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER 'myapp'@'127.0.0.1' IDENTIFIED BY 'STRONG-PASSWORD';
GRANT ALL PRIVILEGES ON myapp.* TO 'myapp'@'127.0.0.1';
SQL
```

> **`localhost` and `127.0.0.1` are different accounts** to MySQL — `localhost` goes over the Unix socket,
> `127.0.0.1` over TCP. Laravel connects over TCP while the `mysql` CLI usually uses the socket, so creating
> both avoids a confusing "access denied".

Verify the new account works:

```bash
mysql -u myapp -p -h 127.0.0.1 myapp -e "SELECT 1;"
```

### Everyday SQL

| Task | Statement |
|---|---|
| list databases | `SHOW DATABASES;` |
| list accounts | `SELECT user, host FROM mysql.user;` |
| change a password | `ALTER USER 'myapp'@'127.0.0.1' IDENTIFIED BY 'new';` |
| grants for one database | `SHOW GRANTS FOR 'myapp'@'127.0.0.1';` |
| revoke everything | `REVOKE ALL PRIVILEGES ON myapp.* FROM 'myapp'@'127.0.0.1';` |
| drop a user | `DROP USER 'myapp'@'127.0.0.1';` |
| **drop a database** (destructive) | `DROP DATABASE myapp;` |

### Back up and restore

```bash
mysqldump -u root -p myapp > ~/Backups/myapp.sql           # one database
mysqldump -u root -p --all-databases > ~/Backups/all.sql   # everything
mysql -u root -p myapp < ~/Backups/myapp.sql               # restore
```

### GUI

If you registered a **phpMyAdmin** site in `sites.conf`, open **https://phpmyadmin.test** →
*Databases* to create one, *User accounts* to add a user.

### Troubleshooting

| Error | Meaning / fix |
|---|---|
| `ERROR 1045 Access denied for user 'root'@'localhost'` | wrong password, or you're connecting as a different account — try adding `-h 127.0.0.1`, or reset the root password below |
| `ERROR 1049 Unknown database` | typo, or the app's `.env` names a database that doesn't exist yet |
| `ERROR 1044 Access denied … to database …` | the account is missing a `GRANT` for that database (or for the host you're connecting as) |
| PHP: `SQLSTATE[HY000] [2002]` | MySQL isn't running → `devstack start mysql` |
| an old client tool can't authenticate | MySQL 8.4 defaults to `caching_sha2_password`; PHP 7.4+ is fine. For a legacy tool: `ALTER USER 'myapp'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '…';` |

### Reset the MySQL root password

```bash
brew services stop mysql@8.4
mysqld_safe --skip-grant-tables --skip-networking &
mysql -u root <<'SQL'
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY 'NEW-PASSWORD';
SQL
mysqladmin -u root -pNEW-PASSWORD shutdown
brew services start mysql@8.4
```

---

## PostgreSQL

PostgreSQL is set up with local **trust** authentication: you connect as your macOS username, which is a
**superuser**. No password is needed locally.

```bash
psql postgres        # or: psql -d postgres
```

### Create a role, database and password

```sql
CREATE ROLE myapp LOGIN PASSWORD 'STRONG-PASSWORD';
CREATE DATABASE myapp OWNER myapp;
```

Or the one-liners (the first prompts for the password):

```bash
createuser -P myapp
createdb -O myapp myapp
```

> **Why set a password if it isn't checked locally?** So your `.env` matches production. Local connections are
> trusted, so the password is simply ignored here — it starts being enforced when you deploy.

> **PostgreSQL 15+ note** — the `public` schema is owned by the database owner, so the role that owns a
> database can create tables in it without any extra `GRANT`.

### Everyday SQL

| Task | Statement / command |
|---|---|
| list databases | `\l` |
| list roles | `\du` |
| connect | `psql -d myapp` |
| change a password | `ALTER ROLE myapp PASSWORD 'new';` |
| let a role create databases | `ALTER ROLE myapp CREATEDB;` |
| change a database's owner | `ALTER DATABASE myapp OWNER TO myapp;` |
| **drop a database** (destructive) | `DROP DATABASE myapp;` |
| drop a role | `DROP ROLE myapp;` |

### Back up and restore

```bash
pg_dump -d myapp > ~/Backups/myapp.sql            # plain SQL
pg_dump -d myapp -Fc -f ~/Backups/myapp.dump      # custom format (recommended)
pg_restore -d myapp --clean ~/Backups/myapp.dump
psql -d myapp -f ~/Backups/myapp.sql
```

### Troubleshooting

| Error | Meaning / fix |
|---|---|
| `FATAL: password authentication failed` | you're connecting from a host that isn't trusted, or the role's password differs |
| `FATAL: role "x" does not exist` | `CREATE ROLE x LOGIN PASSWORD '…';` |
| `FATAL: database "x" does not exist` | `createdb -O x x` |
| `permission denied for schema public` | the role doesn't own the database → `ALTER DATABASE myapp OWNER TO myapp;` |
| `could not connect to server` | PostgreSQL isn't running → `devstack start postgres` |

---

## Redis

Redis has no users or passwords by default, and "databases" are numbered keyspaces (`0`–`15`) rather than
separate stores:

```bash
redis-cli                 # connect to keyspace 0
redis-cli -n 1            # keyspace 1
redis-cli INFO keyspace   # what exists in each
redis-cli FLUSHDB         # wipe the current keyspace   (destructive)
redis-cli FLUSHALL        # wipe every keyspace         (destructive)
```

To require a password, add `requirepass STRONG-PASSWORD` to `$(brew --prefix)/etc/redis.conf`, then
`devstack restart redis`. Clients authenticate with `redis-cli -a STRONG-PASSWORD`, and apps use
`REDIS_PASSWORD=…` in `.env`.

---

## Backups — yours to own

dev-stack backs up only the **configuration it rewrites**. It does not touch your data, and it cannot undo a
dropped database. Before migrating, importing over something, or running `./uninstall.sh`:

```bash
mkdir -p ~/Backups
mysqldump -u root -p --all-databases > ~/Backups/mysql-$(date +%F).sql
pg_dumpall > ~/Backups/postgres-$(date +%F).sql
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

Then `php artisan migrate` (Laravel) or open the site's `wp-admin/install.php` (WordPress).

## Cheat sheet

| I want to… | MySQL | PostgreSQL |
|---|---|---|
| open an admin shell | `mysql -u root -p` | `psql postgres` |
| create a database | `CREATE DATABASE x;` | `createdb x` |
| create a user | `CREATE USER 'x'@'127.0.0.1' IDENTIFIED BY '…';` | `createuser -P x` |
| give it access | `GRANT ALL ON x.* TO 'x'@'127.0.0.1';` | `CREATE DATABASE x OWNER x;` |
| list databases | `SHOW DATABASES;` | `\l` |
| dump everything | `mysqldump -u root -p --all-databases > all.sql` | `pg_dumpall > all.sql` |

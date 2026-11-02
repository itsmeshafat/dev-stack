# Dev Stack — Help

## Quick start
Start or stop everything — or a single module — with the buttons in the main window, or from a terminal.

```
devstack status
devstack start | stop | restart [module]
devstack doctor
```

## Add a new project
1. Put the project anywhere (e.g. ~/Sites/myapp).
2. Register it — interactively, or add one line to ~/.config/devstack/sites.conf.

```
devstack add-site

# host | docroot | php | kind | aliases
myapp.test | ~/Sites/myapp/public | 8.5 | laravel
```

3. Apply and verify.

```
devstack sync
devstack doctor
```

## Point an existing project here
Nothing is moved or copied. Add one line pointing at its document root and run devstack sync — that is all.

## Which folder is the document root?
| Project type | Docroot |
|---|---|
| Laravel / Symfony | <project>/public |
| WordPress | the folder containing wp-config.php |
| Plain PHP / legacy | the folder containing index.php |
| Root .htaccess forwarding to public/ | the project root |

The "kind" column only controls what SSL toggling rewrites: Laravel APP_URL, WordPress siteurl/home.

## Updates
The app checks for a newer release at launch and shows an Update banner (Update now · Release notes ·
Dismiss). You can also check manually from the app menu (⌘U).

```
devstack update --check
devstack update
devstack update --rollback
```

An update replaces only the app code and the app bundle — plus the privileged helper only if it changed
(one admin prompt). Sites, config, certificates, hosts and running services are never touched.

## Commands
| Command | Does |
|---|---|
| devstack status | every module and its state |
| devstack start / stop / restart [module] | control all modules, or one |
| devstack sites | list configured sites |
| devstack add-site | add a site interactively |
| devstack sync | regenerate vhosts + /etc/hosts, reload |
| devstack composer --site HOST | run Composer with the site's PHP |
| devstack ssl enable / disable | trusted HTTPS for all sites |
| devstack doctor | verify services, configs, sites |

## Looks broken?
| Symptom | Fix |
|---|---|
| 502 Bad Gateway | Apache is down — devstack start apache |
| 404 on :80 but works on :8081 | stale vhosts — devstack sync |
| Site name doesn't resolve | hosts entry missing — devstack sync |
| Wrong PHP version | fix the php column, then devstack sync |
| A module won't start | the console shows the underlying brew error |

## Disclaimer
This is a local development tool, provided as-is with no warranty (MIT license). It **does not back up your
databases or project files** — keep your own dumps and use version control. Its automatic backups cover only
the configuration it rewrites, under `~/.local/share/devstack/backups/`.

## Where things live
| What | Path |
|---|---|
| sites | ~/.config/devstack/sites.conf |
| settings | ~/.config/devstack/config |
| activity log | ~/.local/share/devstack/devstack.log |
| config backups | ~/.local/share/devstack/backups/ |

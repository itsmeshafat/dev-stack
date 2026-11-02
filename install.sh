#!/usr/bin/env bash
# dev-stack installer — safe, idempotent, dry-run capable.
#
#   ./install.sh [--dry-run] [--yes] [--no-brew] [--helper-only] [--app-only] [--uninstall]
#
# What it does:
#   preflight -> backup -> brew formulae -> php-fpm sockets -> vhosts
#   -> nginx/apache config -> install CLI + privileged helper -> build app -> summary
set -uo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"; SOURCE="$(readlink "$SOURCE")"; [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
PKG_ROOT="$(cd -P "$(dirname "$SOURCE")" && pwd)"

. "$PKG_ROOT/lib/common.sh"
. "$PKG_ROOT/lib/modules.sh"
. "$PKG_ROOT/lib/sites.sh"
. "$PKG_ROOT/lib/ssl.sh"
. "$PKG_ROOT/lib/hosts.sh"

# respect the user's existing settings (ports, SSL) so a reinstall never downgrades config
load_config

INSTALL_PKG="$DEVSTACK_HOME/pkg"
CLI_LINK="$HOME/.local/bin/devstack"
HELPER_DST="/usr/local/sbin/devstack-web"
SUDOERS_DST="/etc/sudoers.d/devstack"

DO_BREW=1; DO_APP=1; DO_MAIN=1; DO_HELPER=1; DO_SSL=0; ASSUME_YES=0
for a in "$@"; do case "$a" in
  --dry-run)     DRY_RUN=1 ;;
  --yes|-y)      ASSUME_YES=1 ;;
  --no-brew)     DO_BREW=0 ;;
  --no-helper)   DO_HELPER=0 ;;
  --ssl)         DO_SSL=1 ;;
  --helper-only) DO_MAIN=0; DO_BREW=0; DO_APP=0 ;;
  --app-only)    DO_MAIN=0; DO_BREW=0; DO_HELPER=0 ;;
  --uninstall)   exec "$PKG_ROOT/uninstall.sh" "${@:2}" ;;
  -h|--help)     sed -n '2,12p' "$0"; exit 0 ;;
  *) die "unknown option: $a" ;;
esac; done

BACKUP_TS="$(timestamp)"
export BACKUP_TS
ensure_dirs

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$DRY_RUN" = 1 ] && return 0
  local ans; read -r -p "$1 [y/N] " ans; case "$ans" in y|Y|yes) return 0;; *) return 1;; esac
}

# ---------------------------------------------------------------- preflight
preflight() {
  info "preflight"
  [ "$(uname -s)" = "Darwin" ] || die "dev-stack targets macOS only"
  note "macOS $(sw_vers -productVersion) · $(uname -m)"
  if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    warn "Xcode Command Line Tools missing — the app build needs them."
    note "install with:  xcode-select --install"
    [ "$DO_APP" = 1 ] && die "cannot build the app without Command Line Tools (use --no-app to skip)"
  fi
  if ! command -v brew >/dev/null 2>&1 && [ ! -x "$BREW" ]; then
    warn "Homebrew not found at $HOMEBREW_PREFIX"
    confirm "Install Homebrew now?" || die "Homebrew is required"
    if [ "$DRY_RUN" = "1" ]; then
      printf '  \033[2m[dry-run]\033[0m install Homebrew\n'
    else
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
  fi
  ok "preflight passed (brew: $HOMEBREW_PREFIX, user: $DEV_USER)"
}

# ---------------------------------------------------------------- backups
backup_all() {
  info "backing up existing config to $DEVSTACK_BACKUP_DIR/$BACKUP_TS"
  backup_file /etc/hosts
  backup_file "$HOMEBREW_PREFIX/etc/nginx"
  backup_file "$HOMEBREW_PREFIX/etc/httpd"
  for v in 8.5 8.3 7.4; do backup_file "$HOMEBREW_PREFIX/etc/php/$v/php-fpm.d/www.conf"; done
  ok "backups written"
}

# ---------------------------------------------------------------- formulae
install_formulae() {
  [ "$DO_BREW" = 1 ] || { info "skipping Homebrew formulae (--no-brew)"; return; }
  info "Homebrew formulae"
  local f
  for f in nginx httpd mysql@8.4 postgresql@18 redis mailpit php php@8.3 php@7.4 composer wp-cli mkcert; do
    if "$BREW" list --versions "$f" >/dev/null 2>&1; then note "present: $f"; else
      note "installing: $f"; run "$BREW" install "$f"
    fi
  done
  ok "formulae ready (link mysql@8.4 so 'mysql' resolves)"
  run "$BREW" link --force mysql@8.4 >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- php-fpm
configure_php_fpm() {
  info "php-fpm sockets"
  local v f soc
  for v in 8.5 8.3 7.4; do
    f="$HOMEBREW_PREFIX/etc/php/$v/php-fpm.d/www.conf"
    soc="$(phpver_socket "$v")"
    [ -f "$f" ] || { note "skip php $v (no conf)"; continue; }
    if [ "$DRY_RUN" = "1" ]; then printf '  \033[2m[dry-run]\033[0m set php %s listen = %s\n' "$v" "$soc"; else
      sed -i '' -E "s#^listen = .*#listen = $soc#" "$f"
      sed -i '' -E "/^listen\.owner/d; /^listen\.group/d; /^listen\.mode/d" "$f"
      printf 'listen.owner = %s\nlisten.group = %s\nlisten.mode = 0666\n' "$DEV_USER" "$DEV_GROUP" >> "$f"
      note "php $v -> $soc"
    fi
  done
  ok "php-fpm configured"
}

# ---------------------------------------------------------------- web configs
write_nginx_conf() {
  info "nginx config ($HOMEBREW_PREFIX/etc/nginx/nginx.conf)"
  local t="$HOMEBREW_PREFIX/etc/nginx/nginx.conf"
  if [ "$DRY_RUN" = "1" ]; then printf '  \033[2m[dry-run]\033[0m write %s (listen %s)\n' "$t" "$NGINX_PORT"; return; fi
  mkdir -p "$HOMEBREW_PREFIX/var/log/nginx"
  cat > "$t" <<EOF
user $DEV_USER $DEV_GROUP;
worker_processes auto;
error_log $HOMEBREW_PREFIX/var/log/nginx-error.log warn;
pid /tmp/devstack-nginx.pid;
events { worker_connections 1024; }
http {
    include       $HOMEBREW_PREFIX/etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile on; tcp_nopush on; keepalive_timeout 65;
    types_hash_max_size 2048; client_max_body_size 256M; server_names_hash_bucket_size 64;
    gzip on; gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;
    server { listen ${NGINX_PORT} default_server; server_name _; return 404; }
    include $NGINX_SERVERS_DIR/*.conf;
}
EOF
  ok "nginx.conf written"
}

write_apache_conf() {
  info "Apache config ($HOMEBREW_PREFIX/etc/httpd/httpd.conf)"
  local t="$HOMEBREW_PREFIX/etc/httpd/httpd.conf" m="$HOMEBREW_PREFIX/lib/httpd/modules"
  if [ "$DRY_RUN" = "1" ]; then printf '  \033[2m[dry-run]\033[0m write %s (listen %s)\n' "$t" "$APACHE_PORT"; return; fi
  mkdir -p "$HOMEBREW_PREFIX/var/log/httpd" "$HOMEBREW_PREFIX/var/run" "$HTTPD_VHOSTS_DIR"
  cat > "$t" <<EOF
# dev-stack managed Apache config — regenerated by install.sh
ServerRoot "$HOMEBREW_PREFIX/opt/httpd"
Listen 127.0.0.1:${APACHE_PORT}
ServerName 127.0.0.1:${APACHE_PORT}
PidFile "$HOMEBREW_PREFIX/var/run/httpd.pid"
ErrorLog "$HOMEBREW_PREFIX/var/log/httpd/error_log"
LogLevel warn
LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\"" combined
TypesConfig "$HOMEBREW_PREFIX/etc/httpd/mime.types"
User $DEV_USER
Group $DEV_GROUP

$(for mod in mpm_event authn_core authz_host authz_core access_compat filter deflate mime log_config env expires headers setenvif version proxy proxy_http proxy_fcgi unixd dir alias rewrite; do
  echo "LoadModule ${mod}_module lib/httpd/modules/mod_${mod}.so"; done)

DocumentRoot "$HOMEBREW_PREFIX/var/www"
<Directory "$HOMEBREW_PREFIX/var/www">
    AllowOverride None
    Require all granted
</Directory>
<IfModule dir_module>
    DirectoryIndex index.php index.html index.htm
</IfModule>
<FilesMatch "^\.([Hh][Tt]|[Dd][Ss]_[Ss])">
    Require all denied
</FilesMatch>

IncludeOptional $HTTPD_VHOSTS_DIR/*.conf
EOF
  ok "httpd.conf written"
}

# ---------------------------------------------------------------- validation
validate_configs() {
  info "validating configs"
  local out
  out="$("$NGINX_BIN" -t 2>&1 || true)"
  if printf '%s' "$out" | grep -q 'syntax is ok'; then ok "nginx config valid"; else warn "nginx config problem:"; printf '%s\n' "$out" | tail -6; fi
  out="$("$APACHE_BIN" -t 2>&1 || true)"
  if printf '%s' "$out" | grep -q 'Syntax OK'; then ok "apache config valid"; else warn "apache config problem:"; printf '%s\n' "$out" | tail -6; fi
}

restart_php() {
  info "restarting php-fpm"
  local v; for v in 8.5 8.3 7.4; do run "$BREW" services restart "$(phpver_formula "$v")" >/dev/null 2>&1 || true; done
}

restart_apache() {
  info "restarting Apache"
  run "$BREW" services restart httpd >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- helper + cli
install_helper() {
  info "privileged helper (/usr/local/sbin/devstack-web)"
  if [ "$DRY_RUN" = "1" ]; then
    printf '  \033[2m[dry-run]\033[0m install helper + sudoers for %s\n' "$DEV_USER"; return
  fi
  note "macOS will ask for your password once"
  sudo bash "$PKG_ROOT/bin/install-helper-root" "$DEV_USER" "$PKG_ROOT" || die "helper install failed"
  ok "helper + scoped sudo rule installed"
}

install_cli() {
  info "installing CLI"
  run mkdir -p "$INSTALL_PKG" "$HOME/.local/bin"
  if [ "$DRY_RUN" = "1" ]; then printf '  \033[2m[dry-run]\033[0m copy package -> %s ; link %s\n' "$INSTALL_PKG" "$CLI_LINK"; return; fi
  rm -rf "$INSTALL_PKG"; mkdir -p "$INSTALL_PKG"
  cp -R "$PKG_ROOT/lib" "$PKG_ROOT/bin" "$PKG_ROOT/app" "$PKG_ROOT/config" "$INSTALL_PKG/" 2>/dev/null || true
  cp "$PKG_ROOT/install.sh" "$PKG_ROOT/uninstall.sh" "$INSTALL_PKG/" 2>/dev/null || true
  chmod 0755 "$INSTALL_PKG/bin/"* 2>/dev/null || true
  ln -sfn "$INSTALL_PKG/bin/devstack" "$CLI_LINK"
  ok "CLI: $CLI_LINK"
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "add ~/.local/bin to PATH to use 'devstack'" ;; esac
}

seed_sites() {
  if [ -f "$DEVSTACK_SITES_CONF" ]; then note "sites.conf already present"; return; fi
  run cp "$PKG_ROOT/config/sites.conf.example" "$DEVSTACK_SITES_CONF"
  note "created $DEVSTACK_SITES_CONF (edit it, then: devstack restart web)"
}

build_app() {
  info "building the app"
  if [ -x "$PKG_ROOT/app/build-app.sh" ]; then run bash "$PKG_ROOT/app/build-app.sh"; else note "app/build-app.sh not found; skipping"; fi
}

summary() {
  echo
  ok "dev-stack $DEVSTACK_VERSION installed"
  note "config:   $DEVSTACK_SITES_CONF"
  note "backups:  $DEVSTACK_BACKUP_DIR/$BACKUP_TS"
  note "next:     devstack doctor    (verify)   |   devstack start (bring it up)"
  note "uninstall: $PKG_ROOT/uninstall.sh"
}

# ---------------------------------------------------------------- run
echo "dev-stack installer v$DEVSTACK_VERSION  (dry-run=$DRY_RUN)"
preflight
if [ "$DO_MAIN" = 1 ]; then
  backup_all
  install_formulae
  configure_php_fpm
  restart_php
  seed_sites
  if [ "$DO_SSL" = 1 ]; then
    info "enabling HTTPS (mkcert)"
    ssl_install_ca
    ssl_issue_cert
    set_config SSL 1
    SSL=1
  fi
  sites_sync
  write_nginx_conf
  write_apache_conf
  # remove a legacy hosts block from an older dev-stack if present (non-interactive)
  [ "$DRY_RUN" = "1" ] || sudo -n sed -i '' '/# devstack-hosts-begin/,/# devstack-hosts-end/d' /etc/hosts 2>/dev/null || true
  validate_configs
  restart_apache
fi
[ "$DO_HELPER" = 1 ] && install_helper
if [ "$DO_MAIN" = 1 ]; then install_cli; fi
[ "$DO_APP" = 1 ] && build_app
summary

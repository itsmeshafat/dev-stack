#!/usr/bin/env bash
# lib/phpmyadmin.sh — optional phpMyAdmin provisioning for the dev stack.
#
# Downloads phpMyAdmin, verifies the published SHA-256, installs it under ~/Sites/phpmyadmin,
# writes a config.inc.php using *cookie* auth (no password is stored) and registers
# phpmyadmin.test. Never overwrites an install dev-stack did not create unless forced.

PMA_DIR="${PMA_DIR:-$HOME/Sites/phpmyadmin}"
PMA_VERSION_URL="${PMA_VERSION_URL:-https://www.phpmyadmin.net/home_page/version.json}"
PMA_FILES_BASE="${PMA_FILES_BASE:-https://files.phpmyadmin.net/phpMyAdmin}"
PMA_TMP="${PMA_TMP:-$DEVSTACK_HOME/phpmyadmin-tmp}"
PMA_MARKER=".devstack-pma"
# phpMyAdmin 5.2.x supports PHP >=7.2,<8.4 — so it runs on 8.3, not on the 8.5 default.
PMA_PHP="${PMA_PHP:-8.3}"
PMA_HOST="${PMA_HOST:-phpmyadmin.test}"

pma_marker()     { printf '%s/%s' "$PMA_DIR" "$PMA_MARKER"; }
pma_installed()  { [ -f "$PMA_DIR/index.php" ] && [ -f "$PMA_DIR/config.inc.php" ]; }
pma_managed()    { [ -f "$(pma_marker)" ]; }
pma_version()    { [ -f "$(pma_marker)" ] && tr -d ' \n' < "$(pma_marker)" 2>/dev/null; }
pma_registered() { sites_rows 2>/dev/null | awk -F'\t' -v h="$PMA_HOST" '$1==h{f=1} END{exit !f}'; }

pma_latest_version() {
  local json
  json="$(/usr/bin/curl -fsSL --max-time 15 "$PMA_VERSION_URL" 2>/dev/null)" || return 1
  printf '%s' "$json" | sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

pma_reload_web() {
  if sudo -n "${HELPER:-/usr/local/sbin/devstack-web}" start >/dev/null 2>&1; then ok "nginx reloaded"; else warn "reload nginx manually: devstack restart web"; fi
}

pma_status() {
  info "phpMyAdmin"
  if pma_installed; then
    if pma_managed; then ok "installed by dev-stack: v$(pma_version) at $PMA_DIR"; else warn "found at $PMA_DIR, but not installed by dev-stack (left untouched)"; fi
  else
    note "not installed — add it with:  devstack phpmyadmin install"
  fi
  if pma_registered; then ok "site $PMA_HOST is registered"; else note "site $PMA_HOST is not registered yet"; fi
  if pma_installed; then note "url: $(ssl_enabled && echo https || echo http)://$PMA_HOST"; fi
}

pma_install() {
  local force="${1:-0}"
  info "phpMyAdmin setup"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '  \033[2m[dry-run]\033[0m download the latest phpMyAdmin -> %s ; write config.inc.php (cookie auth) ; register %s\n' "$PMA_DIR" "$PMA_HOST"
    return 0
  fi

  if pma_installed && ! pma_managed && [ "$force" != "1" ]; then
    die "$PMA_DIR already holds a phpMyAdmin that dev-stack did not install.
  Refusing to overwrite it — its config.inc.php may hold credentials you still need.
  Move it aside yourself, or re-run with --force to have it backed up automatically."
  fi

  local ver; ver="$(pma_latest_version)"
  [ -n "$ver" ] || die "could not read the current version from $(printf '%s' "$PMA_VERSION_URL" | sed 's#^https\?://##; s#/.*##') (no network?)"
  note "latest: phpMyAdmin $ver"

  local ts; ts="$(timestamp)"
  local tmp="$DEVSTACK_HOME/.pma-tmp-$ts"
  local tarball="phpMyAdmin-$ver-all-languages.tar.gz"
  local url="$PMA_FILES_BASE/$ver/$tarball"
  mkdir -p "$tmp"

  info "downloading phpMyAdmin $ver"
  /usr/bin/curl -fsSL --max-time 300 -o "$tmp/$tarball" "$url" || { rm -rf "$tmp"; die "download failed: $url"; }

  local want have
  want="$(/usr/bin/curl -fsSL --max-time 20 "$url.sha256" 2>/dev/null | awk '{print $1}' | head -1)"
  if [ -n "$want" ]; then
    have="$(/usr/bin/shasum -a 256 "$tmp/$tarball" | awk '{print $1}')"
    [ "$want" = "$have" ] || { rm -rf "$tmp"; die "checksum mismatch for phpMyAdmin $ver (expected $want, got $have)"; }
    ok "SHA-256 verified"
  else
    warn "checksum could not be fetched — continuing unverified"
  fi

  /usr/bin/tar -xzf "$tmp/$tarball" -C "$tmp" || { rm -rf "$tmp"; die "extract failed"; }
  local src; src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'phpMyAdmin-*' | head -1)"
  [ -n "$src" ] && [ -f "$src/index.php" ] || { rm -rf "$tmp"; die "unexpected archive layout"; }

  mkdir -p "$(dirname "$PMA_DIR")"
  if [ -e "$PMA_DIR" ]; then
    local bak="$PMA_DIR.devstack-backup-$ts"
    note "moving the previous install aside: $bak"
    mv "$PMA_DIR" "$bak" || { rm -rf "$tmp"; die "could not move $PMA_DIR aside"; }
  fi
  mv "$src" "$PMA_DIR" || { rm -rf "$tmp"; die "could not move phpMyAdmin into place"; }
  rm -rf "$tmp"

  info "writing config.inc.php (cookie auth — nothing is stored)"
  mkdir -p "$PMA_TMP"; chmod 0700 "$PMA_TMP"
  local secret; secret="$(/usr/bin/openssl rand -base64 32 | tr -d '\n')"
  cat > "$PMA_DIR/config.inc.php" <<PHP
<?php
// Written by dev-stack. Authentication is "cookie": log in with a MySQL account each time,
// so no database password is kept on disk.
\$cfg['blowfish_secret'] = '$secret';

\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = '127.0.0.1';
\$cfg['Servers'][\$i]['port'] = '${MYSQL_PORT:-3306}';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['TempDir'] = '$PMA_TMP';
PHP
  chmod 0644 "$PMA_DIR/config.inc.php"
  printf '%s\n' "$ver" > "$(pma_marker)"
  ok "phpMyAdmin $ver installed at $PMA_DIR"

  if [ "${PMA_SKIP_SYNC:-0}" = "1" ]; then
    note "site registration + sync skipped (PMA_SKIP_SYNC=1)"
    return 0
  fi

  if pma_registered; then
    note "site $PMA_HOST already registered (php $PMA_PHP)"
  else
    mkdir -p "$DEVSTACK_CONFIG_DIR"
    printf '%s | %s | %s | %s\n' "$PMA_HOST" "$PMA_DIR" "$PMA_PHP" "php" >> "$DEVSTACK_SITES_CONF"
    ok "registered $PMA_HOST -> $PMA_DIR (php $PMA_PHP)"
  fi
  sites_sync
  pma_reload_web
  ok "phpMyAdmin ready: https://$PMA_HOST  (log in with a MySQL account)"
}

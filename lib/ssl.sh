#!/usr/bin/env bash
# lib/ssl.sh — trusted TLS for *.test sites via mkcert. Sourced.

MKCERT="$(command -v mkcert 2>/dev/null || true)"
[ -n "$MKCERT" ] || MKCERT="$HOMEBREW_PREFIX/bin/mkcert"
WP_BIN="$HOMEBREW_PREFIX/bin/wp"
OPENSSL="$HOMEBREW_PREFIX/bin/openssl"; [ -x "$OPENSSL" ] || OPENSSL=/usr/bin/openssl

# Path to the mkcert root CA (for curl --cacert, since Homebrew curl doesn't use the keychain)
ssl_cacert() { [ -x "$MKCERT" ] && printf '%s' "$("$MKCERT" -CAROOT 2>/dev/null)/rootCA.pem"; }

# Is mkcert's local CA present AND trusted in the keychain?
ssl_ca_ok() {
  [ -x "$MKCERT" ] || return 1
  local caroot; caroot="$("$MKCERT" -CAROOT 2>/dev/null)" || return 1
  [ -f "$caroot/rootCA.pem" ] || return 1
  /usr/bin/security find-certificate -a -c "mkcert" >/dev/null 2>&1
}

ssl_install_ca() {
  [ -x "$MKCERT" ] || die "mkcert not installed — run ./install.sh"
  if ssl_ca_ok; then ok "mkcert CA already trusted"; return 0; fi
  info "installing mkcert local CA (needs admin)"
  if [ "$DRY_RUN" = "1" ]; then printf '  \033[2m[dry-run]\033[0m mkcert -install\n'; return 0; fi
  if [ -t 0 ]; then
    "$MKCERT" -install
  else
    /usr/bin/osascript -e "do shell script \"$MKCERT -install\" with administrator privileges" >/dev/null
  fi
}

# Every SAN we need: wildcard + each host + each alias (aliases may be two-level, e.g. www.foo.test)
ssl_sans() {
  printf '%s\n' "*.test" "test"
  sites_rows | while IFS=$'\t' read -r host docroot php kind aliases; do
    printf '%s\n' "$host"
    [ -n "$aliases" ] && printf '%s\n' "$aliases" | tr ',' '\n'
  done | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'
}

ssl_issue_cert() {
  [ -x "$MKCERT" ] || die "mkcert not installed"
  if [ "$DRY_RUN" = "1" ]; then printf '  \033[2m[dry-run]\033[0m mkcert *.test (re)issue\n'; return 0; fi
  mkdir -p "$DEVSTACK_CERT_DIR"
  local sans; sans="$(ssl_sans | sort -u)"
  # shellcheck disable=SC2086
  "$MKCERT" -cert-file "$DEVSTACK_CERT" -key-file "$DEVSTACK_CERT_KEY" $sans >/dev/null 2>&1 \
    || die "mkcert failed to issue a certificate"
  chmod 600 "$DEVSTACK_CERT_KEY" 2>/dev/null || true
  ok "issued cert ($(printf '%s\n' "$sans" | wc -l | tr -d ' ') SANs) → $DEVSTACK_CERT"
}

# Rewrite app URLs to https/http for laravel (.env APP_URL) and wp (siteurl/home)
ssl_app_urls() {
  local scheme="$1" host docroot php kind aliases proj
  sites_rows | while IFS=$'\t' read -r host docroot php kind aliases; do
    proj="$docroot"
    [ "$(basename "$docroot")" = "public" ] && proj="$(dirname "$docroot")"
    case "$kind" in
      laravel)
        [ -f "$proj/.env" ] || continue
        if [ "$DRY_RUN" = "1" ]; then printf '  \033[2m[dry-run]\033[0m APP_URL %s -> %s://%s\n' "$host" "$scheme" "$host"; continue; fi
        backup_file "$proj/.env"
        if grep -q '^APP_URL=' "$proj/.env" 2>/dev/null; then
          sed -i '' -E "s#^APP_URL=.*#APP_URL=${scheme}://${host}#" "$proj/.env"
        else
          printf 'APP_URL=%s://%s\n' "$scheme" "$host" >> "$proj/.env"
        fi
        echo "  APP_URL $host → $scheme"
        ;;
      wp)
        [ -x "$WP_BIN" ] || continue
        [ -f "$docroot/wp-config.php" ] || continue
        if [ "$DRY_RUN" = "1" ]; then printf '  \033[2m[dry-run]\033[0m wp siteurl %s -> %s://%s\n' "$host" "$scheme" "$host"; continue; fi
        "$WP_BIN" --path="$docroot" --skip-themes --skip-plugins option update home    "$scheme://$host" >/dev/null 2>&1 || true
        "$WP_BIN" --path="$docroot" --skip-themes --skip-plugins option update siteurl "$scheme://$host" >/dev/null 2>&1 || true
        echo "  WP siteurl $host → $scheme"
        ;;
      *) : ;;  # php / legacy: leave application config untouched
    esac
  done
}

ssl_summary() {
  local state="disabled"; ssl_enabled && state="enabled"
  printf '%s' "$state"
}

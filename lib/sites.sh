#!/usr/bin/env bash
# lib/sites.sh — parse ~/.config/devstack/sites.conf and generate vhosts. Sourced.
#
# sites.conf line format (pipe separated; 'kind' and 'aliases' optional):
#   host | docroot | php | kind | alias1,alias2
#   casepilot.test | ~/Developer/CasePilot/public | 8.3 | laravel
#   wptest.test    | ~/Sites/wptest              | 8.5 | wp
# '#' starts a comment. Blank lines ignored.

NGINX_SERVERS_DIR="$HOMEBREW_PREFIX/etc/nginx/servers"
HTTPD_VHOSTS_DIR="$HOMEBREW_PREFIX/etc/httpd/vhosts"

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
expand_tilde() { case "$1" in "~"|"~/"*) printf '%s%s' "$HOME" "${1#\~}" ;; *) printf '%s' "$1" ;; esac; }

# Echo normalized, tab-separated rows: host \t docroot \t php \t kind \t aliases
sites_rows() {
  [ -f "$DEVSTACK_SITES_CONF" ] || return 0
  while IFS='|' read -r host docroot php kind aliases; do
    host="$(trim "${host:-}")"
    [ -z "$host" ] && continue
    case "$host" in \#*) continue ;; esac
    # validate the hostname charset — prevents config//etc/hosts injection
    case "$host" in
      .*|*[!A-Za-z0-9.-]*) warn "sites.conf: skipping invalid host '$host'"; continue ;;
    esac
    docroot="$(trim "${docroot:-}" | tr -d '\r\n')"
    case "$docroot" in
      *'"'*|*';'*) warn "sites.conf: skipping $host (invalid docroot)"; continue ;;
    esac
    php="$(trim "${php:-}")"; [ -z "$php" ] && php="8.5"
    case "$php" in *[!0-9.]*) php="8.5" ;; esac
    kind="$(trim "${kind:-}")"; [ -z "$kind" ] && kind="php"
    # sanitize aliases: keep only valid hostnames
    aliases="$(trim "${aliases:-}")"
    if [ -n "$aliases" ]; then
      local clean="" a
      for a in $(printf '%s' "$aliases" | tr ',' ' '); do
        case "$a" in .*|*[!A-Za-z0-9.-]*) continue ;; esac
        clean="${clean:+$clean,}$a"
      done
      aliases="$clean"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$host" "$(expand_tilde "$docroot")" "$php" "$kind" "$aliases"
  done < "$DEVSTACK_SITES_CONF"
}

sites_hosts() {
  sites_rows | while IFS=$'\t' read -r host docroot php kind aliases; do
    printf '%s\n' "$host"
    if [ -n "$aliases" ]; then
      printf '%s\n' "$aliases" | tr ',' '\n' | while read -r a; do
        a="$(trim "$a")"; [ -n "$a" ] && printf '%s\n' "$a"
      done
    fi
  done
}

_nginx_write() {
  local host="$1" aliases="$2" file="$NGINX_SERVERS_DIR/$host.conf"
  local names="$host"
  [ -n "$aliases" ] && names="$host $(printf '%s' "$aliases" | tr ',' ' ')"

  if ssl_enabled; then
    cat > "$file" <<NGINX
server {
    listen ${NGINX_PORT};
    server_name $names;
    return 301 https://\$host\$request_uri;
}
server {
    listen ${SSL_PORT} ssl;
    http2 on;
    server_name $names;
    ssl_certificate     "$DEVSTACK_CERT";
    ssl_certificate_key "$DEVSTACK_CERT_KEY";
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    location / {
        proxy_pass http://127.0.0.1:${APACHE_PORT};
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 120s;
    }
}
NGINX
    return
  fi

  {
    echo "server {"
    echo "    listen ${NGINX_PORT};"
    if [ -n "$aliases" ]; then
      echo "    server_name $host $(printf '%s' "$aliases" | tr ',' ' ');"
    else
      echo "    server_name $host;"
    fi
    echo "    location / {"
    echo "        proxy_pass http://127.0.0.1:${APACHE_PORT};"
    echo "        proxy_set_header Host              \$host;"
    echo "        proxy_set_header X-Real-IP         \$remote_addr;"
    echo "        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;"
    echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "        proxy_read_timeout 120s;"
    echo "    }"
    echo "}"
  } > "$file"
}

_apache_write() {
  local host="$1" docroot="$2" php="$3" aliases="$4" file="$HTTPD_VHOSTS_DIR/$host.conf"
  local sock; sock="$(phpver_socket "$php")"
  {
    echo "<VirtualHost *:${APACHE_PORT}>"
    echo "    ServerName $host"
    [ -n "$aliases" ] && echo "    ServerAlias $(printf '%s' "$aliases" | tr ',' ' ')"
    echo "    DocumentRoot \"$docroot\""
    echo "    <Directory \"$docroot\">"
    echo "        Options -Indexes +FollowSymLinks"
    echo "        AllowOverride All"
    echo "        Require all granted"
    echo "    </Directory>"
    echo "    DirectoryIndex index.php index.html index.htm"
    echo "    ErrorLog \"$HOMEBREW_PREFIX/var/log/httpd/$host-error.log\""
    echo "    CustomLog \"$HOMEBREW_PREFIX/var/log/httpd/$host-access.log\" combined"
    echo "    <FilesMatch \\.php\$>"
    echo "        SetHandler \"proxy:unix:$sock|fcgi://localhost\""
    echo "    </FilesMatch>"
    echo "</VirtualHost>"
  } > "$file"
}

# sites_sync — (re)generate nginx + apache vhosts for every configured site.
sites_sync() {
  run mkdir -p "$NGINX_SERVERS_DIR" "$HTTPD_VHOSTS_DIR"
  # ensure the wildcard cert covers any newly added hosts
  if ssl_enabled && [ "$DRY_RUN" != "1" ] && [ ! -f "$DEVSTACK_CERT" ]; then
    ssl_issue_cert
  fi
  # remove previously generated ones (tracked via .devstack-generated marker files)
  if [ "$DRY_RUN" != "1" ]; then
    find "$NGINX_SERVERS_DIR" -name '*.conf' -exec grep -lq 'proxy_pass http://127.0.0.1:' {} \; -delete 2>/dev/null || true
    rm -f "$HTTPD_VHOSTS_DIR"/*.conf 2>/dev/null || true
  fi
  sites_rows | while IFS=$'\t' read -r host docroot php kind aliases; do
    if [ "$DRY_RUN" = "1" ]; then
      printf '  \033[2m[dry-run]\033[0m vhost %-20s -> %s (php %s)\n' "$host" "$docroot" "$php"
      continue
    fi
    _nginx_write  "$host" "$aliases"
    _apache_write "$host" "$docroot" "$php" "$aliases"
    printf '  vhost %-22s -> %s (php %s)\n' "$host" "$docroot" "$php"
  done
}

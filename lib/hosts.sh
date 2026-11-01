#!/usr/bin/env bash
# lib/hosts.sh — managed /etc/hosts block (no DNS daemon needed). Sourced.
# Used by bin/devstack-web (runs as root).

HOSTS_FILE="/etc/hosts"
HOSTS_BEGIN="# devstack-begin"
HOSTS_END="# devstack-end"

# All server_name values declared by the generated nginx vhosts.
hosts_names() {
  grep -hE '^[[:space:]]*server_name' "$NGINX_SERVERS_DIR"/*.conf 2>/dev/null \
    | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;//g' \
    | tr ' ' '\n' \
    | grep -E '^[A-Za-z0-9][A-Za-z0-9._-]*$' \
    | sort -u
}

# hosts_sync — rewrite the managed block from current nginx vhosts.
hosts_sync() {
  local names; names="$(hosts_names)"
  [ -n "$names" ] || { warn "no nginx server_name found; leaving /etc/hosts unchanged"; return 0; }

  sed -i '' "/$HOSTS_BEGIN/,/$HOSTS_END/d" "$HOSTS_FILE" 2>/dev/null || true
  {
    echo "$HOSTS_BEGIN"
    while read -r n; do [ -n "$n" ] && echo "127.0.0.1 $n"; done <<< "$names"
    echo "$HOSTS_END"
  } >> "$HOSTS_FILE"
  ok "synced /etc/hosts ($(echo "$names" | wc -l | tr -d ' ') names)"
}

# hosts_remove — drop the managed block entirely.
hosts_remove() {
  sed -i '' "/$HOSTS_BEGIN/,/$HOSTS_END/d" "$HOSTS_FILE" 2>/dev/null || true
}

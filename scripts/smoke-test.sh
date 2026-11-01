#!/usr/bin/env bash
# smoke-test.sh — post-install verification. Non-destructive.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/lib/common.sh"
. "$HERE/lib/modules.sh"
. "$HERE/lib/sites.sh"
. "$HERE/lib/ssl.sh"
load_config

pass=0; fail=0
chk() { if eval "$2" >/dev/null 2>&1; then printf '  \033[1;32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); else printf '  \033[1;31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); fi; }
chk_out() { local out; out="$(eval "$2" 2>&1 || true)"; case "$out" in *"$3"*) printf '  \033[1;32m✓\033[0m %s\n' "$1"; pass=$((pass+1));; *) printf '  \033[1;31m✗\033[0m %s\n' "$1"; fail=$((fail+1));; esac; }

echo "== modules =="
for m in $MODULES_ALL; do chk "$m running" "[ \"\$(module_state $m)\" = running ]"; done

echo "== ports =="
chk "nginx :$NGINX_PORT"  "lsof -nP -iTCP:$NGINX_PORT -sTCP:LISTEN"
chk "apache :$APACHE_PORT" "lsof -nP -iTCP:$APACHE_PORT -sTCP:LISTEN"
chk "mysql :3306"   "lsof -nP -iTCP:3306 -sTCP:LISTEN"
chk "postgres :5432" "lsof -nP -iTCP:5432 -sTCP:LISTEN"
chk "redis :6379"   "lsof -nP -iTCP:6379 -sTCP:LISTEN"

echo "== config syntax =="
chk_out "nginx config valid"  "\"$NGINX_BIN\" -t"  "syntax is ok"
chk_out "apache config valid" "\"$APACHE_BIN\" -t" "Syntax OK"

echo "== helper =="
chk "/usr/local/sbin/devstack-web" "[ -x /usr/local/sbin/devstack-web ]"

echo "== ssl =="
if ssl_enabled; then
  chk "listening :$SSL_PORT" "lsof -nP -iTCP:$SSL_PORT -sTCP:LISTEN"
  chk "certificate present" "[ -f \"$DEVSTACK_CERT\" ]"
else
  printf '  \033[1;33m!\033[0m ssl disabled\n'
fi

echo "== sites =="
scheme="http"; port="$NGINX_PORT"; cacert=""
if ssl_enabled; then scheme="https"; port="$SSL_PORT"; cacert="$(ssl_cacert)"; fi
if [ -f "$DEVSTACK_SITES_CONF" ]; then
  while IFS=$'\t' read -r host docroot php kind aliases; do
    if [ -n "$cacert" ] && [ -f "$cacert" ]; then
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --cacert "$cacert" --resolve "$host:$port:127.0.0.1" "$scheme://$host:$port/" 2>/dev/null)"
    else
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$host:$port:127.0.0.1" "$scheme://$host:$port/" 2>/dev/null)"
    fi
    case "$code" in 2*|3*) printf '  \033[1;32m✓\033[0m %-22s %s\n' "$host" "$code"; pass=$((pass+1));;
      *) printf '  \033[1;31m✗\033[0m %-22s %s\n' "$host" "${code:-none}"; fail=$((fail+1));; esac
  done < <(sites_rows)
else
  printf '  \033[1;33m!\033[0m no sites.conf\n'
fi

echo
echo "passed: $pass   failed: $fail"
exit "$([ "$fail" = 0 ] && echo 0 || echo 1)"

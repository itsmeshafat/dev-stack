#!/usr/bin/env bash
# lib/modules.sh — the service table. Sourced.

# Order matters: databases/cache first, php-fpm, then apache, then nginx (web).
MODULES_START="mysql postgres redis mail php85 php83 php74 apache"
MODULES_ALL="$MODULES_START web"

# module -> brew formula ("" for the privileged web module)
module_formula() {
  case "$1" in
    mysql)    echo "mysql@8.4" ;;
    postgres) echo "postgresql@18" ;;
    redis)    echo "redis" ;;
    mail)     echo "mailpit" ;;
    php85)    echo "php" ;;
    php83)    echo "php@8.3" ;;
    php74)    echo "php@7.4" ;;
    apache)   echo "httpd" ;;
    *)        return 1 ;;
  esac
}

# module -> human detail line
module_detail() {
  case "$1" in
    mysql)    echo "127.0.0.1:3306" ;;
    postgres) echo "127.0.0.1:5432" ;;
    redis)    echo "127.0.0.1:6379" ;;
    mail)     echo "smtp :1025 / ui :8025" ;;
    php85)    echo "$(phpver_socket 8.5)" ;;
    php83)    echo "$(phpver_socket 8.3)" ;;
    php74)    echo "$(phpver_socket 7.4)" ;;
    apache)   echo "127.0.0.1:${APACHE_PORT}" ;;
    web)      echo "nginx :${NGINX_PORT} (hosts-based DNS)" ;;
    *)        echo "" ;;
  esac
}

# module -> is it running?  prints running|stopped|partial
module_state() {
  local m="$1"
  if [ "$m" = "web" ]; then
    if port_listening "$NGINX_PORT"; then echo running; else echo stopped; fi
    return
  fi
  local f; f="$(module_formula "$m")" || { echo unknown; return; }
  case "$("$BREW" services list 2>/dev/null | awk -v f="$f" '$1==f{print $2; exit}')" in
    started) echo running ;;
    *)       echo stopped ;;
  esac
}

port_listening() { "$LSOF" -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

valid_module() {
  case "$1" in
    mysql|postgres|redis|mail|php85|php83|php74|apache|web) return 0 ;;
    *) return 1 ;;
  esac
}

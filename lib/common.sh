#!/usr/bin/env bash
# lib/common.sh — environment detection, config, logging, dry-run helpers.
# Sourced by bin/devstack, bin/devstack-web and install.sh. Not executed directly.

DEVSTACK_VERSION="1.4.0"

# ---- resolvable paths (all HOME/brew-prefix relative, no machine hardcoding) ----
DEVSTACK_HOME="${DEVSTACK_HOME:-$HOME/.local/share/devstack}"
DEVSTACK_CONFIG_DIR="${DEVSTACK_CONFIG_DIR:-$HOME/.config/devstack}"
DEVSTACK_BACKUP_DIR="$DEVSTACK_HOME/backups"
DEVSTACK_LOG="$DEVSTACK_HOME/devstack.log"
DEVSTACK_SITES_CONF="$DEVSTACK_CONFIG_DIR/sites.conf"
DEVSTACK_CONFIG="$DEVSTACK_CONFIG_DIR/config"

# ---- Homebrew (arm64 /opt/homebrew, intel /usr/local) ----
if command -v brew >/dev/null 2>&1; then
  HOMEBREW_PREFIX="$(brew --prefix)"
elif [ -x /opt/homebrew/bin/brew ]; then
  HOMEBREW_PREFIX="/opt/homebrew"
elif [ -x /usr/local/bin/brew ]; then
  HOMEBREW_PREFIX="/usr/local"
else
  HOMEBREW_PREFIX="/opt/homebrew"
fi
export HOMEBREW_PREFIX
BREW="$HOMEBREW_PREFIX/bin/brew"
if [ -x "$HOMEBREW_PREFIX/sbin/nginx" ]; then NGINX_BIN="$HOMEBREW_PREFIX/bin/nginx"; else NGINX_BIN="$HOMEBREW_PREFIX/bin/nginx"; fi
APACHE_BIN="$HOMEBREW_PREFIX/bin/httpd"
LSOF="/usr/sbin/lsof"

# ---- identity ----
DEV_USER="$(id -un)"
DEV_GROUP="$(id -gn)"

# ---- ports (overridable via ~/.config/devstack/config) ----
NGINX_PORT="${NGINX_PORT:-80}"
APACHE_PORT="${APACHE_PORT:-8081}"
SSL_PORT="${SSL_PORT:-443}"

# ---- TLS / certs ----
SSL="${SSL:-0}"
DEVSTACK_CERT_DIR="$DEVSTACK_HOME/certs"
DEVSTACK_CERT="$DEVSTACK_CERT_DIR/devstack.test.pem"
DEVSTACK_CERT_KEY="$DEVSTACK_CERT_DIR/devstack.test-key.pem"
ssl_enabled() { [ "${SSL:-0}" = "1" ]; }

# ---- php socket namespacing ----
phpver_socket() {  # 8.5 -> /tmp/devstack-php-85.sock
  printf '/tmp/devstack-php-%s.sock' "$(printf '%s' "$1" | tr -d '.')"
}
phpver_formula() { # 8.5 -> php, 8.3 -> php@8.3
  case "$1" in
    8.5|8.5.*) echo "php" ;;
    *) echo "php@$1" ;;
  esac
}

# ---- logging / output ----
DRY_RUN="${DRY_RUN:-0}"
QUIET="${QUIET:-0}"

log() {
  local via gp
  via="$(ps -o comm= -p "${PPID:-0}" 2>/dev/null)"; via="${via##*/}"
  gp="$(ps -o ppid= -p "${PPID:-0}" 2>/dev/null | tr -d ' ')"
  gp="$(ps -o comm= -p "${gp:-0}" 2>/dev/null)"; gp="${gp##*/}"
  printf '%s %s [pid=%s via=%s<%s>]\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" "$$" "${via:-?}" "${gp:-?}" >>"$DEVSTACK_LOG" 2>/dev/null
}
info() { [ "$QUIET" = 1 ] || printf '\033[1;34m▸\033[0m %s\n' "$*"; }
note() { [ "$QUIET" = 1 ] || printf '  %s\n' "$*"; }
ok()   { [ "$QUIET" = 1 ] || printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# run <cmd...> — executes, or just prints under --dry-run
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  \033[2m[dry-run]\033[0m %s\n' "$*"
  else
    "$@"
  fi
}

# run_root <cmd...> — same, but via the scoped helper (see bin/devstack-web)
has_sudo_n() { sudo -n true 2>/dev/null; }

load_config() {
  # shellcheck disable=SC1090
  [ -f "$DEVSTACK_CONFIG" ] && . "$DEVSTACK_CONFIG"
  NGINX_PORT="${NGINX_PORT:-80}"
  APACHE_PORT="${APACHE_PORT:-8081}"
  SSL_PORT="${SSL_PORT:-443}"
  SSL="${SSL:-0}"
}

# set_config KEY VALUE — persist an override in ~/.config/devstack/config
set_config() {
  local k="$1" v="$2"
  mkdir -p "$DEVSTACK_CONFIG_DIR"
  [ -f "$DEVSTACK_CONFIG" ] || : > "$DEVSTACK_CONFIG"
  if grep -q "^${k}=" "$DEVSTACK_CONFIG" 2>/dev/null; then
    sed -i '' -E "s#^${k}=.*#${k}=${v}#" "$DEVSTACK_CONFIG"
  else
    printf '%s=%s\n' "$k" "$v" >> "$DEVSTACK_CONFIG"
  fi
}

ensure_dirs() {
  run mkdir -p "$DEVSTACK_HOME" "$DEVSTACK_CONFIG_DIR" "$DEVSTACK_BACKUP_DIR"
  [ "$DRY_RUN" = "1" ] || touch "$DEVSTACK_LOG" 2>/dev/null || true
}

timestamp() { date '+%Y%m%d-%H%M%S'; }

backup_file() {  # backup_file <path> -> copies into $DEVSTACK_BACKUP_DIR/<ts>/
  local src="$1"; [ -e "$src" ] || return 0
  local dest="$DEVSTACK_BACKUP_DIR/${BACKUP_TS:-$(timestamp)}"
  run mkdir -p "$dest"
  run cp -R "$src" "$dest/" 2>/dev/null || true
}

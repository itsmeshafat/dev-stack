#!/usr/bin/env bash
# dev-stack uninstaller — reverses install.sh. Safe: stops services, removes the
# helper + sudo rule + hosts block, and restores the most recent config backup.
set -uo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"; SOURCE="$(readlink "$SOURCE")"; [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
PKG_ROOT="$(cd -P "$(dirname "$SOURCE")" && pwd)"
. "$PKG_ROOT/lib/common.sh"
. "$PKG_ROOT/lib/modules.sh"

DRY_RUN=0; ASSUME_YES=0
for a in "$@"; do case "$a" in
  --dry-run) DRY_RUN=1 ;;
  --yes|-y) ASSUME_YES=1 ;;
  -h|--help) echo "usage: uninstall.sh [--dry-run] [--yes] [--purge]"; exit 0 ;;
esac; done

confirm() { [ "$ASSUME_YES" = 1 ] && return 0; [ "$DRY_RUN" = 1 ] && return 0
  local ans; read -r -p "$1 [y/N] " ans; case "$ans" in y|Y|yes) return 0;; *) return 1;; esac; }

echo "dev-stack uninstaller (dry-run=$DRY_RUN)"
confirm "Stop all dev-stack services and remove the stack?" || { echo "aborted"; exit 1; }

info "stopping services"
for m in web apache php74 php83 php85 mail redis postgres mysql; do
  f="$(module_formula "$m" 2>/dev/null || true)"
  if [ "$m" = "web" ]; then run sudo -n /usr/local/sbin/devstack-web uninstall 2>/dev/null || true; run "$HOMEBREW_PREFIX/bin/brew" services stop nginx 2>/dev/null || true
  else [ -n "$f" ] && run "$BREW" services stop "$f" 2>/dev/null || true; fi
done

info "removing privileged helper + sudo rule"
run sudo rm -f /usr/local/sbin/devstack-web /etc/sudoers.d/devstack

info "removing managed /etc/hosts block"
if [ "$DRY_RUN" = "1" ]; then printf '  \033[2m[dry-run]\033[0m strip devstack block from /etc/hosts\n'
else sudo sed -i '' '/# devstack-begin/,/# devstack-end/d' /etc/hosts 2>/dev/null || true; fi

info "removing generated vhosts"
run rm -f "$HOMEBREW_PREFIX/etc/nginx/servers/"*.conf "$HOMEBREW_PREFIX/etc/httpd/vhosts/"*.conf 2>/dev/null || true

info "restoring most recent config backup"
if [ "$DRY_RUN" != "1" ]; then
  last="$(ls -1dt "$DEVSTACK_BACKUP_DIR"/* 2>/dev/null | head -1)"
  if [ -n "${last:-}" ]; then
    note "from $last"
    [ -f "$last/hosts" ] && sudo cp "$last/hosts" /etc/hosts 2>/dev/null || true
    [ -d "$last/nginx" ] && cp -R "$last/nginx/." "$HOMEBREW_PREFIX/etc/nginx/" 2>/dev/null || true
    [ -d "$last/httpd" ] && cp -R "$last/httpd/." "$HOMEBREW_PREFIX/etc/httpd/" 2>/dev/null || true
  fi
fi

info "removing CLI + installed package"
run rm -f "$HOME/.local/bin/devstack"
run rm -rf "$DEVSTACK_HOME/pkg"

info "removing app"
run rm -rf "/Applications/Dev Stack.app" "$HOME/Desktop/Dev Stack.app"

ok "uninstall complete (Homebrew formulae left in place; remove them manually if you wish)"

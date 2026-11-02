#!/usr/bin/env bash
# lib/update.sh — release check + safe self-update. Sourced.
#
# Safety contract: an update only replaces application code
#   ~/.local/share/devstack/pkg, /Applications/Dev Stack.app,
#   and (only if changed) /usr/local/sbin/devstack-web.
# It never touches ~/.config/devstack, certs, /etc/hosts, vhosts, databases or services.

UPDATE_REPO="${DEVSTACK_UPDATE_REPO:-itsmeshafat/dev-stack}"
UPDATE_API="${DEVSTACK_UPDATE_API:-https://api.github.com/repos/$UPDATE_REPO/releases/latest}"
UPDATE_CACHE="$DEVSTACK_HOME/update-check.json"
UPDATE_CACHE_MAX_AGE=3600
DEVSTACK_PKG_DIR="$DEVSTACK_HOME/pkg"
UPDATE_BACKUPS="$DEVSTACK_HOME/pkg-backups"
UPDATE_TMP="$DEVSTACK_HOME/.update-tmp"
UPDATE_HELPER="/usr/local/sbin/devstack-web"

_pop() { printf '%s' "${1%%.*}"; }
_rest() { case "$1" in *.*) printf '%s' "${1#*.}" ;; *) printf '' ;; esac; }
_numeric() { local v; v="$(printf '%s' "$1" | tr -cd '0-9')"; [ -n "$v" ] || v=0; printf '%s' "$v"; }

# version_gt A B -> success when A > B (numeric, dot separated)
version_gt() {
  local i va vb A="$1" B="$2"
  for i in 1 2 3; do
    va="$(_numeric "$(_pop "$A")")"; A="$(_rest "$A")"
    vb="$(_numeric "$(_pop "$B")")"; B="$(_rest "$B")"
    [ "$va" -gt "$vb" ] && return 0
    [ "$va" -lt "$vb" ] && return 1
  done
  return 1
}

update_tag_of() {
  case "$1" in *'"prerelease": true'*|*'"prerelease":true'*) return 0 ;; esac
  printf '%s' "$1" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}
update_url_of() {
  printf '%s' "$1" \
    | grep -o '"html_url":[[:space:]]*"[^"]*"' \
    | sed -E 's/.*"html_url":[[:space:]]*"([^"]*)"/\1/' \
    | grep '/releases/tag/' | head -1
}

update_fetch() {
  /usr/bin/curl -fsSL --max-time 8 \
    -H 'User-Agent: devstack-updater' -H 'Accept: application/vnd.github+json' \
    "$UPDATE_API" 2>/dev/null
}

# update_status <json> -> "current<TAB>latest<TAB>available(0|1)<TAB>url"
update_status_of() {
  local json="$1" tag latest url available=0
  tag="$(update_tag_of "$json")"
  latest="${tag#v}"
  url="$(update_url_of "$json")"
  if [ -n "$latest" ] && version_gt "$latest" "$DEVSTACK_VERSION"; then available=1; fi
  printf '%s\t%s\t%s\t%s\n' "$DEVSTACK_VERSION" "$latest" "$available" "$url"
}

# update_check [human|json] — uses a 1h cache unless --refresh is passed
update_check() {
  local mode="${1:-human}" refresh="${2:-0}"
  if [ "${DEVSTACK_NO_UPDATE_CHECK:-0}" = "1" ]; then
    [ "$mode" = "json" ] && printf '{"current":"%s","latest":"%s","available":false,"url":""}\n' "$DEVSTACK_VERSION" "$DEVSTACK_VERSION" \
      || note "update checks disabled"
    return 0
  fi

  local json=""
  if [ "$refresh" != "1" ] && [ -f "$UPDATE_CACHE" ]; then
    local age=$(( $(date +%s) - $(/usr/bin/stat -f %m "$UPDATE_CACHE" 2>/dev/null || echo 0) ))
    [ "$age" -lt "$UPDATE_CACHE_MAX_AGE" ] && json="$(cat "$UPDATE_CACHE")"
  fi
  if [ -z "$json" ]; then
    json="$(update_fetch)"
    if [ -n "$json" ]; then printf '%s' "$json" > "$UPDATE_CACHE" 2>/dev/null || true
    elif [ -f "$UPDATE_CACHE" ]; then json="$(cat "$UPDATE_CACHE")"; fi
  fi

  if [ -z "$json" ]; then
    [ "$mode" = "json" ] && printf '{"current":"%s","latest":"","available":false,"url":""}\n' "$DEVSTACK_VERSION" \
      || warn "could not check for updates (offline?)"
    return 0
  fi

  local IFS=$'\t'; local cur latest avail url
  read -r cur latest avail url <<< "$(update_status_of "$json")"
  if [ "$mode" = "json" ]; then
    local avail_json="false"; [ "$avail" = "1" ] && avail_json="true"
    printf '{"current":"%s","latest":"%s","available":%s,"url":"%s"}\n' "$cur" "$latest" "$avail_json" "$url"
  else
    if [ "$avail" = "1" ]; then info "Update available: $cur → $latest"; note "$url"
    else ok "up to date ($cur)"; fi
  fi
}

# update_apply <assume_yes 0|1> <allow_helper 0|1>
update_apply() {
  local assume_yes="${1:-0}" allow_helper="${2:-1}"
  local current="$DEVSTACK_VERSION"

  info "checking for updates"
  local json; json="$(update_fetch)"
  if [ -z "$json" ]; then die "cannot reach GitHub (no network?)"; fi
  local tag latest; tag="$(update_tag_of "$json")"; latest="${tag#v}"
  [ -n "$latest" ] || die "could not read the latest release"
  if ! version_gt "$latest" "$current"; then ok "already up to date ($current)"; return 0; fi

  local url="${DEVSTACK_UPDATE_TARBALL:-https://github.com/$UPDATE_REPO/archive/refs/tags/$tag.tar.gz}"
  local ts; ts="$(timestamp)"
  local tmp="$UPDATE_TMP/$ts"
  mkdir -p "$tmp"
  info "downloading $tag"
  /usr/bin/curl -fsSL --max-time 180 -o "$tmp/release.tar.gz" "$url" || { rm -rf "$tmp"; die "download failed"; }
  /usr/bin/tar -xzf "$tmp/release.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "extract failed"; }
  local src; src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [ -n "$src" ] && [ -d "$src/bin" ] || { rm -rf "$tmp"; die "unexpected archive layout"; }

  local newver; newver="$(sed -n 's/^DEVSTACK_VERSION="\(.*\)"/\1/p' "$src/lib/common.sh" 2>/dev/null | head -1)"
  [ "$newver" = "$latest" ] || { rm -rf "$tmp"; die "version mismatch: archive=$newver tag=$latest"; }

  # ---- atomic swap (rename keeps the running script valid) ----
  mkdir -p "$UPDATE_BACKUPS"
  if [ -e "$DEVSTACK_PKG_DIR" ]; then
    mv "$DEVSTACK_PKG_DIR" "$UPDATE_BACKUPS/$current-$ts" || die "could not back up current version"
  fi
  if ! mv "$src" "$DEVSTACK_PKG_DIR"; then
    [ -e "$UPDATE_BACKUPS/$current-$ts" ] && mv "$UPDATE_BACKUPS/$current-$ts" "$DEVSTACK_PKG_DIR"
    rm -rf "$tmp"; die "swap failed; previous version restored"
  fi
  rm -rf "$tmp"
  # keep the last 3 backups
  ls -1dt "$UPDATE_BACKUPS"/* 2>/dev/null | tail -n +4 | while read -r old; do rm -rf "$old"; done

  # ---- helper (only if it changed) ----
  local helper_changed=0 h_new h_old
  if [ -f "$DEVSTACK_PKG_DIR/bin/devstack-web" ]; then
    h_new="$(/usr/bin/shasum -a 256 "$DEVSTACK_PKG_DIR/bin/devstack-web" | awk '{print $1}')"
    if [ -x "$UPDATE_HELPER" ]; then
      h_old="$(/usr/bin/shasum -a 256 "$UPDATE_HELPER" | awk '{print $1}')"
      [ "$h_new" != "$h_old" ] && helper_changed=1
    else
      helper_changed=1
    fi
  fi
  if [ "$helper_changed" = "1" ]; then
    if [ "$allow_helper" = "0" ]; then
      echo "HELPER_UPDATE_REQUIRED"
      warn "privileged helper changed — update it with: sudo bash \"$DEVSTACK_PKG_DIR/bin/install-helper-root\" \"$DEV_USER\" \"$DEVSTACK_PKG_DIR\""
    elif [ -t 0 ]; then
      info "privileged helper changed — one admin prompt"
      sudo bash "$DEVSTACK_PKG_DIR/bin/install-helper-root" "$DEV_USER" "$DEVSTACK_PKG_DIR" || warn "helper update failed"
    else
      echo "HELPER_UPDATE_REQUIRED"
    fi
  fi

  # ---- rebuild the app (no config/service changes) ----
  if [ "${DEVSTACK_SKIP_APP:-0}" = "1" ]; then
    note "app rebuild skipped (DEVSTACK_SKIP_APP=1)"
  elif command -v swiftc >/dev/null 2>&1 || /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
    if bash "$DEVSTACK_PKG_DIR/app/build-app.sh" >/dev/null 2>&1; then ok "app rebuilt"; else warn "app rebuild failed (run app/build-app.sh)"; fi
  else
    warn "Xcode Command Line Tools missing — CLI updated, app NOT rebuilt"
  fi

  ok "updated $current → $latest"
  note "sites, config, certificates and running services were not touched"
  note "if this release changed vhost templates, run: devstack sync"
}

update_rollback() {
  local last; last="$(ls -1dt "$UPDATE_BACKUPS"/* 2>/dev/null | head -1)"
  [ -n "$last" ] || die "no backups to roll back to"
  local ts; ts="$(timestamp)"
  mkdir -p "$UPDATE_TMP"
  mv "$DEVSTACK_PKG_DIR" "$UPDATE_TMP/rollback-$ts" 2>/dev/null || rm -rf "$DEVSTACK_PKG_DIR"
  if ! mv "$last" "$DEVSTACK_PKG_DIR"; then
    mv "$UPDATE_TMP/rollback-$ts" "$DEVSTACK_PKG_DIR" 2>/dev/null
    die "rollback failed"
  fi
  rm -rf "$UPDATE_TMP/rollback-$ts"
  local v; v="$(sed -n 's/^DEVSTACK_VERSION="\(.*\)"/\1/p' "$DEVSTACK_PKG_DIR/lib/common.sh" 2>/dev/null | head -1)"
  ok "rolled back to $v"
  if [ "${DEVSTACK_SKIP_APP:-0}" != "1" ] && bash "$DEVSTACK_PKG_DIR/app/build-app.sh" >/dev/null 2>&1; then
    ok "app rebuilt"
  fi
}

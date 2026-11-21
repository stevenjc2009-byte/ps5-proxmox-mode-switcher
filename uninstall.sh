#!/usr/bin/env bash
# PS5 Proxmox RAM/VRAM mode switcher - uninstaller.
#
# Removes the container, the host switcher, the boot-verification unit and the
# restricted SSH key. Keeps every backup under /root/ps5-mode-backup-* and the
# log at /var/log/ps5-mode.log. It never touches /boot/efi.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ps5-proxmox-mode-switcher/main/uninstall.sh)"
#
# Overrides: PS5SW_CTID, PS5SW_YES=1, PS5SW_DRY_RUN=1
set -Eeuo pipefail

CTID="${PS5SW_CTID:-$(cat /etc/ps5-mode/ctid 2>/dev/null || true)}"
ASSUME_YES="${PS5SW_YES:-0}"
DRY_RUN="${PS5SW_DRY_RUN:-0}"

if [ -t 1 ]; then C_Y=$'\033[1;33m'; C_G=$'\033[1;32m'; C_0=$'\033[0m'; else C_Y=""; C_G=""; C_0=""; fi
log() { printf '==> %s\n' "$*"; }
warn() { printf '%swarn%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die() { printf 'ERROR %s\n' "$*" >&2; exit 1; }
run() { if [ "$DRY_RUN" = 1 ]; then printf '    would run: %s\n' "$*"; else "$@"; fi; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"

log "PS5 mode switcher uninstall"
[ -n "$CTID" ] && printf '  container: CT %s\n' "$CTID"
printf '  keeps    : /root/ps5-mode-backup-* and /var/log/ps5-mode.log\n'
printf '  removes  : host scripts, unit, restricted key, /etc/ps5-mode, /var/lib/ps5-mode\n\n'

if [ "$ASSUME_YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then
  printf 'Continue? [y/N] '
  read -r a
  case "$a" in y|Y|yes|YES) ;; *) die "cancelled" ;; esac
fi

if [ -n "$CTID" ] && pct status "$CTID" >/dev/null 2>&1; then
  run pct stop "$CTID" || true
  run pct destroy "$CTID" --purge 1
  log "container CT $CTID removed"
else
  warn "no container found to remove"
fi

for f in /usr/local/sbin/ps5-mode-switch /usr/local/sbin/ps5-mode-ctl \
  /etc/systemd/system/ps5-mode-verify.service; do
  if [ -e "$f" ]; then run rm -f "$f"; fi
done
run systemctl daemon-reload

ak=/root/.ssh/authorized_keys
if [ -f "$ak" ] && grep -q '^# ps5-mode-switcher begin$' "$ak"; then
  if [ "$DRY_RUN" = 1 ]; then
    printf '    would remove the ps5-mode-switcher block from %s\n' "$ak"
  else
    cp -a "$ak" "$ak.bak-uninstall-$(date +%Y%m%d-%H%M%S)"
    tmp=$(mktemp)
    awk '
      /^# ps5-mode-switcher begin$/ {skip = 1; next}
      /^# ps5-mode-switcher end$/   {skip = 0; next}
      !skip {print}
    ' "$ak" >"$tmp"
    cat "$tmp" >"$ak"
    rm -f "$tmp"
    chmod 0600 "$ak"
    log "restricted key removed"
  fi
fi

run rm -rf /etc/ps5-mode /var/lib/ps5-mode
printf '\n%sUninstall complete.%s Backups and the log were kept.\n' "$C_G" "$C_0"

#!/usr/bin/env bash
# PS5 Proxmox RAM/VRAM mode switcher - Proxmox VE install helper.
#
# Run on the Proxmox host (PS5 node) as root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ps5-proxmox-mode-switcher/main/install.sh)"
#
# What it does
#   1. Backs up the current boot configuration to /root/ps5-mode-backup-<time>.
#   2. Installs the host-side switcher and a restricted SSH bridge.
#   3. Creates a small unprivileged Debian LXC whose Shell opens the mode menu.
#   4. Tests the bridge end to end and prints the container ID.
#
# It never edits /boot/efi/cmdline.txt or vram.txt. Mode changes are kexec only,
# so a cold PS5 boot always returns to the stock default.
#
# Environment overrides:
#   PS5SW_CTID PS5SW_HOSTNAME PS5SW_IP PS5SW_GW PS5SW_BRIDGE PS5SW_STORAGE
#   PS5SW_TEMPLATE_STORAGE PS5SW_HOST_IP PS5SW_CORES PS5SW_MEMORY PS5SW_SWAP
#   PS5SW_DISK PS5SW_YES=1 PS5SW_DRY_RUN=1 PS5SW_REPIN=1 PS5SW_FORCE=1
#   PS5SW_REF (git ref, default main) PS5SW_BASE_URL
set -Eeuo pipefail
umask 022

REPO_SLUG="stevenjc2009-byte/ps5-proxmox-mode-switcher"
REF="${PS5SW_REF:-main}"
BASE_URL="${PS5SW_BASE_URL:-https://raw.githubusercontent.com/$REPO_SLUG/$REF}"

CTID="${PS5SW_CTID:-}"
CT_HOSTNAME="${PS5SW_HOSTNAME:-ps5-mode}"
CT_IP="${PS5SW_IP:-}"
CT_GW="${PS5SW_GW:-}"
CT_CORES="${PS5SW_CORES:-1}"
CT_MEMORY="${PS5SW_MEMORY:-256}"
CT_SWAP="${PS5SW_SWAP:-128}"
CT_DISK="${PS5SW_DISK:-2}"
BRIDGE="${PS5SW_BRIDGE:-vmbr0}"
ROOTFS_STORAGE="${PS5SW_STORAGE:-}"
TEMPLATE_STORAGE="${PS5SW_TEMPLATE_STORAGE:-}"
HOST_IP="${PS5SW_HOST_IP:-}"
ASSUME_YES="${PS5SW_YES:-0}"
DRY_RUN="${PS5SW_DRY_RUN:-0}"
REPIN="${PS5SW_REPIN:-0}"
FORCE="${PS5SW_FORCE:-0}"
ALLOW_NONROOT="${PS5SW_ALLOW_NONROOT:-0}"

STATE_DIR="${PS5SW_STATE_DIR:-/etc/ps5-mode}"
LIB_STATE="${PS5SW_LIB_STATE:-/var/lib/ps5-mode}"
ESP_DIR="${PS5SW_ESP:-/boot/efi}"
TMP=""

if [ -t 1 ]; then
  C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_B=$'\033[1;36m'; C_0=$'\033[0m'
else
  C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""
fi

log() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok() { printf '%s  ok%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die() { printf '%sERROR%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

on_err() { printf '%sERROR%s line %s: %s\n' "$C_R" "$C_0" "${1:-?}" "${2:-?}" >&2; }
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
cleanup() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '    would run: %s\n' "$*"
  else
    "$@"
  fi
}

self_src="${BASH_SOURCE[0]:-}"
LOCAL_DIR=""
if [ -n "$self_src" ] && [ -f "$self_src" ]; then
  cand=$(cd "$(dirname "$self_src")" && pwd)
  if [ -f "$cand/host/ps5-mode-switch" ]; then LOCAL_DIR="$cand"; fi
fi

fetch() {
  local rel="$1" dest="$2"
  if [ -n "$LOCAL_DIR" ]; then
    cp "$LOCAL_DIR/$rel" "$dest" || die "missing local file $rel"
  else
    curl -fsSL --retry 3 --connect-timeout 10 "$BASE_URL/$rel" -o "$dest" \
      || die "download failed: $BASE_URL/$rel"
  fi
  [ -s "$dest" ] || die "downloaded file is empty: $rel"
}

preflight() {
  if [ "$ALLOW_NONROOT" != 1 ]; then
    [ "$(id -u)" -eq 0 ] || die "run this on the Proxmox host as root"
  fi
  command -v pveversion >/dev/null 2>&1 || die "this does not look like Proxmox VE (pveversion missing)"
  command -v pct >/dev/null 2>&1 || die "pct missing; is this a Proxmox VE host?"
  command -v qm >/dev/null 2>&1 || die "qm missing; is this a Proxmox VE host?"
  if [ ! -e /dev/mp1 ] && [ ! -d /sys/class/devfreq/ps5-gpufreq ] && [ "$FORCE" != 1 ]; then
    die "this does not look like the PS5 node (no /dev/mp1 or ps5-gpufreq). Set PS5SW_FORCE=1 to continue anyway."
  fi
  [ -f "$ESP_DIR/bzImage" ] && [ -f "$ESP_DIR/initrd.img" ] \
    || die "$ESP_DIR/bzImage or initrd.img missing; kexec needs the ESP mounted at /boot/efi"
  if ! command -v kexec >/dev/null 2>&1; then
    warn "kexec-tools is missing; installing it"
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y kexec-tools
  fi
  ok "host looks like the PS5 Proxmox node"
}

resolve_host_ip() {
  if [ -z "$HOST_IP" ]; then
    HOST_IP=$(ip -4 route get 1.1.1.1 2>/dev/null |
      awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)
  fi
  if [ -z "$HOST_IP" ]; then HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true); fi
  [ -n "$HOST_IP" ] || die "cannot determine the host IP; set PS5SW_HOST_IP=192.168.0.145"
}

resolve_ctid() {
  if [ -z "$CTID" ] && command -v pct >/dev/null 2>&1; then
    CTID=$(pct list 2>/dev/null |
      awk -v n="$CT_HOSTNAME" 'NR > 1 && $NF == n {print $1; exit}')
  fi
  if [ -z "$CTID" ]; then
    CTID=$(pvesh get /cluster/nextid 2>/dev/null || true)
    if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
      local max
      max=$({ qm list 2>/dev/null; pct list 2>/dev/null; } | awk '$1 ~ /^[0-9]+$/ {if ($1 > m) m = $1} END {print m + 0}')
      CTID=$((max + 1))
    fi
  fi
  [[ "$CTID" =~ ^[0-9]+$ ]] || die "invalid container ID '$CTID'"
}

pick_rootfs_storage() {
  local list s
  list=$(pvesm status -content rootdir 2>/dev/null | awk 'NR > 1 {print $1}')
  for s in local-zfs local-lvm; do
    if printf '%s\n' "$list" | grep -qx "$s"; then printf '%s\n' "$s"; return 0; fi
  done
  printf '%s\n' "$list" | head -n1
}

find_template() {
  local store="$1"
  pveam list "$store" 2>/dev/null |
    awk 'NR > 1 && $1 ~ /debian-13-standard_/ {print $1}' |
    sort -V | tail -n1
}

resolve_template() {
  if [ -z "$TEMPLATE_STORAGE" ]; then
    TEMPLATE_STORAGE=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR > 1 {print $1; exit}')
  fi
  [ -n "$TEMPLATE_STORAGE" ] || die "no storage accepts container templates; set PS5SW_TEMPLATE_STORAGE"
  TEMPLATE=$(find_template "$TEMPLATE_STORAGE" || true)
  if [ -z "$TEMPLATE" ]; then
    log "Debian 13 template not found; downloading it"
    run pveam update
    local name
    name=$(pveam available --section system 2>/dev/null |
      awk '$2 ~ /^debian-13-standard_/ {print $2}' | sort -V | tail -n1)
    if [ -z "$name" ] && [ "$DRY_RUN" = 1 ]; then name="debian-13-standard_dry-run_amd64.tar.zst"; fi
    [ -n "$name" ] || die "no debian-13-standard template available from pveam"
    run pveam download "$TEMPLATE_STORAGE" "$name"
    TEMPLATE=$(find_template "$TEMPLATE_STORAGE" || true)
    if [ -z "$TEMPLATE" ] && [ "$DRY_RUN" = 1 ]; then
      TEMPLATE="$TEMPLATE_STORAGE:vztmpl/$name"
    fi
  fi
  [ -n "$TEMPLATE" ] || die "could not resolve a Debian 13 template"
}

make_backup() {
  local dir="$1"
  run mkdir -p "$dir"
  local f
  for f in cmdline.txt vram.txt cmdline.txt.11gib-gtt cmdline.txt.12gib-gtt; do
    if [ -f "$ESP_DIR/$f" ]; then run cp -a "$ESP_DIR/$f" "$dir/$f"; fi
  done
  run cp /proc/cmdline "$dir/proc-cmdline.txt"
  run sh -c "uname -a > '$dir/uname.txt'"
  run sh -c "pveversion -v > '$dir/pveversion.txt' 2>/dev/null || true"
  run sh -c "{ qm list; pct list; } > '$dir/guests.txt' 2>/dev/null || true"
  run sh -c "cat > '$dir/README.txt' <<'EOF'
Original PS5 Proxmox boot configuration, saved before the ps5-mode-switcher
made any change.

  cmdline.txt       cold-boot kernel command line (stock default, no ttm args)
  vram.txt          PS5 loader VRAM carve-out (0x20000000 = 512 MiB)
  proc-cmdline.txt  command line the running kernel was started with

Restore with:  ps5-mode-switch rollback
EOF"
}

install_host_files() {
  install -m 0755 "$TMP/ps5-mode-switch" /usr/local/sbin/ps5-mode-switch
  install -m 0755 "$TMP/ps5-mode-ctl" /usr/local/sbin/ps5-mode-ctl
  install -m 0644 "$TMP/ps5-mode-verify.service" /etc/systemd/system/ps5-mode-verify.service
  ok "host switcher installed in /usr/local/sbin"
}

make_key() {
  PUB=""
  install -d -m 0700 "$STATE_DIR"
  if [ ! -f "$STATE_DIR/id_ed25519" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDRYRUNONLY ps5-mode-switcher"
      return 0
    fi
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is missing"
    ssh-keygen -t ed25519 -N "" -C ps5-mode-switcher -f "$STATE_DIR/id_ed25519" >/dev/null
    ok "SSH key created in $STATE_DIR"
  fi
  PUB=$(cat "$STATE_DIR/id_ed25519.pub")
}

write_authorized_key() {
  local ip="$1" ak=/root/.ssh/authorized_keys tmpak
  install -d -m 0700 /root/.ssh
  touch "$ak"
  chmod 0600 "$ak"
  tmpak=$(mktemp)
  awk '
    /^# ps5-mode-switcher begin$/ {skip = 1; next}
    /^# ps5-mode-switcher end$/   {skip = 0; next}
    !skip {print}
  ' "$ak" >"$tmpak"
  cp -a "$ak" "$ak.bak-$(date +%Y%m%d-%H%M%S)"
  {
    cat "$tmpak"
    printf '# ps5-mode-switcher begin\n'
    printf 'command="/usr/local/sbin/ps5-mode-ctl",restrict,from="%s" %s\n' "$ip" "$PUB"
    printf '# ps5-mode-switcher end\n'
  } >"$ak"
  rm -f "$tmpak"
  chmod 0600 "$ak"
  ok "restricted key pinned to $ip in $ak"
}

current_mode_name() {
  local lim
  lim=$(tr ' ' '\n' </proc/cmdline | sed -n 's/^ttm\.pages_limit=//p' | head -n1)
  if [ -z "$lim" ]; then
    printf 'default (full RAM, stock GPU limit)'
  elif [ "$lim" = 2883584 ]; then
    printf 'AI (11 GiB GPU)'
  else
    printf 'custom (ttm.pages_limit=%s)' "$lim"
  fi
}

container_ip() {
  local ip
  if [ -n "$CT_IP" ]; then
    printf '%s\n' "$CT_IP"
    return 0
  fi
  for _ in $(seq 1 60); do
    ip=$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null |
      awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
    if [ -n "$ip" ]; then printf '%s\n' "$ip"; return 0; fi
    sleep 3
  done
  return 1
}

setup_container() {
  local exists=0 net ip
  if pct status "$CTID" >/dev/null 2>&1; then
    exists=1
    [ "$(pct config "$CTID" | sed -n 's/^hostname: //p')" = "$CT_HOSTNAME" ] \
      || die "CT $CTID exists and is not '$CT_HOSTNAME'; pick another ID with PS5SW_CTID"
    warn "CT $CTID already exists; updating its menu and key"
  else
    net="name=eth0,bridge=$BRIDGE,ip=dhcp"
    if [ -n "$CT_IP" ]; then
      net="name=eth0,bridge=$BRIDGE,ip=$CT_IP/24${CT_GW:+,gw=$CT_GW}"
    fi
    run pct create "$CTID" "$TEMPLATE" \
      --hostname "$CT_HOSTNAME" \
      --description "PS5 Proxmox RAM/VRAM mode switcher - open Shell for the menu" \
      --cores "$CT_CORES" --memory "$CT_MEMORY" --swap "$CT_SWAP" \
      --rootfs "$ROOTFS_STORAGE:$CT_DISK" \
      --net0 "$net" \
      --unprivileged 1 --features nesting=1 --onboot 1 --ostype debian --start 1
    ok "container $CTID created and started"
  fi
  if [ "$exists" = 1 ] && [ "$DRY_RUN" = 1 ]; then
    printf '    would enable nesting and restart CT %s so the web console works\n' "$CTID"
  elif [ "$exists" = 1 ]; then
    pct set "$CTID" --features nesting=1 >/dev/null 2>&1 \
      || warn "could not set nesting=1 on CT $CTID; the web console may stay black"
    pct reboot "$CTID" >/dev/null 2>&1 || pct start "$CTID" >/dev/null 2>&1 || true
  fi

  if [ "$DRY_RUN" = 1 ]; then
    printf '    would install openssh-client + whiptail in CT %s and enable root console autologin\n' "$CTID"
    ip="${CT_IP:-dhcp-pending}"
  else
    log "installing container packages (openssh-client, whiptail)"
    local tries=0
    until pct exec "$CTID" -- true >/dev/null 2>&1; do
      tries=$((tries + 1))
      [ "$tries" -lt 60 ] || die "CT $CTID did not become reachable; check its console with: pct enter $CTID"
      sleep 2
    done
    pct exec "$CTID" -- bash -c 'apt-get update -qq'
    pct exec "$CTID" -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-client whiptail ca-certificates'
    pct exec "$CTID" -- install -d -m 0755 /etc/ps5-mode
    pct push "$CTID" --perms 755 "$TMP/ps5-menu" /usr/local/bin/ps5-menu
    pct push "$CTID" --perms 600 "$STATE_DIR/id_ed25519" /etc/ps5-mode/id_ed25519
    pct push "$CTID" --perms 644 "$TMP/bashrc-hook" /etc/ps5-mode/bashrc-hook
    pct push "$CTID" --perms 644 "$TMP/bashrc-hook" /etc/profile.d/ps5-menu.sh
    pct exec "$CTID" -- install -d -m 0755 /etc/systemd/system/getty@tty1.service.d
    pct push "$CTID" --perms 644 "$TMP/getty-autologin.conf" \
      /etc/systemd/system/getty@tty1.service.d/autologin.conf
    pct exec "$CTID" -- systemctl daemon-reload
    pct exec "$CTID" -- systemctl restart getty@tty1 >/dev/null 2>&1 || true
    pct exec "$CTID" -- sh -c "printf '%s\n' '$HOST_IP' > /etc/ps5-mode/host"
    pct exec "$CTID" -- sh -c 'touch /etc/ps5-mode/known_hosts; chmod 600 /etc/ps5-mode/known_hosts'
    pct exec "$CTID" -- sh -c "ssh-keyscan -T 5 -t ed25519 '$HOST_IP' > /etc/ps5-mode/known_hosts 2>/dev/null || true"
    pct exec "$CTID" -- bash -c '
      if ! grep -q ps5-mode-switcher /root/.bashrc 2>/dev/null; then
        printf "\n# ps5-mode-switcher\n. /etc/ps5-mode/bashrc-hook\n" >> /root/.bashrc
      fi
    '
    ip=$(container_ip) || die "CT $CTID got no IP address. Re-run with PS5SW_IP=192.168.0.x PS5SW_GW=192.168.0.1 (and keep that address reserved)."
    ok "container is at $ip"
  fi
  CT_IP_RESOLVED="$ip"
}

test_bridge() {
  [ "$DRY_RUN" = 1 ] && { log "would test the bridge from CT $CTID"; return 0; }
  local out
  out=$(pct exec "$CTID" -- ssh -i /etc/ps5-mode/id_ed25519 \
    -o BatchMode=yes -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/etc/ps5-mode/known_hosts \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "root@$HOST_IP" status 2>&1) \
    || die "bridge test failed from the container:
$out

Check that the host sshd allows root key logins and that /root/.ssh/authorized_keys
contains the ps5-mode-switcher block pinned to $CT_IP_RESOLVED."
  printf '%s\n' "$out"
  ok "container -> host bridge works"
}

enable_verify_unit() {
  run systemctl daemon-reload
  run systemctl enable ps5-mode-verify.service
  ok "boot verification unit enabled"
}

main() {
  log "PS5 Proxmox RAM/VRAM mode switcher installer"
  preflight
  resolve_host_ip
  resolve_ctid

  if [ "$REPIN" = 1 ]; then
    [ -n "$CTID" ] || die "no CT id; pass PS5SW_CTID"
    pct status "$CTID" >/dev/null 2>&1 || die "CT $CTID does not exist"
    [ -f "$STATE_DIR/id_ed25519" ] || die "SSH key missing from $STATE_DIR; run the full installer once"
    PUB=$(cat "$STATE_DIR/id_ed25519.pub")
    CT_IP_RESOLVED=$(container_ip) || die "CT $CTID has no IP"
    write_authorized_key "$CT_IP_RESOLVED"
    test_bridge
    ok "re-pinned to $CT_IP_RESOLVED"
    return 0
  fi

  ROOTFS_STORAGE="${ROOTFS_STORAGE:-$(pick_rootfs_storage)}"
  if [ -z "$ROOTFS_STORAGE" ] && [ "$DRY_RUN" = 1 ]; then ROOTFS_STORAGE="local-zfs"; fi
  [ -n "$ROOTFS_STORAGE" ] || die "no storage accepts container root disks; set PS5SW_STORAGE"
  resolve_template

  local backup_dir
  backup_dir="/root/ps5-mode-backup-$(date +%Y%m%d-%H%M%S)"

  printf '\n%sPlan%s\n' "$C_B" "$C_0"
  printf '  host          : %s (%s, kernel %s)\n' "$HOST_IP" "$(hostname)" "$(uname -r)"
  printf '  current mode  : %s\n' "$(current_mode_name)"
  printf '  container     : CT %s %s, %s core, %s MB RAM, %s GB on %s\n' \
    "$CTID" "$CT_HOSTNAME" "$CT_CORES" "$CT_MEMORY" "$CT_DISK" "$ROOTFS_STORAGE"
  printf '  network       : %s, %s\n' "$BRIDGE" "${CT_IP:-DHCP}"
  printf '  template      : %s\n' "$TEMPLATE"
  printf '  backup        : %s\n' "$backup_dir"
  printf '\nNothing on the PS5 loader is changed. Mode switches use kexec only.\n\n'

  if [ "$ASSUME_YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    local a
    printf 'Continue? [y/N] '
    read -r a
    case "$a" in y|Y|yes|YES) ;; *) die "cancelled" ;; esac
  fi

  TMP=$(mktemp -d)
  log "fetching files"
  fetch host/ps5-mode-switch "$TMP/ps5-mode-switch"
  fetch host/ps5-mode-ctl "$TMP/ps5-mode-ctl"
  fetch host/ps5-mode-verify.service "$TMP/ps5-mode-verify.service"
  fetch container/ps5-menu "$TMP/ps5-menu"
  fetch container/bashrc-hook "$TMP/bashrc-hook"
  fetch container/getty-autologin.conf "$TMP/getty-autologin.conf"
  chmod 0755 "$TMP/ps5-mode-switch" "$TMP/ps5-mode-ctl" "$TMP/ps5-menu"

  log "backing up the current boot configuration"
  make_backup "$backup_dir"
  if [ "$DRY_RUN" != 1 ]; then
    install -d -m 0755 "$LIB_STATE"
    printf '%s\n' "$backup_dir" >"$LIB_STATE/backup-dir"
  fi
  ok "backup at $backup_dir"

  log "installing host files"
  if [ "$DRY_RUN" = 1 ]; then
    printf '    would install /usr/local/sbin/ps5-mode-switch and ps5-mode-ctl\n'
  else
    install_host_files
  fi
  make_key
  if [ "$DRY_RUN" != 1 ]; then
    printf '%s\n' "$CTID" >"$STATE_DIR/ctid"
    printf '%s\n' "$HOST_IP" >"$STATE_DIR/host"
    printf '%s\n' "$REF" >"$STATE_DIR/version"
  fi

  setup_container
  if [ "$DRY_RUN" != 1 ]; then
    write_authorized_key "$CT_IP_RESOLVED"
  else
    printf '    would pin the key to the container IP in /root/.ssh/authorized_keys\n'
  fi
  test_bridge
  enable_verify_unit

  if [ "$DRY_RUN" != 1 ]; then
    /usr/local/sbin/ps5-mode-switch record-boot >/dev/null 2>&1 || true
  fi

  printf '\n%s%sInstall complete%s\n\n' "$C_G" "$C_B" "$C_0"
  printf '  Container : CT %s (%s) at %s\n' "$CTID" "$CT_HOSTNAME" "${CT_IP_RESOLVED:-?}"
  printf '  Open it   : web UI > node > CT %s > Console (the menu starts itself)\n' "$CTID"
  printf '  Modes     : NORMAL (default: full RAM, Minecraft / VMs) and AI (11 GB VRAM / ~3 GB RAM)\n'
  printf '  Rollback  : ps5-mode-switch rollback   (host shell)\n'
  printf '  Log       : /var/log/ps5-mode.log\n'
  printf '  Backup    : %s\n' "$backup_dir"
  printf '  Uninstall : bash -c "$(curl -fsSL %s/uninstall.sh)"\n' "$BASE_URL"
  printf '\nAfter every switch the container stops with the host and comes back on boot.\n'
  printf 'Reopen its Shell after about 2 minutes to see the new mode.\n'
}

main "$@"

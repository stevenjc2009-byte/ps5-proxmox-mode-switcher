#!/usr/bin/env bash
# Offline tests for the ps5-mode-switcher. No Proxmox, no PS5, no kexec:
# every privileged command is a stub that records what it was asked to do.
#
# Run:  bash tests/run-tests.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
contains() {
  local desc="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then ok "$desc"; else bad "$desc (missing: $needle)"; fi
}
not_contains() {
  local desc="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then bad "$desc (found: $needle)"; else ok "$desc"; fi
}

# ---------------------------------------------------------------- sandbox ----
ESP="$T/esp"
DRM="$T/drm"
STATE="$T/state"
BACKUP="$T/root"
BIN="$T/bin"
CALLS="$T/calls"
export CALLS
CMDLINE="$T/proc-cmdline"
mkdir -p "$ESP" "$DRM" "$STATE" "$BACKUP" "$BIN"
: >"$CALLS"

printf 'root=LABEL=proxmox9 rw rootwait quiet console=ttyTitania0 console=tty0\n' >"$ESP/cmdline.txt"
printf '0x20000000\n' >"$ESP/vram.txt"
: >"$ESP/bzImage"
: >"$ESP/initrd.img"
touch -d '30 days ago' "$ESP/bzImage" "$ESP/initrd.img"
printf 'root=LABEL=proxmox9 rw rootwait quiet console=ttyTitania0 console=tty0\n' >"$CMDLINE"
printf '11811160064\n' >"$DRM/mem_info_gtt_total"
printf '11767808\n' >"$DRM/mem_info_gtt_used"
printf '536870912\n' >"$DRM/mem_info_vram_total"

cat >"$BIN/kexec" <<'EOF'
#!/usr/bin/env bash
echo "kexec $*" >>"$CALLS"
exit 0
EOF
cat >"$BIN/systemd-run" <<'EOF'
#!/usr/bin/env bash
echo "systemd-run $*" >>"$CALLS"
exit 0
EOF
cat >"$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$CALLS"
exit 0
EOF
cat >"$BIN/qm" <<'EOF'
#!/usr/bin/env bash
echo "qm $*" >>"$CALLS"
case "${1:-}" in
  list) printf '      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n       100 macos-tahoe          running    11012        64.00 0\n' ;;
  config) printf 'name: macos-tahoe\nmemory: 11012\nonboot: 0\n' ;;
  shutdown) [ "${QM_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
esac
exit 0
EOF
cat >"$BIN/pct" <<'EOF'
#!/usr/bin/env bash
echo "pct $*" >>"$CALLS"
case "${1:-}" in
  list) printf '      VMID Status           Lock Name\n       101 running               ollama\n       102 running               searxng\n       103 running               ps5-mode\n' ;;
  config)
    case "${2:-}" in
      101) printf 'hostname: ollama\nmemory: 12288\nonboot: 1\n' ;;
      102) printf 'hostname: searxng\nmemory: 512\nonboot: 1\n' ;;
      103) printf 'hostname: ps5-mode\nmemory: 256\nonboot: 1\n' ;;
    esac
    ;;
  status) [ "${PCT_EXISTS:-0}" = 1 ] || exit 1 ;;
  shutdown) [ "${PCT_FAIL_ID:-}" = "${2:-}" ] && exit 1; exit 0 ;;
  exec) exit 0 ;;
esac
exit 0
EOF
cat >"$BIN/pveversion" <<'EOF'
#!/usr/bin/env bash
echo 'pve-manager/9.2.28/abcdef (running kernel: 7.2.3)'
EOF
cat >"$BIN/pvesm" <<'EOF'
#!/usr/bin/env bash
echo "pvesm $*" >>"$CALLS"
if [ "${1:-}" = status ]; then
  case "${3:-}" in
    rootdir) printf 'Name             Type     Status           Total            Used       Available        %%\nlocal-zfs        zfspool  active               1               1               1    1.00\n' ;;
    vztmpl) printf 'Name             Type     Status           Total            Used       Available        %%\nlocal            dir      active               1               1               1    1.00\n' ;;
  esac
fi
exit 0
EOF
cat >"$BIN/pveam" <<'EOF'
#!/usr/bin/env bash
echo "pveam $*" >>"$CALLS"
case "${1:-}" in
  list) printf 'Name                                                     Size\nlocal:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst     180.00MB\n' ;;
  available) printf 'Section  Name\ndebian   debian-13-standard_13.6-1_amd64.tar.zst\n' ;;
  download|update) exit 0 ;;
esac
exit 0
EOF
cat >"$BIN/pvesh" <<'EOF'
#!/usr/bin/env bash
echo "pvesh $*" >>"$CALLS"
case "$*" in
  *nextid*) echo 103 ;;
esac
exit 0
EOF
chmod +x "$BIN"/*

run_switch() {
  env \
    PS5MODE_ESP="$ESP" \
    PS5MODE_CMDLINE_FILE="$CMDLINE" \
    PS5MODE_DRM="$DRM" \
    PS5MODE_STATE="$STATE" \
    PS5MODE_LOG="$T/log" \
    PS5MODE_LOCK="$T/lock" \
    PS5MODE_BACKUP_ROOT="$BACKUP" \
    PS5MODE_ALLOW_NONROOT=1 \
    PATH="$BIN:$PATH" \
    "$ROOT/host/ps5-mode-switch" "$@"
}

reset_state() {
  : >"$CALLS"
  rm -rf "$STATE" "$BACKUP"
  mkdir -p "$STATE" "$BACKUP"
  printf 'root=LABEL=proxmox9 rw rootwait quiet console=ttyTitania0 console=tty0\n' >"$CMDLINE"
  printf '0x20000000\n' >"$ESP/vram.txt"
  rm -f "$ESP/cmdline.txt.ai" "$ESP/cmdline.txt.default"
}

echo "== syntax =="
for f in "$ROOT"/install.sh "$ROOT"/uninstall.sh "$ROOT"/host/ps5-mode-switch \
  "$ROOT"/host/ps5-mode-ctl "$ROOT"/container/ps5-menu "$ROOT"/container/bashrc-hook; do
  check "bash -n $(basename "$f")" bash -n "$f"
done
if command -v shellcheck >/dev/null 2>&1; then
  for f in "$ROOT"/install.sh "$ROOT"/uninstall.sh "$ROOT"/host/ps5-mode-switch \
    "$ROOT"/host/ps5-mode-ctl "$ROOT"/container/ps5-menu; do
    if shellcheck -S warning -e SC1091 "$f" >"$T/sc.out" 2>&1; then
      ok "shellcheck $(basename "$f")"
    else
      bad "shellcheck $(basename "$f")"
      sed -n '1,12p' "$T/sc.out"
    fi
  done
else
  echo "  skip shellcheck (not installed)"
fi

echo "== mode detection and status =="
reset_state
out=$(run_switch status)
if printf '%s\n' "$out" | grep -qx 'MODE=default'; then ok "status: default detected"; else bad "status: default detected"; fi
if printf '%s\n' "$out" | grep -qx 'GTT_TOTAL_MIB=11264'; then ok "status: GTT total read"; else bad "status: GTT total read"; fi
if printf '%s\n' "$out" | grep -qx 'GTT_USED_MIB=11'; then ok "status: GTT used converted from bytes"; else bad "status: GTT used converted from bytes"; fi
if printf '%s\n' "$out" | grep -qx 'VRAM_TOTAL_MIB=512'; then ok "status: VRAM converted from bytes"; else bad "status: VRAM converted from bytes"; fi
if printf '%s\n' "$out" | grep -qx 'VRAM_TOTAL_MIB=512'; then ok "status: VRAM carve-out converted to MiB"; else bad "status: VRAM carve-out converted to MiB"; fi

reset_state
printf 'root=LABEL=proxmox9 rw quiet ttm.pages_limit=2883584 ttm.page_pool_size=2883584\n' >"$CMDLINE"
out=$(run_switch status)
if printf '%s\n' "$out" | grep -qx 'MODE=ai'; then ok "status: AI detected"; else bad "status: AI detected"; fi
if printf '%s\n' "$out" | grep -qx 'TTM_LIMIT=2883584'; then ok "status: ttm limit reported"; else bad "status: ttm limit reported"; fi

echo "== command line building =="
reset_state
out=$(PS5MODE_DRY_RUN=1 run_switch ai 2>&1)
if printf '%s\n' "$out" | grep -q 'ttm.pages_limit=2883584 ttm.page_pool_size=2883584'; then
  ok "ai: command line gains the 11 GiB ttm pair"
else
  bad "ai: command line gains the 11 GiB ttm pair"
fi
if [ ! -e "$ESP/cmdline.txt.ai" ]; then ok "dry-run: no file written"; else bad "dry-run: no file written"; fi
if ! grep -q '^kexec' "$CALLS"; then ok "dry-run: kexec not run"; else bad "dry-run: kexec not run"; fi

reset_state
printf 'root=LABEL=proxmox9 rw quiet ttm.pages_limit=2883584 ttm.page_pool_size=2883584\n' >"$CMDLINE"
out=$(PS5MODE_DRY_RUN=1 run_switch default 2>&1)
if printf '%s\n' "$out" | grep -q 'Command line: root=LABEL=proxmox9 rw quiet'; then
  ok "default: ttm args stripped"
else
  bad "default: ttm args stripped"
fi
if printf '%s\n' "$out" | grep -q 'ttm\.'; then bad "default: no ttm left"; else ok "default: no ttm left"; fi

echo "== real switch (stubbed) =="
reset_state
run_switch ai >"$T/switch.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "ai switch exits 0" || { bad "ai switch exits 0 (rc=$rc)"; sed -n '1,20p' "$T/switch.out"; }
contains "ai switch: mode file written" "$ESP/cmdline.txt.ai" "ttm.pages_limit=2883584"
contains "ai switch: kexec loaded the kernel" "$CALLS" "kexec -l $ESP/bzImage"
contains "ai switch: kexec scheduled" "$CALLS" "systemd-run --on-active=5"
contains "ai switch: backup recorded" "$STATE/backup-dir" "ps5-mode-backup-"
contains "ai switch: guest 101 shut down" "$CALLS" "pct shutdown 101"
not_contains "ai switch: menu container left for kexec" "$CALLS" "pct shutdown 103"
if [ -f "$(cat "$STATE/backup-dir")/cmdline.txt" ]; then ok "ai switch: cmdline backed up"; else bad "ai switch: cmdline backed up"; fi
kline=$(grep -n 'kexec -l' "$CALLS" 2>/dev/null | head -n1 | cut -d: -f1)
sline=$(grep -n 'pct shutdown' "$CALLS" 2>/dev/null | head -n1 | cut -d: -f1)
if [ -n "$kline" ] && [ -n "$sline" ] && [ "$kline" -lt "$sline" ]; then
  ok "ai switch: kernel loaded before guests stop"
else
  bad "ai switch: kernel loaded before guests stop"
fi

printf 'root=LABEL=proxmox9 rw quiet ttm.pages_limit=2883584 ttm.page_pool_size=2883584\n' >"$CMDLINE"
out=$(run_switch ai 2>&1)
if printf '%s\n' "$out" | grep -q 'Already in ai mode'; then ok "ai switch: idempotent"; else bad "ai switch: idempotent"; fi

echo "== guards =="
reset_state
printf '0x300000000\n' >"$ESP/vram.txt"
out=$(run_switch ai 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'not the 512 MiB default'; then
  ok "guard: non-default VRAM carve-out refused"
else
  bad "guard: non-default VRAM carve-out refused"
fi
printf '0x20000000\n' >"$ESP/vram.txt"

reset_state
printf '0x0\n' >"$ESP/vram.txt"
out=$(PS5MODE_DRY_RUN=1 run_switch ai 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then ok "guard: vram.txt 0x0 accepted as 512 MiB default"; else bad "guard: vram.txt 0x0 accepted as 512 MiB default"; fi
printf '0x20000000\n' >"$ESP/vram.txt"

reset_state
touch "$ESP/bzImage"
out=$(run_switch ai 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'newer than the running kernel'; then
  ok "guard: pending kernel update refused"
else
  bad "guard: pending kernel update refused"
fi
touch -d '30 days ago' "$ESP/bzImage"

reset_state
out=$(PCT_FAIL_ID=101 run_switch ai 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'did not shut down cleanly'; then
  ok "guard: unclean guest shutdown aborts"
else
  bad "guard: unclean guest shutdown aborts"
fi
if ! grep -q 'systemd-run' "$CALLS"; then ok "guard: no kexec after aborted shutdown"; else bad "guard: no kexec after aborted shutdown"; fi

reset_state
printf '0x300000000\n' >"$ESP/vram.txt"
out=$(run_switch default 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then ok "guard: carve-out also refused in default mode"; else bad "guard: carve-out also refused in default mode"; fi
printf '0x20000000\n' >"$ESP/vram.txt"

echo "== rollback =="
reset_state
run_switch ai >/dev/null 2>&1
printf 'root=LABEL=proxmox9 rw quiet ttm.pages_limit=2883584 ttm.page_pool_size=2883584\n' >"$ESP/cmdline.txt"
: >"$CALLS"
run_switch rollback >"$T/rb.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "rollback exits 0" || { bad "rollback exits 0 (rc=$rc)"; sed -n '1,20p' "$T/rb.out"; }
if grep -q 'ttm' "$ESP/cmdline.txt"; then bad "rollback: original cmdline restored"; else ok "rollback: original cmdline restored"; fi
contains "rollback: kexec uses the restored line" "$CALLS" "kexec -l $ESP/bzImage"

echo "== dispatcher =="
printf '#!/bin/sh\necho "switch:$*"\n' >"$T/fake-switch"
chmod +x "$T/fake-switch"
out=$(SSH_ORIGINAL_COMMAND=status PS5MODE_SWITCH_BIN="$T/fake-switch" "$ROOT/host/ps5-mode-ctl")
[ "$out" = "switch:status" ] && ok "ctl: status forwarded" || bad "ctl: status forwarded"
SSH_ORIGINAL_COMMAND='rm -rf /' PS5MODE_SWITCH_BIN="$T/fake-switch" "$ROOT/host/ps5-mode-ctl" >/dev/null 2>&1
[ $? -eq 64 ] && ok "ctl: unknown command refused" || bad "ctl: unknown command refused"
SSH_ORIGINAL_COMMAND='' PS5MODE_SWITCH_BIN="$T/fake-switch" "$ROOT/host/ps5-mode-ctl" >/dev/null 2>&1
[ $? -eq 64 ] && ok "ctl: empty command refused" || bad "ctl: empty command refused"

echo "== container menu =="
CT="$T/ct"
mkdir -p "$CT"
printf '127.0.0.1\n' >"$CT/host"
: >"$CT/id_ed25519"
: >"$CT/known_hosts"
printf '%s\n' 'MODE=ai
MODE_LABEL=AI - 11 GiB GPU / ~3 GiB system RAM
GTT_TOTAL_MIB=11264
GTT_USED_MIB=12
VRAM_TOTAL_MIB=512
RAM_TOTAL_MIB=14468
RAM_AVAIL_MIB=12601
KERNEL=7.2.3
HOSTNAME=ps5pve
UPTIME=2d 3h' >"$T/status.txt"
cat >"$T/bin/ssh" <<EOF
#!/usr/bin/env bash
if [ "\${FAIL_SSH:-0}" = 1 ]; then echo "ssh: connect refused" >&2; exit 255; fi
case "\${@: -1}" in
  status) cat "$T/status.txt" ;;
  details) echo "details from host" ;;
esac
exit 0
EOF
chmod +x "$T/bin/ssh"
menu_out=$(PS5MODE_CT_STATE="$CT" PATH="$BIN:$PATH" "$ROOT/container/ps5-menu" --status)
if printf '%s\n' "$menu_out" | grep -qx 'MODE=ai'; then ok "menu: status parsed"; else bad "menu: status parsed"; fi
FAIL_SSH=1 PS5MODE_CT_STATE="$CT" PATH="$BIN:$PATH" "$ROOT/container/ps5-menu" --status >/dev/null 2>&1
[ $? -ne 0 ] && ok "menu: unreachable host reported" || bad "menu: unreachable host reported"

echo "== installer dry-run =="
: >"$CALLS"
inst_out=$(env \
  PS5SW_DRY_RUN=1 PS5SW_FORCE=1 PS5SW_ALLOW_NONROOT=1 PS5SW_ESP="$ESP" \
  PS5SW_STATE_DIR="$T/statehost" PS5SW_LIB_STATE="$T/libhost" \
  PS5SW_CTID=103 PATH="$BIN:$PATH" \
  bash "$ROOT/install.sh" 2>&1)
if printf '%s\n' "$inst_out" | grep -q 'pct create 103'; then ok "installer: container create planned"; else bad "installer: container create planned"; fi
if printf '%s\n' "$inst_out" | grep -q 'nesting=1'; then ok "installer: console nesting enabled at create"; else bad "installer: console nesting enabled at create"; fi
if printf '%s\n' "$inst_out" | grep -q 'console autologin'; then ok "installer: console autologin planned"; else bad "installer: console autologin planned"; fi
if printf '%s\n' "$inst_out" | grep -q 'Install complete'; then ok "installer: completion message"; else bad "installer: completion message"; fi
if printf '%s\n' "$inst_out" | grep -q 'ERROR'; then bad "installer: no errors"; printf '%s\n' "$inst_out" | grep 'ERROR'; else ok "installer: no errors"; fi
if ! grep -q 'pct create' "$CALLS"; then ok "installer dry-run: pct create not executed"; else bad "installer dry-run: pct create not executed"; fi

inst2=$(env \
  PS5SW_DRY_RUN=1 PS5SW_FORCE=1 PS5SW_ALLOW_NONROOT=1 PS5SW_ESP="$ESP" \
  PS5SW_STATE_DIR="$T/statehost2" PS5SW_LIB_STATE="$T/libhost2" \
  PCT_EXISTS=1 PATH="$BIN:$PATH" \
  bash "$ROOT/install.sh" 2>&1)
if printf '%s\n' "$inst2" | grep -q 'CT 103 already exists'; then ok "installer: existing ps5-mode CT found by name"; else bad "installer: existing ps5-mode CT found by name"; fi
if printf '%s\n' "$inst2" | grep -q 'would enable nesting'; then ok "installer: existing CT nesting planned"; else bad "installer: existing CT nesting planned"; fi
if printf '%s\n' "$inst2" | grep -q 'pct create'; then bad "installer: existing CT not recreated"; else ok "installer: existing CT not recreated"; fi

echo
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

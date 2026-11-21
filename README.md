# PS5 Proxmox RAM/VRAM mode switcher

A one-command installer for a small Proxmox LXC container whose **Shell** opens
a menu that switches your PS5 Proxmox node between:

| Mode | GPU memory ceiling | What it is for |
|---|---|---|
| **DEFAULT** | stock (no `ttm` kernel args) | Minecraft servers, VMs, general Proxmox work |
| **AI** | `ttm.pages_limit=2883584 ttm.page_pool_size=2883584` = **11264 MiB (11 GiB) GTT** + the 512 MiB VRAM carve-out | running large local models on the PS5 GPU |

The switch uses **kexec** of the same kernel with a different command line. The
PS5 itself stays powered on; Linux does a clean systemd shutdown and comes back
in about two minutes. Every VM and container stops, and `onboot` guests return
with the new split.

This is the method proven on the node on 2026-11-17/18. It does **not** touch
`/boot/efi/cmdline.txt` or `vram.txt`, so a cold PS5 boot always returns to the
stock default.

## Install

On the **Proxmox host** (not inside a container), as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ps5-proxmox-mode-switcher/main/install.sh)"
```

It prints a plan and asks once. It then:

1. Backs up the current boot configuration to `/root/ps5-mode-backup-<time>/`.
2. Installs `/usr/local/sbin/ps5-mode-switch` and a restricted SSH bridge.
3. Creates CT `ps5-mode` (Debian 13, unprivileged, 1 core, 256 MB, 2 GB) and
   starts it.
4. Tests the container-to-host bridge and prints the container ID.

Requirements: Proxmox VE on the PS5 node, `/boot/efi` with `bzImage` and
`initrd.img`, `kexec-tools` (installed automatically if missing), and internet
access for the Debian template and two container packages.

### Options

Set environment variables before the one-liner:

| Variable | Default | Meaning |
|---|---|---|
| `PS5SW_CTID` | next free ID | container ID |
| `PS5SW_IP` / `PS5SW_GW` | DHCP | static address, e.g. `192.168.0.60` / `192.168.0.1` |
| `PS5SW_STORAGE` | auto | root-disk storage |
| `PS5SW_TEMPLATE_STORAGE` | auto | template storage |
| `PS5SW_BRIDGE` | `vmbr0` | network bridge |
| `PS5SW_HOST_IP` | auto | address the container uses to reach the host |
| `PS5SW_MEMORY` / `PS5SW_DISK` | `256` / `2` | container size |
| `PS5SW_YES=1` | off | skip the confirmation |
| `PS5SW_DRY_RUN=1` | off | print every action, change nothing |
| `PS5SW_REPIN=1` | off | re-pin the key after the container's IP changed |

## Use

Web UI > node > **CT `ps5-mode`** (the installer prints its ID) > **Shell**.

The menu starts automatically and shows the live mode, GPU ceiling, RAM and
host. Choose:

1. **DEFAULT mode** — Minecraft / VMs / general use.
2. **AI mode** — 11 GB VRAM / ~3 GB system RAM.
3. **Details / refresh.**
4. **Exit to normal bash shell** (type `ps5-menu` to come back).

After a switch the container stops with the host and returns on boot. Reopen the
Shell after about two minutes.

Host-side commands:

```bash
ps5-mode-switch status      # key=value state
ps5-mode-switch details     # human-readable
ps5-mode-switch ai          # switch from a host shell
ps5-mode-switch default
ps5-mode-switch rollback    # restore the original cmdline.txt/vram.txt, then kexec
```

## What "11 GB VRAM" means

The PS5 GPU uses system RAM. The `ttm.pages_limit` value is a **ceiling**, not a
reservation:

- **DEFAULT**: no `ttm` args; amdgpu takes its stock limit (about half of RAM).
  The GPU can still use several GB, but leaves the rest for VMs and containers.
- **AI**: the GPU may claim up to 11 GiB of the same 14468 MiB pool. With a
  large model loaded, roughly 3 GiB is left for Proxmox. At idle, RAM is free
  in both modes.

Consequences in AI mode: CT 101 (ollama, memory 12288) and VM 100 (11012 MB)
can start, but a loaded model plus their own memory will not fit. The switcher
prints a warning for every `onboot` guest larger than 3 GB.

The 512 MiB VRAM carve-out (`vram.txt`) is separate and stays at its default.
A larger carve-out is rejected by the switcher: it takes RAM away at cold boot
and makes both modes unsafe.

## Safety

- Backups: `/root/ps5-mode-backup-<time>/` holds `cmdline.txt`, `vram.txt`,
  the running `/proc/cmdline`, `uname -a`, `pveversion -v` and the guest list.
- Rollback: `ps5-mode-switch rollback` copies the backup back and kexecs it.
  A cold PS5 boot is always the stock default regardless.
- The switcher refuses to run if a guest does not shut down cleanly. It never
  force-stops a VM or container.
- It refuses if `/boot/efi/bzImage` is newer than the running kernel (a kernel
  update is pending), because kexec would boot a kernel the running modules do
  not match.
- Every switch and every boot is logged to `/var/log/ps5-mode.log`.
- The container's SSH key is pinned to `command="/usr/local/sbin/ps5-mode-ctl",
  restrict,from="<container IP>"`. It can only run `status`, `details`, `ai`,
  `default` or `rollback` — no shell, no pty, no forwarding.

## Troubleshooting

**Pasted command breaks with `$'\E[200~curl'`** — the Proxmox web shell sometimes
prefixes pasted text with a bracketed-paste marker. Type
`bind 'set enable-bracketed-paste off'` and press Enter, then paste again.

**Menu says the host is unreachable** — the container's IP changed (DHCP) and
the key is pinned to the old one. Re-pin:

```bash
PS5SW_CTID=<id> PS5SW_REPIN=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ps5-proxmox-mode-switcher/main/install.sh)"
```

A static address (`PS5SW_IP`) avoids this.

**A switch failed after guests stopped** — start the guests again; nothing was
changed. Read `/var/log/ps5-mode.log` for the exact error.

**Kernel update pending** — reboot the PS5 through the loader first. The
switcher will not kexec a newer kernel than the running one.

## Uninstall

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevenjc2009-byte/ps5-proxmox-mode-switcher/main/uninstall.sh)"
```

Removes the container, host scripts, unit and key. Keeps backups and the log.
It never touches `/boot/efi`.

## Files

```
install.sh                        installer
uninstall.sh                      uninstaller
host/ps5-mode-switch              host switcher (kexec, guards, rollback)
host/ps5-mode-ctl                 forced-command dispatcher
host/ps5-mode-verify.service      logs the mode after every boot
container/ps5-menu                whiptail menu, plain fallback
container/bashrc-hook             auto-launch snippet
tests/run-tests.sh                offline logic tests
```

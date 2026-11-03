#!/bin/bash
# Arch VM first-boot provisioning (runs INSIDE the guest).
#
# This script never touches the Unraid host. It is handed to the guest as a
# systemd credential via SMBIOS OEM strings (see quick_archvm.sh) and run by
# quick_archvm-provision.service, which systemd creates from the credential
# "systemd.extra-unit.quick_archvm-provision.service".
#
# It runs once: on success it writes /var/lib/quick_archvm/provisioned and the unit
# is skipped from then on. If it fails (no network yet, mirror down, ...) it
# retries every 30 seconds and again on the next boot.

set -uo pipefail

CRED="${CREDENTIALS_DIRECTORY:-/run/credentials/quick_archvm-provision.service}"
log() { echo "quick_archvm-provision: $*"; }

# 1. Hostname (taken from the VM name)
if [[ -s "$CRED/quick_archvm.hostname" ]]; then
  # systemd already applied it at boot (system.hostname credential); persist
  # it in /etc/hostname so it survives the credentials being removed later
  name=$(<"$CRED/quick_archvm.hostname")
  log "setting hostname to $name"
  printf '%s\n' "$name" >/etc/hostname
  hostnamectl hostname "$name" || log "WARNING: could not set hostname"
fi

# 2. Optional SSH public key for the default 'arch' user
if [[ -s "$CRED/quick_archvm.ssh-key" ]] && id arch &>/dev/null; then
  home=$(getent passwd arch | cut -d: -f6)
  install -d -m 700 -o arch -g arch "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  key=$(<"$CRED/quick_archvm.ssh-key")
  if ! grep -qxF "$key" "$home/.ssh/authorized_keys"; then
    log "adding SSH key for user arch"
    printf '%s\n' "$key" >>"$home/.ssh/authorized_keys"
  fi
  chown arch:arch "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
fi

# 3. Grow the root partition + filesystem to the full virtual disk size
#    (the image is 40 GiB; the vdisk may have been created larger).
grow_root() {
  local src dev part disk num fstype
  src=$(findmnt -no SOURCE / | sed 's/\[.*\]$//')        # /dev/vda3 (strip btrfs [/subvol])
  dev=$(basename "$src")
  part=/sys/class/block/$dev/partition
  [[ -r $part ]] || { log "root is not on a partition, not growing"; return 0; }
  num=$(<"$part")
  disk=/dev/$(lsblk -no PKNAME "$src" | head -n1)
  fstype=$(findmnt -no FSTYPE /)
  # move the backup GPT header to the (new) end of the disk, then grow
  sfdisk --relocate gpt-bak-std "$disk" &>/dev/null || true
  if echo ', +' | sfdisk --no-reread --no-tell-kernel -q -N "$num" "$disk" &>/dev/null; then
    partx -u -n "$num" "$disk" || true
  fi
  case $fstype in
    btrfs) btrfs filesystem resize max / >/dev/null ;;
    ext4)  resize2fs "$src" >/dev/null ;;
    xfs)   xfs_growfs / >/dev/null ;;
  esac
  log "root filesystem: $(df -h --output=size / | tail -n1 | tr -d ' ')"
}
grow_root || log "WARNING: could not grow the root filesystem"

# 4. qemu-guest-agent: recent official images already ship it, older ones
#    don't. Install it only when it is missing.
if ! pacman -Q qemu-guest-agent &>/dev/null; then
  # wait for working DNS (network-online.target is not always enough)
  for _ in $(seq 1 60); do
    getent hosts archlinux.org &>/dev/null && break
    sleep 2
  done
  # pacman keyring (normally done by the image's own pacman-init.service)
  if [[ ! -s /etc/pacman.d/gnupg/pubring.gpg && ! -s /etc/pacman.d/gnupg/pubring.kbx ]]; then
    log "initialising pacman keyring"
    pacman-key --init && pacman-key --populate archlinux || exit 1
  fi
  # refresh the keyring first (avoids signature errors on older images), then
  # do a full upgrade together with the install (Arch does not support
  # partial upgrades)
  log "refreshing archlinux-keyring"
  pacman -Sy --noconfirm --needed archlinux-keyring || exit 1
  log "upgrading system and installing qemu-guest-agent"
  pacman -Su --noconfirm --needed qemu-guest-agent || exit 1
else
  log "qemu-guest-agent is already installed"
fi

# 5. Make sure the agent runs now and on every boot. The package's udev rule
#    starts it when the virtio channel appears; enabling is a no-op for a
#    static unit but covers future packaging changes.
systemctl enable qemu-guest-agent.service &>/dev/null || true
udevadm trigger --subsystem-match=virtio-ports --action=add &>/dev/null || true
systemctl start qemu-guest-agent.service || log "WARNING: qemu-guest-agent did not start"

mkdir -p /var/lib/quick_archvm
date -Is >/var/lib/quick_archvm/provisioned
log "done"
exit 0

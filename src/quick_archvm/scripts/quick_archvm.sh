#!/bin/bash
# quick_archvm.sh - create an Arch Linux VM on Unraid from the official
# Arch Linux "basic" cloud image, with qemu-guest-agent installed on first boot.
#
# Usage:
#   quick_archvm.sh --name NAME [--cpus N] [--memory-gb N] [--disk-gb N]
#                    [--pinning auto|none] [--ssh-key "ssh-ed25519 ..."]
#                    [--start] [--dry-run]
#
# Called by the web UI (via scripts/quick_archvm_create), but works from a shell too.

set -uo pipefail
umask 022

PLUGIN=quick_archvm
PLUGIN_DIR=/usr/local/emhttp/plugins/$PLUGIN
# the two config paths can be overridden for tests (tests/run.sh)
CFG_FILE=${QUICK_ARCHVM_CFG:-/boot/config/plugins/$PLUGIN/$PLUGIN.cfg}
DOMAIN_CFG=${QUICK_ARCHVM_DOMAIN_CFG:-/boot/config/domain.cfg}
NVRAM_DIR=/etc/libvirt/qemu/nvram
OVMF_CODE=/usr/share/qemu/ovmf-x64/OVMF_CODE-pure-efi.fd
OVMF_VARS=/usr/share/qemu/ovmf-x64/OVMF_VARS-pure-efi.fd
LOCK=/var/run/$PLUGIN.lock
MIN_DISK_GB=40   # virtual size of the official image; shrinking is not supported

# ---------------------------------------------------------------- helpers ---
say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*"; exit 1; }

# read KEY="value" from a cfg file without sourcing it
cfg_get() { # file key default
  local v
  # tr strips Windows line endings (file edited over the flash share)
  v=$({ tr -d '\r' <"$1"; } 2>/dev/null | sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" | tail -n1)
  printf '%s' "${v:-$3}"
}

xml_escape() {
  local s=$1
  # replacements are quoted: since bash 5.2 an unquoted '&' in the replacement
  # means "the matched text" (patsub_replacement), which breaks the escaping
  s=${s//&/"&amp;"}; s=${s//</"&lt;"}; s=${s//>/"&gt;"}; s=${s//\"/"&quot;"}; s=${s//\'/"&apos;"}
  printf '%s' "$s"
}

b64() { base64 -w0; }

# Pick the VM's IPv4 address from "virsh domifaddr --source agent" output.
# Prefers the interface with the VM's own MAC ($1); otherwise any address that
# is not loopback (127.x) or link-local (169.254.x). Lines that continue an
# interface (extra addresses) show "-" in the name and MAC columns.
vm_ipv4() {
  awk -v mac="$(tr 'A-F' 'a-f' <<<"$1")" '
    NR <= 2 { next }                                  # header + separator
    { if ($2 != "-") cur = tolower($2) }
    $3 == "ipv4" {
      split($4, a, "/"); ip = a[1]
      if (ip ~ /^127\./ || ip ~ /^169\.254\./) next
      if (cur == mac && own == "") own = ip
      if (any == "") any = ip
    }
    END { print (own != "" ? own : any) }'
}

# tests/run.sh sources the script with this set to get only the helpers above
[[ ${QUICK_ARCHVM_SOURCE_ONLY:-} == 1 ]] && return 0

# ------------------------------------------------------------- arguments ---
NAME="" CPUS="" MEM_GB="" DISK_GB="" PINNING="" SSH_KEY="" START=no DRYRUN=no
while [[ $# -gt 0 ]]; do
  case $1 in
    --name)      NAME=${2-};    shift 2 ;;
    --cpus)      CPUS=${2-};    shift 2 ;;
    --memory-gb) MEM_GB=${2-};  shift 2 ;;
    --disk-gb)   DISK_GB=${2-}; shift 2 ;;
    --pinning)   PINNING=${2-}; shift 2 ;;
    --ssh-key)   SSH_KEY=${2-}; shift 2 ;;
    --start)     START=yes;     shift ;;
    --dry-run)   DRYRUN=yes;    shift ;;
    -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

# --------------------------------------------------------------- config ---
IMAGE_URL=$(cfg_get "$CFG_FILE" IMAGE_URL "https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-basic.qcow2")
DOMAINDIR=$(cfg_get "$DOMAIN_CFG" DOMAINDIR "/mnt/user/domains/")
VM_DIR=$(cfg_get "$CFG_FILE" VM_DIR "$DOMAINDIR")
VM_DIR=${VM_DIR%/}
CACHE_DIR=$(cfg_get "$CFG_FILE" CACHE_DIR "$VM_DIR/.quick_archvm-cache")
CACHE_DIR=${CACHE_DIR%/}
BRIDGE=$(cfg_get "$CFG_FILE" BRIDGE "$(cfg_get "$DOMAIN_CFG" BRNAME virbr0)")
KEYMAP=$(cfg_get "$CFG_FILE" KEYMAP "")
CPUS=${CPUS:-$(cfg_get "$CFG_FILE" DEFAULT_CPUS 2)}
MEM_GB=${MEM_GB:-$(cfg_get "$CFG_FILE" DEFAULT_MEMORY_GB 4)}
DISK_GB=${DISK_GB:-$(cfg_get "$CFG_FILE" DEFAULT_DISK_GB $MIN_DISK_GB)}
PINNING=${PINNING:-$(cfg_get "$CFG_FILE" CPU_PINNING auto)}
[[ $DRYRUN == yes ]] && { VM_DIR=${QUICK_ARCHVM_TEST_DIR:-/tmp/quick_archvm-dryrun}; CACHE_DIR=$VM_DIR/.quick_archvm-cache; }

# ----------------------------------------------------------- validation ---
[[ $NAME =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,62}$ ]] ||
  die "invalid VM name '$NAME' (letters, digits, space, . _ - ; max 63 chars)"
{ [[ $CPUS =~ ^[0-9]+$ ]] && (( CPUS >= 1 )); } || die "invalid CPU count '$CPUS'"
{ [[ $MEM_GB =~ ^[0-9]+$ ]] && (( MEM_GB >= 1 )); } || die "invalid memory size '$MEM_GB' GiB"
[[ $DISK_GB =~ ^[0-9]+$ ]] || die "invalid disk size '$DISK_GB' GiB"
(( DISK_GB >= MIN_DISK_GB )) || die "disk size must be at least ${MIN_DISK_GB} GiB (size of the Arch image)"
[[ $PINNING == auto || $PINNING == none ]] || die "--pinning must be 'auto' or 'none'"
if [[ -n $SSH_KEY ]]; then
  SSH_KEY=$(printf '%s' "$SSH_KEY" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ $SSH_KEY != *$'\n'* && $SSH_KEY =~ ^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.-]+\ [A-Za-z0-9+/=]+(\ .*)?$ ]] ||
    die "the SSH key does not look like a single OpenSSH public key line"
fi

HOST_CPUS=$(nproc --all)
(( CPUS <= HOST_CPUS )) || die "requested $CPUS vCPUs but the host only has $HOST_CPUS"
HOST_MEM_GB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
(( MEM_GB < HOST_MEM_GB )) || die "requested ${MEM_GB} GiB RAM but the host only has ~${HOST_MEM_GB} GiB"

# guest hostname derived from the VM name
HOSTNAME_G=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g;s/--*/-/g;s/^-//;s/-$//' | cut -c1-63)
HOSTNAME_G=${HOSTNAME_G%-}; HOSTNAME_G=${HOSTNAME_G:-arch}

if [[ $DRYRUN == no ]]; then
  { command -v virsh >/dev/null && [[ -e /var/run/libvirt/libvirtd.pid ]]; } ||
    die "the VM service (libvirt) is not running - enable it under Settings > VM Manager"
  virsh dominfo "$NAME" &>/dev/null && die "a VM named '$NAME' already exists"
  [[ -r $OVMF_VARS && -r $OVMF_CODE ]] || die "OVMF firmware not found in /usr/share/qemu/ovmf-x64"
  [[ -d ${VM_DIR} ]] || die "VM storage path '$VM_DIR' does not exist (check Settings > VM Manager)"
fi

VDISK_DIR="$VM_DIR/$NAME"
VDISK="$VDISK_DIR/vdisk1.qcow2"
[[ -e $VDISK ]] && die "'$VDISK' already exists - remove it or choose another name"

# the braces keep 2>/dev/null to this one exec; a bare "exec ... 2>/dev/null"
# would silence stderr for the rest of the script
{ exec 9>"$LOCK"; } 2>/dev/null || exec 9>/dev/null
flock -n 9 || die "another Arch VM is being created right now - try again when it has finished"

# cleanup on failure
CREATED_DISK="" CREATED_DIR="" CREATED_NVRAM="" DEFINED=""
# shellcheck disable=SC2317  # only called via trap
cleanup() {
  local rc=$?
  if (( rc != 0 )) && [[ -z $DEFINED ]]; then
    [[ -n $CREATED_DISK  ]] && rm -f -- "$CREATED_DISK"
    [[ -n $CREATED_NVRAM ]] && rm -f -- "$CREATED_NVRAM"
    [[ -n $CREATED_DIR   ]] && rmdir -- "$CREATED_DIR" 2>/dev/null
    rm -f -- "${CACHE_DIR}/.download.part"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'die "interrupted"' INT TERM

say "Creating Arch Linux VM '$NAME'"
say "  vCPUs: $CPUS   RAM: ${MEM_GB} GiB   disk: ${DISK_GB} GiB   network: $BRIDGE"
say "  location: $VDISK_DIR"

# ---------------------------------------------------------- base image ---
step "Checking for the latest Arch Linux basic image"
mkdir -p -- "$CACHE_DIR" || die "cannot create cache directory $CACHE_DIR"
CACHED="$CACHE_DIR/$(basename "$IMAGE_URL")"
REMOTE_SHA=$(curl -fsSL --retry 3 --connect-timeout 15 "$IMAGE_URL.SHA256" | awk '{print $1}')
LOCAL_SHA=$(cat -- "$CACHED.sha256" 2>/dev/null)
if [[ ! $REMOTE_SHA =~ ^[0-9a-f]{64}$ ]]; then
  [[ -s $CACHED && -n $LOCAL_SHA ]] || die "could not reach $IMAGE_URL.SHA256 and no cached image exists"
  say "WARNING: could not check for updates, using cached image"
elif [[ -s $CACHED && $LOCAL_SHA == "$REMOTE_SHA" ]]; then
  say "cached image is up to date"
else
  say "downloading $IMAGE_URL"
  # --progress-bar writes \r-terminated updates which the web UI renders in place
  curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "$CACHE_DIR/.download.part" "$IMAGE_URL" 2>&1 |
    tr '\r' '\n' | awk '/%/{ if (int($NF) >= last+5 || $NF ~ /100/) { printf "  %s\r", $NF; last=int($NF) } } END{ print "" }'
  [[ ${PIPESTATUS[0]} -eq 0 ]] || die "download failed"
  say "verifying checksum"
  GOT=$(sha256sum "$CACHE_DIR/.download.part" | awk '{print $1}')
  [[ $GOT == "$REMOTE_SHA" ]] || die "checksum mismatch (expected $REMOTE_SHA, got $GOT)"
  mv -f -- "$CACHE_DIR/.download.part" "$CACHED" && printf '%s\n' "$REMOTE_SHA" >"$CACHED.sha256"
  say "image cached at $CACHED"
fi
IMG_VERSION=$(curl -fsSL --connect-timeout 10 "$(dirname "$IMAGE_URL")/" 2>/dev/null |
  grep -o 'Arch-Linux-x86_64-basic-[0-9.]*\.qcow2"' | head -n1 | sed 's/.*basic-\([0-9]*\)\..*/\1/')

# ---------------------------------------------------------------- vdisk ---
step "Creating virtual disk"
[[ -d $VDISK_DIR ]] || { mkdir -p -- "$VDISK_DIR" || die "cannot create $VDISK_DIR"; CREATED_DIR=$VDISK_DIR; }
CREATED_DISK=$VDISK
qemu-img convert -p -O qcow2 -o preallocation=off -- "$CACHED" "$VDISK" 2>&1 |
  tr '\r' '\n' | awk '/%\)/{ gsub(/[()]/,""); v=int($1); if (v >= last+10 && v < 100) { printf "  %d%%\r", v; last=v } } END{ print "  100%" }'
[[ ${PIPESTATUS[0]} -eq 0 ]] || die "qemu-img convert failed"
if (( DISK_GB > MIN_DISK_GB )); then
  qemu-img resize -q -- "$VDISK" "${DISK_GB}G" || die "qemu-img resize failed"
fi
say "created $VDISK (${DISK_GB} GiB, thin provisioned)"

# -------------------------------------------------------- CPU selection ---
# Returns the host CPUs to pin to. "auto" prefers whole physical cores
# (hyperthread pairs), starting from the highest core, and leaves core 0
# (which Unraid itself uses most) free whenever possible.
PINS=() THREADS=1
expand_cpulist() { # "0-3,8" -> "0 1 2 3 8"
  local out=() p parts
  IFS=, read -ra parts <<<"$1"
  for p in "${parts[@]}"; do
    [[ -z $p ]] && continue
    if [[ $p == *-* ]]; then mapfile -t -O "${#out[@]}" out < <(seq "${p%-*}" "${p#*-}"); else out+=("$p"); fi
  done
  echo "${out[*]}"
}
if [[ $PINNING == auto && -r /sys/devices/system/cpu/cpu0/topology/thread_siblings_list ]]; then
  declare -A SEEN=()
  CORES=()
  for f in /sys/devices/system/cpu/cpu[0-9]*/topology/thread_siblings_list; do
    l=$(<"$f"); [[ -n ${SEEN[$l]:-} ]] && continue; SEEN[$l]=1
    CORES+=("$(expand_cpulist "$l")")
  done
  mapfile -t CORES < <(printf '%s\n' "${CORES[@]}" | sort -n -k1,1)
  ISOLATED=" $(expand_cpulist "$(cat /sys/devices/system/cpu/isolated 2>/dev/null)") "
  TPC=$(wc -w <<<"${CORES[0]}")   # threads per core
  # order: isolated cores (highest first), other cores (highest first), core 0 last
  ISO=() REST=()
  for (( i=${#CORES[@]}-1; i>=1; i-- )); do
    first=${CORES[$i]%% *}
    if [[ $ISOLATED == *" $first "* ]]; then ISO+=("${CORES[$i]}"); else REST+=("${CORES[$i]}"); fi
  done
  for c in "${ISO[@]}" "${REST[@]}" "${CORES[0]}"; do
    for t in $c; do (( ${#PINS[@]} < CPUS )) && PINS+=("$t"); done
  done
  # use an SMT topology only when every selected core is fully used
  (( TPC > 1 && CPUS % TPC == 0 )) && THREADS=$TPC
fi
CORES_TOPO=$(( CPUS / THREADS ))

# ------------------------------------------------------------ libvirt XML ---
step "Generating VM definition"
UUID=$(cat /proc/sys/kernel/random/uuid)
# random MAC with QEMU's prefix, re-rolled until no existing VM uses it
USED_MACS=""
if [[ $DRYRUN == no ]]; then
  USED_MACS=$(virsh list --all --uuid 2>/dev/null | while read -r u; do
    [[ -n $u ]] && virsh dumpxml "$u" 2>/dev/null; done |
    grep -o "mac address='[0-9a-fA-F:]*'" | cut -d"'" -f2 | tr 'A-F' 'a-f')
fi
for _ in $(seq 1 100); do
  MAC=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
  grep -qxF "$MAC" <<<"$USED_MACS" || break
done
grep -qxF "$MAC" <<<"$USED_MACS" && die "could not find an unused MAC address"
NVRAM="$NVRAM_DIR/${UUID}_VARS-pure-efi.fd"
MEM_KIB=$(( MEM_GB * 1024 * 1024 ))
if [[ $DRYRUN == no ]]; then
  MACHINE=$(virsh capabilities 2>/dev/null | grep -o 'pc-q35-[0-9][0-9.]*' | sort -uV | tail -n1)
else
  MACHINE=pc-q35-9.2
fi
MACHINE=${MACHINE:-q35}

# systemd credentials passed via SMBIOS type 11 (OEM strings). systemd >= 256
# in the guest turns "systemd.extra-unit.*" into a unit file and
# "systemd.unit-dropin.*" into a drop-in, so the guest provisions itself on
# first boot without us ever mounting the image on the host.
PROVISION_UNIT=$(cat <<'EOF'
[Unit]
Description=Unraid Arch VM first-boot provisioning
Wants=network-online.target
After=network-online.target pacman-init.service systemd-resolved.service
ConditionPathExists=!/var/lib/quick_archvm/provisioned
StartLimitIntervalSec=0

[Service]
Type=oneshot
ImportCredential=quick_archvm.*
ExecStart=/bin/bash %d/quick_archvm.provision
Restart=on-failure
RestartSec=30
TimeoutStartSec=30min
EOF
)
DROPIN=$'[Unit]\nWants=quick_archvm-provision.service\n'

oem() { printf '      <entry>io.systemd.credential.binary:%s=%s</entry>\n' "$1" "$(printf '%s' "$2" | b64)"; }
OEM_STRINGS=$(
  oem systemd.extra-unit.quick_archvm-provision.service "$PROVISION_UNIT"
  oem systemd.unit-dropin.multi-user.target~quick_archvm "$DROPIN"
  oem quick_archvm.provision "$(cat "$PLUGIN_DIR/include/guest-provision.sh" 2>/dev/null || cat "$(dirname "$0")/../include/guest-provision.sh")"
  oem quick_archvm.hostname "$HOSTNAME_G"
  oem system.hostname "$HOSTNAME_G"
  [[ -n $SSH_KEY ]] && oem quick_archvm.ssh-key "$SSH_KEY"
)
[[ $OEM_STRINGS == *quick_archvm.provision=I* ]] || die "guest-provision.sh not found"

CPUTUNE=""
if (( ${#PINS[@]} == CPUS )); then
  CPUTUNE="  <cputune>"$'\n'
  for (( i=0; i<CPUS; i++ )); do CPUTUNE+="    <vcpupin vcpu='$i' cpuset='${PINS[$i]}'/>"$'\n'; done
  CPUTUNE+="  </cputune>"
fi
KEYMAP_ATTR=""; [[ $KEYMAP =~ ^[a-z]{2}(-[a-z]{2,3})?$ ]] && KEYMAP_ATTR=" keymap='$KEYMAP'"
DESC="Arch Linux (official basic image${IMG_VERSION:+ $IMG_VERSION}) - default login arch/arch"

XML_FILE=$(mktemp /tmp/quick_archvm-XXXXXX.xml)
cat >"$XML_FILE" <<EOF
<domain type='kvm'>
  <name>$(xml_escape "$NAME")</name>
  <uuid>$UUID</uuid>
  <description>$(xml_escape "$DESC")</description>
  <metadata>
    <vmtemplate xmlns="http://unraid" name="Arch" icon="arch.png" os="arch" webui="" storage="default"/>
  </metadata>
  <memory unit='KiB'>$MEM_KIB</memory>
  <currentMemory unit='KiB'>$MEM_KIB</currentMemory>
  <memoryBacking>
    <nosharepages/>
  </memoryBacking>
  <vcpu placement='static'>$CPUS</vcpu>
$CPUTUNE
  <sysinfo type='smbios'>
    <oemStrings>
$OEM_STRINGS
    </oemStrings>
  </sysinfo>
  <os>
    <type arch='x86_64' machine='$MACHINE'>hvm</type>
    <loader readonly='yes' type='pflash' format='raw'>$OVMF_CODE</loader>
    <nvram format='raw'>$(xml_escape "$NVRAM")</nvram>
    <smbios mode='sysinfo'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'>
    <topology sockets='1' dies='1' clusters='1' cores='$CORES_TOPO' threads='$THREADS'/>
    <cache mode='passthrough'/>
  </cpu>
  <clock offset='utc'>
    <timer name='hpet' present='no'/>
    <timer name='hypervclock' present='no'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='rtc' tickpolicy='catchup'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>
  <devices>
    <emulator>/usr/local/sbin/qemu</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='writeback' discard='unmap'/>
      <source file='$(xml_escape "$VDISK")'/>
      <target dev='hdc' bus='virtio'/>
      <serial>vdisk1</serial>
      <boot order='1'/>
    </disk>
    <controller type='usb' index='0' model='qemu-xhci' ports='15'/>
    <controller type='virtio-serial' index='0'/>
    <interface type='bridge'>
      <mac address='$MAC'/>
      <source bridge='$(xml_escape "$BRIDGE")'/>
      <model type='virtio-net'/>
    </interface>
    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <channel type='qemu-vdagent'>
      <source>
        <clipboard copypaste='yes'/>
        <mouse mode='client'/>
      </source>
      <target type='virtio' name='com.redhat.spice.0'/>
    </channel>
    <input type='tablet' bus='usb'/>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
    <graphics type='vnc' port='-1' autoport='yes' websocket='-1' listen='0.0.0.0'$KEYMAP_ATTR sharePolicy='ignore'>
      <listen type='address' address='0.0.0.0'/>
    </graphics>
    <audio id='1' type='none'/>
    <video>
      <model type='qxl' ram='65536' vram='16384' vgamem='16384' heads='1' primary='yes'/>
    </video>
    <watchdog model='itco' action='reset'/>
    <memballoon model='virtio'/>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
  </devices>
</domain>
EOF
sed -i '/^$/d' "$XML_FILE"

if [[ $DRYRUN == yes ]]; then
  say "dry run - XML written to $XML_FILE"
  DEFINED=dry
  exit 0
fi

# --------------------------------------------------------------- define ---
mkdir -p -- "$NVRAM_DIR"
cp -- "$OVMF_VARS" "$NVRAM" || die "cannot create NVRAM file"
CREATED_NVRAM=$NVRAM
if ! OUT=$(virsh define "$XML_FILE" 2>&1); then
  say "$OUT"; rm -f -- "$XML_FILE"
  die "virsh define failed"
fi
rm -f -- "$XML_FILE"
DEFINED=yes
say "VM '$NAME' defined (UUID $UUID)"
[[ -n $CPUTUNE ]] && say "pinned to host CPUs: ${PINS[*]}"

# ---------------------------------------------------------------- start ---
if [[ $START == yes ]]; then
  step "Starting VM"
  if ! OUT=$(virsh start "$NAME" 2>&1); then
    say "$OUT"
    die "the VM was created but failed to start (see the message above); fix the cause and start it from the VMs tab"
  fi
  say "VM started. Waiting for the guest agent (first boot installs it, up to 10 minutes)..."
  for (( i=0; i<120; i++ )); do
    if virsh qemu-agent-command "$NAME" '{"execute":"guest-ping"}' &>/dev/null; then
      printf '\n'; say "guest agent is up"
      # The agent reports every interface, loopback first, and may come up
      # before DHCP has finished, so retry for up to 60 s.
      IP=""
      for (( j=0; j<20; j++ )); do
        IP=$(virsh domifaddr --source agent "$NAME" 2>/dev/null | vm_ipv4 "$MAC")
        [[ -n $IP ]] && break
        sleep 3
      done
      if [[ -n $IP ]]; then
        say "IP address: $IP   (ssh arch@$IP, password: arch)"
      else
        say "no IP address yet (DHCP still running?) - it will show on the VMs tab once assigned"
      fi
      break
    fi
    printf '  %ds\r' $(( i*5 )); sleep 5
  done
  (( i < 120 )) || { printf '\n'; say "The guest agent is not up yet. That is not an error: on slow"
                     say "connections the first-boot upgrade can take longer. It keeps retrying in the guest."; }
fi

step "Done"
say "Default login: user 'arch', password 'arch' (change it with 'passwd')."
exit 0

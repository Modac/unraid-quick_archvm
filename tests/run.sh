#!/bin/bash
# quick_archvm test suite - runs without Unraid, libvirt or network access.
#
#   tests/run.sh
#
# Needs: bash, coreutils, curl. Optional (tests are skipped without them):
# ShellCheck, php (+ node for the JS check), xmllint, virt-xml-validate, qemu-img.
# With CI=true the web UI page is rendered too; that needs sudo to create
# /var/run/libvirt/libvirtd.pid and /boot/config/plugins/quick_archvm/quick_archvm.cfg.
# PHP snippets below are single-quoted on purpose (PHP variables, not shell)
# shellcheck disable=SC2016
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
SRC=$ROOT/src/quick_archvm
WORKER=$SRC/scripts/quick_archvm.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

PASS=0 FAIL=0 SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [[ -n ${2:-} ]] && printf '        %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  skip  %s\n' "$1"; }
eq()   { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "missing: $3"; fi; }
have() { command -v "$1" >/dev/null; }
section() { printf '\n%s\n' "$1"; }

# default cfg exactly as the installer writes it (taken from build.sh)
default_cfg() { sed -n "/^cat > \"\$C\/quick_archvm.cfg\" <<'CFG'$/,/^CFG$/p" build.sh | sed '1d;$d'; }

# ------------------------------------------------------------------------------
section "static checks"
for f in "$WORKER" "$SRC/include/guest-provision.sh" build.sh tests/run.sh; do
  if bash -n "$f"; then ok "bash -n ${f#"$ROOT"/}"; else bad "bash -n ${f#"$ROOT"/}"; fi
done
if have shellcheck; then
  if out=$(shellcheck "$WORKER" "$SRC/include/guest-provision.sh" build.sh tests/run.sh 2>&1); then
    ok "shellcheck"; else bad "shellcheck" "$out"; fi
else skip "shellcheck (not installed)"; fi
if have php; then
  for f in "$SRC/include/ArchVM.php" "$SRC/scripts/quick_archvm_create"; do
    if php -l "$f" >/dev/null 2>&1; then ok "php -l ${f#"$ROOT"/}"; else bad "php -l ${f#"$ROOT"/}"; fi
  done
else skip "php lint (php not installed)"; fi
if out=$(./build.sh --check 2>&1); then ok "quick_archvm.plg matches the sources"; else bad "quick_archvm.plg matches the sources" "$out"; fi

# ------------------------------------------------------------------------------
section "helpers in quick_archvm.sh"
(
  export QUICK_ARCHVM_SOURCE_ONLY=1
  # shellcheck source=/dev/null
  source "$WORKER"
  printf 'KEYMAP="de"\r\nBRIDGE=br1\r\nDEFAULT_CPUS="4"\r\nVM_DIR=""\r\nBRIDGE="br2"\r\n' >"$T/crlf.cfg"
  eq "cfg_get: quoted value, CRLF"            "$(cfg_get "$T/crlf.cfg" KEYMAP x)" "de"
  eq "cfg_get: later line wins"               "$(cfg_get "$T/crlf.cfg" BRIDGE x)" "br2"
  eq "cfg_get: empty value -> default"        "$(cfg_get "$T/crlf.cfg" VM_DIR fallback)" "fallback"
  eq "cfg_get: missing key -> default"        "$(cfg_get "$T/crlf.cfg" NOPE fallback)" "fallback"
  eq "cfg_get: missing file -> default, quiet" "$(cfg_get "$T/none.cfg" BRIDGE br0 2>&1)" "br0"
  printf 'BRIDGE=br7\r\n' >"$T/unq.cfg"
  eq "cfg_get: unquoted value, CRLF"          "$(cfg_get "$T/unq.cfg" BRIDGE x)" "br7"
  default_cfg >"$T/default.cfg"
  eq "cfg_get: installer's default cfg"       "$(cfg_get "$T/default.cfg" DEFAULT_MEMORY_GB x)" "4"
  eq "xml_escape" "$(xml_escape "a&b<c>\"d'")" "a&amp;b&lt;c&gt;&quot;d&apos;"

  H=$' Name       MAC address          Protocol     Address\n-------------------------------------------------'
  ip() { printf '%s\n%s\n' "$H" "$2" | vm_ipv4 "$1"; }
  eq "vm_ipv4: skips loopback"   "$(ip 52:54:00:ab:cd:ef $' lo         00:00:00:00:00:00    ipv4         127.0.0.1/8\n -          -                    ipv6         ::1/128\n enp1s0     52:54:00:ab:cd:ef    ipv4         192.168.1.77/24')" "192.168.1.77"
  eq "vm_ipv4: loopback only -> empty" "$(ip 52:54:00:ab:cd:ef ' lo         00:00:00:00:00:00    ipv4         127.0.0.1/8')" ""
  eq "vm_ipv4: prefers own MAC over docker0" "$(ip 52:54:00:ab:cd:ef $' docker0    02:42:11:22:33:44    ipv4         172.17.0.1/16\n enp1s0     52:54:00:AB:CD:EF    ipv4         192.168.1.77/24')" "192.168.1.77"
  eq "vm_ipv4: continuation line"  "$(ip 52:54:00:ab:cd:ef $' enp1s0     52:54:00:ab:cd:ef    ipv6         fe80::1/64\n -          -                    ipv4         192.168.1.78/24')" "192.168.1.78"
  eq "vm_ipv4: fallback skips link-local" "$(ip 52:54:00:00:00:01 $' enp1s0     52:54:00:ab:cd:ef    ipv4         169.254.3.4/16\n enp2s0     52:54:00:ab:cd:ee    ipv4         10.0.0.5/24')" "10.0.0.5"
  echo "$PASS $FAIL $SKIP" >"$T/counts"
)
read -r PASS FAIL SKIP <"$T/counts"

# ------------------------------------------------------------------------------
section "dry run (fake 40 GiB image, no network)"
if have qemu-img; then
  mkdir -p "$T/img" "$T/vms"
  qemu-img create -q -f qcow2 "$T/img/Arch-Linux-x86_64-basic.qcow2" 40G
  (cd "$T/img" || exit; sha256sum Arch-Linux-x86_64-basic.qcow2 >Arch-Linux-x86_64-basic.qcow2.SHA256)
  printf 'IMAGE_URL="file://%s/img/Arch-Linux-x86_64-basic.qcow2"\nKEYMAP="de"\nBRIDGE=""\n' "$T" >"$T/plugin.cfg"
  printf 'DOMAINDIR="/mnt/user/domains/"\nBRNAME="br0"\n' >"$T/domain.cfg"
  KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOnly test@host"
  run() { QUICK_ARCHVM_CFG=$T/plugin.cfg QUICK_ARCHVM_DOMAIN_CFG=$T/domain.cfg QUICK_ARCHVM_TEST_DIR=$T/vms \
          bash "$WORKER" --dry-run "$@" 2>&1; }

  out=$(run --name "Test VM 1" --cpus 1 --memory-gb 1 --disk-gb 50 --pinning none --ssh-key "$KEY"); rc=$?
  eq "dry run exits 0" "$rc" "0"
  has "image downloaded and verified" "$out" "verifying checksum"
  XML=$(sed -n 's/^dry run - XML written to //p' <<<"$out")
  if [[ -f $XML ]]; then
    ok "XML written"
    if have xmllint; then
      if xmllint --noout "$XML" 2>/dev/null; then ok "XML well-formed"; else bad "XML well-formed"; fi
    else skip "xmllint (not installed)"; fi
    if have virt-xml-validate; then
      # clusters= is newer than the schema shipped with older libvirt clients
      sed "s/ clusters='1'//" "$XML" >"$T/v.xml"
      if out2=$(virt-xml-validate "$T/v.xml" domain 2>&1); then ok "libvirt schema validation"
      else bad "libvirt schema validation" "$out2"; fi
    else skip "libvirt schema validation (virt-xml-validate not installed)"; fi
    x=$(cat "$XML")
    cred() { sed -n "s|.*io.systemd.credential.binary:$1=\([^<]*\)</entry>.*|\1|p" <<<"$x" | base64 -d; }
    has "name in XML"                 "$x" "<name>Test VM 1</name>"
    has "bridge from domain.cfg"      "$x" "<source bridge='br0'/>"
    has "keymap from plugin cfg"      "$x" "keymap='de'"
    has "guest agent channel"         "$x" "name='org.qemu.guest_agent.0'"
    has "clipboard channel"           "$x" "type='qemu-vdagent'"
    has "smbios sysinfo enabled"      "$x" "<smbios mode='sysinfo'/>"
    if grep -q "<cputune>" <<<"$x"; then bad "no pinning with --pinning none"; else ok "no pinning with --pinning none"; fi
    eq "credential system.hostname"   "$(cred system.hostname)" "test-vm-1"
    eq "credential ssh key"           "$(cred quick_archvm.ssh-key)" "$KEY"
    if [[ "$(cred quick_archvm.provision)" == "$(cat "$SRC/include/guest-provision.sh")" ]]; then
      ok "embedded guest script = guest-provision.sh"; else bad "embedded guest script = guest-provision.sh"; fi
    has "unit runs once"   "$(cred systemd.extra-unit.quick_archvm-provision.service)" "ConditionPathExists=!/var/lib/quick_archvm/provisioned"
    has "drop-in hooks unit into boot" "$(cred 'systemd.unit-dropin.multi-user.target~quick_archvm')" "Wants=quick_archvm-provision.service"
    eq "vdisk virtual size" "$(qemu-img info "$T/vms/Test VM 1/vdisk1.qcow2" | sed -n 's/^virtual size: .*(\([0-9]*\) bytes)$/\1/p')" "$((50*1024*1024*1024))"
    rm -f "$XML"
  else
    bad "XML written" "$out"
  fi

  out=$(run --name "Test VM 1" --cpus 1 --memory-gb 1)
  has "refuses to overwrite an existing vdisk" "$out" "already exists"
  # storage path with characters that must be escaped in XML
  mkdir -p "$T/Bob's & <VMs>"
  out=$(QUICK_ARCHVM_CFG=$T/plugin.cfg QUICK_ARCHVM_DOMAIN_CFG=$T/domain.cfg QUICK_ARCHVM_TEST_DIR="$T/Bob's & <VMs>" \
        bash "$WORKER" --dry-run --name "Odd Path" --cpus 1 --memory-gb 1 2>&1)
  XML=$(sed -n 's/^dry run - XML written to //p' <<<"$out")
  if [[ -f $XML ]] && have xmllint; then
    eq "XML-escaped vdisk path" "$(xmllint --xpath 'string(//disk/source/@file)' "$XML" 2>/dev/null)" "$T/Bob's & <VMs>/Odd Path/vdisk1.qcow2"
  elif [[ -f $XML ]]; then has "XML-escaped vdisk path" "$(cat "$XML")" "Bob&apos;s &amp; &lt;VMs&gt;"
  else bad "XML-escaped vdisk path" "$out"; fi
  rm -f "$XML"
  out=$(run --name "Pinned" --cpus 1 --memory-gb 1 --pinning auto); XML=$(sed -n 's/^dry run - XML written to //p' <<<"$out")
  if [[ -f $XML ]] && grep -q "<vcpupin vcpu='0'" "$XML"; then ok "auto pinning writes vcpupin"; else bad "auto pinning writes vcpupin" "$out"; fi
  rm -f "$XML"
  has "rejects disk < 40 GiB"     "$(run --name x --cpus 1 --memory-gb 1 --disk-gb 39)" "at least 40 GiB"
  has "rejects bad name"          "$(run --name 'a;b' --cpus 1 --memory-gb 1)" "invalid VM name"
  has "rejects bad SSH key"       "$(run --name x --cpus 1 --memory-gb 1 --ssh-key 'nope')" "SSH key"
  has "rejects too many CPUs"     "$(run --name x --cpus 99999 --memory-gb 1)" "only has"
  has "rejects unknown argument"  "$(run --name x --bogus)" "unknown argument"
else
  skip "dry run (qemu-img not installed)"
fi

# ------------------------------------------------------------------------------
section "web endpoint and job runner (PHP)"
if have php; then
  post() { (cd "$SRC" || exit; php -r 'parse_str($argv[1], $_POST); include "include/ArchVM.php";' "$1"); }
  has "endpoint: bad name"       "$(post 'action=prepare&name=a;b&cpus=1&memory=1&disk=40')" "Invalid name"
  has "endpoint: small disk"     "$(post 'action=prepare&name=ok&cpus=1&memory=1&disk=20')" "at least 40"
  has "endpoint: bad SSH key"    "$(post 'action=prepare&name=ok&cpus=1&memory=1&disk=40&sshkey=nope')" "SSH key"
  has "endpoint: unknown action" "$(post 'action=rm')" "unknown action"
  res=$(post 'action=prepare&name=Endpoint Test&cpus=1&memory=2&disk=60&pinning=none&start=yes')
  id=$(sed -n 's/.*"id":"\([a-f0-9]\{16\}\)".*/\1/p' <<<"$res")
  if [[ -n $id && -f /tmp/quick_archvm/jobs/$id.json ]]; then
    ok "endpoint: valid request creates a job"
    job=$(cat "/tmp/quick_archvm/jobs/$id.json"); rm -f "/tmp/quick_archvm/jobs/$id.json"
    has "job contents" "$job" '"name":"Endpoint Test","cpus":1,"memory":2,"disk":60,"pinning":"none","sshkey":"","start":true'
  else bad "endpoint: valid request creates a job" "$res"; fi
  out=$(php "$SRC/scripts/quick_archvm_create" 'abc;rm -rf /' 2>&1); rc=$?
  has "runner: rejects a malformed job id" "$out" "not found"
  eq  "runner: exit code 1 on error" "$rc" "1"
else
  skip "PHP tests (php not installed)"
fi

# ------------------------------------------------------------------------------
section "VMs tab page (CI only)"
if [[ -n ${CI:-} ]] && have php && sudo -n true 2>/dev/null; then
  sudo mkdir -p /var/run/libvirt /boot/config/plugins/quick_archvm
  sudo touch /var/run/libvirt/libvirtd.pid
  default_cfg | sed 's/^DEFAULT_MEMORY_GB="4"/DEFAULT_MEMORY_GB="8"/; s/^DEFAULT_DISK_GB="40"/DEFAULT_DISK_GB=80/' |
    sed 's/$/\r/' | sudo tee /boot/config/plugins/quick_archvm/quick_archvm.cfg >/dev/null
  render() { (cd "$SRC" || exit; php -d short_open_tag=1 -r "\$task='$1';"' $t=file_get_contents("ArchVMButton.page"); $t=substr($t, strpos($t,"---")+3); eval("?>".$t);' 2>&1); }
  page=$(render VMs)
  has "page: memory default from cfg (# comments, CRLF)" "$page" '"memory":8'
  has "page: unquoted disk default from cfg"             "$page" '"disk":80'
  has "page: button inserted next to Add VM"             "$page" "insertAfter(add)"
  if grep -q "PHP \(Warning\|Notice\|Fatal\)" <<<"$page"; then bad "page: no PHP warnings" "$page"; else ok "page: no PHP warnings"; fi
  if have node; then
    sed -n '/<script>/,/<\/script>/p' <<<"$page" | sed '1d;$d' >"$T/page.js"
    if node --check "$T/page.js" 2>/dev/null; then ok "page: JavaScript syntax"; else bad "page: JavaScript syntax"; fi
  else skip "page: JavaScript syntax (node not installed)"; fi
  eq "page: nothing on other tabs" "$(render Dashboard | wc -c)" "0"
else
  skip "page rendering (set CI=true; needs php and passwordless sudo)"
fi

# ------------------------------------------------------------------------------
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))

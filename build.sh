#!/bin/bash
# Build quick_archvm.plg - a single self-contained Unraid plugin file with every
# source file under src/quick_archvm embedded inline.
#
#   ./build.sh              # next version: today's date, then a, b, c ... on the same day
#   ./build.sh 2026.12.01   # explicit version
#   ./build.sh --check      # rebuild with the committed version and fail if
#                           # quick_archvm.plg is not up to date (used by CI)
set -euo pipefail
cd "$(dirname "$0")"

# ---------------------------------------------------------------- settings ---
# GitHub repository that hosts the plugin. Used for the plugin's update URL
# (Plugins > Check for updates), its support link and the README install
# commands. Change it once, then run ./build.sh.
GITHUB_REPO="Modac/unraid-quick_archvm"
BRANCH="main"
AUTHOR="Modac"
MIN_UNRAID="6.12.0"

NAME=quick_archvm
SRC=src/$NAME
DEST=/usr/local/emhttp/plugins/$NAME
PLG=$NAME.plg

# ----------------------------------------------------------------- version ---
current_version() { sed -n 's/^<!ENTITY version *"\([^"]*\)">$/\1/p' "$PLG" 2>/dev/null; }

CHECK=no
case ${1:-} in
  --check) CHECK=yes; VERSION=$(current_version)
           [[ -n $VERSION ]] || { echo "error: no version found in $PLG" >&2; exit 1; } ;;
  "")      today=$(date +%Y.%m.%d); cur=$(current_version)
           if [[ $cur == "$today"* ]]; then
             suffix=${cur#"$today"}
             case $suffix in
               "")    VERSION=${today}a ;;
               [a-y]) VERSION=$today$(echo "$suffix" | tr 'a-y' 'b-z') ;;
               *)     echo "error: cannot bump version '$cur', pass one explicitly" >&2; exit 1 ;;
             esac
           else
             VERSION=$today
           fi ;;
  *)       VERSION=$1 ;;
esac

if [[ $GITHUB_REPO == OWNER/* ]]; then
  PLUGIN_URL="" SUPPORT_URL=""
  [[ $CHECK == no ]] && echo "note: GITHUB_REPO is still a placeholder - the plugin gets no update URL" >&2
else
  PLUGIN_URL="https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH/$PLG"
  SUPPORT_URL="https://github.com/$GITHUB_REPO/issues"
fi

# ---------------------------------------------------------------- helpers ---
cdata_check() {
  if grep -q ']]>' "$1"; then echo "error: $1 contains ']]>'" >&2; exit 1; fi
}

emit_file() { # source-file
  local rel=${1#"$SRC"/}
  cdata_check "$1"
  printf '<FILE Name="%s/%s">\n<INLINE><![CDATA[\n' "$DEST" "$rel"
  cat "$1"
  printf ']]></INLINE>\n</FILE>\n\n'
}

# --------------------------------------------------------------------- build ---
cdata_check CHANGELOG.md
if [[ $CHECK == no ]] && ! grep -q "^### $VERSION\$" CHANGELOG.md; then
  echo "note: CHANGELOG.md has no '### $VERSION' entry yet" >&2
fi

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
{
cat <<EOF
<?xml version='1.0' standalone='yes'?>
<!DOCTYPE PLUGIN [
<!ENTITY name      "$NAME">
<!ENTITY author    "$AUTHOR">
<!ENTITY version   "$VERSION">
<!ENTITY launch    "VMs">
<!ENTITY pluginURL "$PLUGIN_URL">
<!ENTITY support   "$SUPPORT_URL">
<!ENTITY plugdir   "$DEST">
]>

<PLUGIN name="&name;" author="&author;" version="&version;" launch="&launch;"
        pluginURL="&pluginURL;" support="&support;" icon="linux" min="$MIN_UNRAID">

<CHANGES><![CDATA[
$(cat CHANGELOG.md)
]]></CHANGES>

<!-- remove files of a previous version -->
<FILE Run="/bin/bash">
<INLINE>
rm -rf &plugdir;
</INLINE>
</FILE>

EOF

while IFS= read -r f; do
  emit_file "$SRC/$f"
done < <(cd "$SRC" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)

cat <<'EOF'
<!-- install -->
<FILE Run="/bin/bash">
<INLINE>
<![CDATA[
D=/usr/local/emhttp/plugins/quick_archvm
C=/boot/config/plugins/quick_archvm
chmod 755 "$D/scripts/quick_archvm_create" "$D/scripts/quick_archvm.sh"
mkdir -p "$C"
if [ ! -f "$C/quick_archvm.cfg" ]; then
cat > "$C/quick_archvm.cfg" <<'CFG'
# Arch VM plugin settings - all optional, empty = automatic
# Image to use (the matching .SHA256 file must exist next to it)
IMAGE_URL="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-basic.qcow2"
# Where VM folders are created (default: "Default VM storage path" from Settings > VM Manager)
VM_DIR=""
# Where the downloaded image is cached (default: <VM_DIR>/.quick_archvm-cache)
CACHE_DIR=""
# Network bridge (default: "Default network source" from Settings > VM Manager)
BRIDGE=""
# VNC keyboard layout, e.g. "de" (default: none = en-us)
KEYMAP=""
# Defaults shown in the dialog
DEFAULT_CPUS="2"
DEFAULT_MEMORY_GB="4"
DEFAULT_DISK_GB="40"
CPU_PINNING="auto"
DEFAULT_SSH_KEY=""
CFG
fi
echo
echo "-----------------------------------------------------------"
echo " quick_archvm is installed."
echo " Use the 'Add Arch Linux VM' button on the VMs tab."
echo " Settings: /boot/config/plugins/quick_archvm/quick_archvm.cfg"
echo "-----------------------------------------------------------"
echo
]]>
</INLINE>
</FILE>

<!-- uninstall -->
<FILE Run="/bin/bash" Method="remove">
<INLINE>
<![CDATA[
rm -rf /usr/local/emhttp/plugins/quick_archvm /tmp/quick_archvm /var/run/quick_archvm.lock
echo "quick_archvm removed. Settings in /boot/config/plugins/quick_archvm and the image cache"
echo "(<VM storage path>/.quick_archvm-cache) were kept - delete them manually if unwanted."
]]>
</INLINE>
</FILE>

</PLUGIN>
EOF
} >"$OUT"

if command -v xmllint >/dev/null; then
  xmllint --noout "$OUT" || { echo "error: generated plugin is not well-formed XML" >&2; exit 1; }
fi

if [[ $CHECK == yes ]]; then
  if diff -q "$PLG" "$OUT" >/dev/null; then
    echo "$PLG is up to date (version $VERSION)"
  else
    diff -u "$PLG" "$OUT" | head -40 >&2
    echo "error: $PLG is out of date - run ./build.sh and commit the result" >&2
    exit 1
  fi
  exit 0
fi

cp "$OUT" "$PLG"

# keep the install commands and CI badge in README.md pointing at the configured repo
if [[ -n $PLUGIN_URL ]]; then
  sed -i -e "s#https://raw.githubusercontent.com/[^/ ]*/[^/ ]*/[^/ ]*/$PLG#$PLUGIN_URL#g" \
         -e "s#https://github.com/[^/ ]*/[^/ ]*/actions/#https://github.com/$GITHUB_REPO/actions/#g" README.md
fi
echo "built $PLG (version $VERSION)"

### 2026.11.03e
- Repository setup: build script with automatic versions and changelog,
  test suite, GitHub Actions CI. No change in behaviour.
- Fix: XML escaping was broken on bash 5.2+ (Unraid 7). A storage path
  containing ' or & produced an invalid VM definition.
- Uninstall also removes the lock file.

### 2026.11.03d
- Report the VM's real IP address after creation instead of 127.0.0.1
  (skip loopback, match the VM's own network card, wait up to 60 s for DHCP).

### 2026.11.03c
- Fix: dialog ignored the defaults in quick_archvm.cfg (PHP's INI parser
  rejects the file's '#' comment lines).

### 2026.11.03b
- Fix: unquoted settings in a cfg edited from Windows (CRLF line endings)
  got an invisible extra character.

### 2026.11.03a
- Add the qemu-vdagent clipboard channel to new VMs.

### 2026.11.03
- Show system error messages in the progress window (were hidden).
- Never reuse a MAC address of an existing VM.
- Show libvirt's real error when the new VM fails to start.

### 2026.11.02
- First release: "Add Arch Linux VM" button on the VMs tab. Creates a VM from
  the latest official Arch Linux basic image; on first boot the guest sets its
  hostname, grows its root filesystem, adds an optional SSH key and installs
  qemu-guest-agent if missing.

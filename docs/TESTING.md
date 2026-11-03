# Testing on a real Unraid server

`tests/run.sh` covers everything that can be checked without Unraid. This plan
covers the rest: the web UI, libvirt, and the first boot of a real VM. Do the
steps in order; each one catches a different kind of problem.

## 1. Before you start

- *Settings → VM Manager*: the VM service is enabled, and *Default VM storage
  path* and *Default network source* are set.
- The server can reach `geo.mirror.pkgbuild.com`. The first run downloads
  about 500 MB.

## 2. Install

Copy the `.plg` to `/tmp` (not `/boot/config/plugins/`, see the README) and run:

```bash
plugin install /tmp/quick_archvm.plg
```

Expected: the "quick_archvm is installed" box. Check:

```bash
ls -l /usr/local/emhttp/plugins/quick_archvm/scripts/ /boot/config/plugins/quick_archvm/
```

## 3. Dry run (creates no VM)

Use a folder on a share; the default dry-run folder is in `/tmp`, which is RAM:

```bash
QUICK_ARCHVM_TEST_DIR=/mnt/user/domains/qa-dryrun /usr/local/emhttp/plugins/quick_archvm/scripts/quick_archvm.sh --name "Dry Test" --cpus 2 --memory-gb 2 --disk-gb 50 --dry-run
```

Expected: download progress, "verifying checksum", "created …/vdisk1.qcow2
(50 GiB…)", "dry run - XML written to …". Check the network, machine type and
pinning:

```bash
grep -E "machine=|bridge=|vcpupin|topology|keymap" /tmp/quick_archvm-*.xml
```

Clean up:

```bash
rm -rf /mnt/user/domains/qa-dryrun /tmp/quick_archvm-*.xml
```

## 4. Button and dialog

1. **VMs** tab: "Add Arch Linux VM" appears next to "Add VM" (Ctrl+F5 if not).
2. Click it. The defaults come from `quick_archvm.cfg`; the name is the first
   free `Arch-N`.
3. Without creating anything: name `bad;name` → red error; disk `20` → red
   error; the name of an existing VM → "already exists" (from the server).
4. Cancel.

## 5. Create a test VM

Name `qa-test`, 2 CPUs, 2 GiB, disk `60` (so growing is tested), your SSH key,
"Start VM" ticked → **Create**.

Expected in the progress window: disk created, "VM 'qa-test' defined",
"pinned to host CPUs: …", "VM started", a seconds counter, "guest agent is up",
and **"IP address: <LAN address>"** (not 127.0.0.1). The VMs tab shows the Arch
icon and the IP address.

```bash
virsh qemu-agent-command qa-test '{"execute":"guest-get-host-name"}'
```

Expected: `qa-test`.

## 6. Inside the VM

Log in with VNC or `ssh arch@<ip>`. The journal needs `sudo`; without it,
`journalctl` shows nothing for system services:

```bash
sudo journalctl -u quick_archvm-provision --no-pager
```

Expected: hostname, SSH key, `root filesystem: 60G`, guest agent, `done`.

```bash
hostnamectl hostname; df -h /; cat /var/lib/quick_archvm/provisioned; systemctl is-active qemu-guest-agent
```

Expected: `qa-test`, about 60G, a date, `active`.

## 7. Second boot

Restart the VM from the VMs tab, then inside the VM:

```bash
sudo journalctl -b -u quick_archvm-provision --no-pager
```

Expected: one line ending in `skipped, unmet condition check
ConditionPathExists=!/var/lib/quick_archvm/provisioned`. The IP address shows
on the VMs tab again (the agent starts on its own).

## 8. Failure cases (optional)

- Create `qa-test` again → refused before anything is created.
- Start two creations quickly → the second says another VM is being created.
- Set `BRIDGE="br99"` in the cfg and create `qa-fail` with Start ticked →
  the VM is defined, and the start fails with libvirt's message about `br99`.
  Set `BRIDGE` back and remove `qa-fail` (*Remove VM & Disks*).

## 9. Clean up

VMs tab → `qa-test` icon → **Remove VM & Disks**. The image cache in
`<VM storage path>/.quick_archvm-cache/` stays for the next VM.

## When something goes wrong

- Run the same creation from the terminal to see all output:
  `/usr/local/emhttp/plugins/quick_archvm/scripts/quick_archvm.sh --name qa-test2 --cpus 2 --memory-gb 2 --start`
- The agent doesn't come up: check the journal in the VM (step 6). The image
  waits for time sync before its own setup, so NTP must be reachable.
- The button is missing: check that the VM service runs, then look for errors
  in the browser console (F12) on the VMs tab.

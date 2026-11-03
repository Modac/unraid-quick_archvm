# quick_archvm – one-click Arch Linux VMs for Unraid

[![CI](https://github.com/Modac/unraid-quick_archvm/actions/workflows/ci.yml/badge.svg)](https://github.com/Modac/unraid-quick_archvm/actions/workflows/ci.yml)

Adds an **Add Arch Linux VM** button next to *Add VM* on Unraid's **VMs** tab.
Enter a name, CPUs, memory and disk size, and a few minutes later you have a
running Arch Linux VM with **qemu-guest-agent**: its IP address shows on the VMs
tab, and Unraid can shut it down cleanly.

| Field           | Default            | Notes                                                    |
|-----------------|--------------------|----------------------------------------------------------|
| Name            | `Arch-1`, `Arch-2` | becomes the VM name **and** the guest hostname           |
| CPUs            | 2                  | pinned automatically (whole cores, core 0 last) or none  |
| Memory (GiB)    | 4                  |                                                          |
| Disk size (GiB) | 40                 | minimum 40 (size of the image), thin provisioned         |
| SSH public key  | –                  | optional, added to `~arch/.ssh/authorized_keys`          |
| Start VM        | yes                | the progress window waits until the guest agent replies  |

Default login: **`arch` / `arch`** (passwordless sudo, sshd enabled). Change the
password after the first login.

## What it does

1. Downloads the latest official **Arch Linux basic image**
   (`geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-basic.qcow2`),
   checks it against the published SHA256 and caches it. Later VMs reuse the
   cache until a newer image is published.
2. Copies it to `<VM storage path>/<name>/vdisk1.qcow2` and resizes it.
3. Defines a q35 / UEFI VM like the ones Unraid creates: virtio disk and network
   on your default bridge, VNC, serial console, guest-agent and clipboard
   channels, Unraid's Arch icon and template metadata. It never reuses the MAC
   address of another VM.
4. On the **first boot** the guest sets itself up: hostname from the VM name,
   root partition and filesystem grown to the full disk, your SSH key, and
   qemu-guest-agent installed and running (current images already include it).

## Install

Requires Unraid 6.12 or newer with the VM service enabled
(*Settings → VM Manager*).

In the web UI: **Plugins → Install Plugin**, paste this URL and click *Install*:

```
https://raw.githubusercontent.com/Modac/unraid-quick_archvm/main/quick_archvm.plg
```

Or in the Unraid terminal:

```bash
plugin install https://raw.githubusercontent.com/Modac/unraid-quick_archvm/main/quick_archvm.plg
```

## Update

**Plugins → Check for updates**, then *Update* next to quick_archvm.

To install a downloaded `.plg` by hand, **don't** install it from
`/boot/config/plugins/` – Unraid refuses to reinstall from the path the
installed plugin already uses ("not re-installing same plugin"). Copy it
somewhere else first:

```bash
cp quick_archvm.plg /tmp/quick_archvm.plg
```

```bash
plugin install /tmp/quick_archvm.plg
```

Add `forced` at the end if the version number didn't change.

## Settings

`/boot/config/plugins/quick_archvm/quick_archvm.cfg` is created on install. All
keys are optional, and changes take effect immediately: reload the VMs tab for
new dialog defaults; everything else applies to the next VM you create.

| Key                 | Meaning                                                    |
|---------------------|------------------------------------------------------------|
| `IMAGE_URL`         | image to use (`<url>.SHA256` must exist next to it)        |
| `VM_DIR`            | where VM folders go; default = *Default VM storage path*   |
| `CACHE_DIR`         | image cache; default = `<VM_DIR>/.quick_archvm-cache`      |
| `BRIDGE`            | network bridge; default = *Default network source*         |
| `KEYMAP`            | VNC keymap, e.g. `de`                                      |
| `DEFAULT_CPUS`, `DEFAULT_MEMORY_GB`, `DEFAULT_DISK_GB`, `CPU_PINNING` (`auto`/`none`), `DEFAULT_SSH_KEY` | dialog defaults |

## Command line

```bash
/usr/local/emhttp/plugins/quick_archvm/scripts/quick_archvm.sh --name devbox --cpus 4 --memory-gb 8 --disk-gb 80 --start
```

`--help` lists all options. `--dry-run` creates the disk and XML under
`/tmp/quick_archvm-dryrun` (override with `QUICK_ARCHVM_TEST_DIR`) without
touching libvirt.

## How the first-boot setup works

The plugin never mounts or modifies the image on the Unraid host. The VM's XML
carries **systemd credentials** in SMBIOS OEM strings:

```xml
<sysinfo type='smbios'>
  <oemStrings>
    <entry>io.systemd.credential.binary:systemd.extra-unit.quick_archvm-provision.service=…</entry>
    <entry>io.systemd.credential.binary:systemd.unit-dropin.multi-user.target~quick_archvm=…</entry>
    <entry>io.systemd.credential.binary:quick_archvm.provision=…</entry>
    <entry>io.systemd.credential.binary:quick_archvm.hostname=…</entry>
    <entry>io.systemd.credential.binary:system.hostname=…</entry>
  </oemStrings>
</sysinfo>
```

systemd (≥ 256) in the guest turns these into `quick_archvm-provision.service`
and hooks it into normal boot. The service runs
[`guest-provision.sh`](src/quick_archvm/include/guest-provision.sh) once, writes
`/var/lib/quick_archvm/provisioned`, and is skipped on every later boot. If it
fails (no network yet, for example) it retries every 30 s and on the next boot.
To see what happened, run this inside the VM:

```bash
sudo journalctl -u quick_archvm-provision --no-pager
```

The `<sysinfo>` block is harmless after the first boot. Unraid's form editor
may drop it when you edit the VM, which is fine.

## Development

```
src/quick_archvm/
├── ArchVMButton.page          # button + dialog on the VMs tab
├── include/ArchVM.php         # AJAX endpoint: validates input, queues a job
├── include/guest-provision.sh # runs inside the guest on first boot
└── scripts/
    ├── quick_archvm_create    # started by openPlugin(), streams output to the progress window
    └── quick_archvm.sh        # creates the VM (also usable from the CLI)
build.sh                       # builds quick_archvm.plg from src/ and CHANGELOG.md
tests/run.sh                   # test suite (no Unraid, libvirt or network needed)
docs/TESTING.md                # manual test plan on a real Unraid server
```

`quick_archvm.plg` is generated, but it's committed because Unraid installs
and updates the plugin straight from that file in the repository.

**Before the first push:** set `GITHUB_REPO` at the top of `build.sh` to
your `owner/repo` and run `./build.sh`. That puts the update URL and support
link into the plugin and rewrites the install URLs and CI badge in this
README.

**Making a release:**

1. Change files under `src/quick_archvm/`.
2. Add a `### <version>` entry at the top of `CHANGELOG.md`. Versions are
   `YYYY.MM.DD`, then `a`, `b`, … for more releases on the same day.
3. Run `./build.sh`. It picks the next version automatically and warns if the
   changelog has no entry for it; pass a version to choose one yourself.
4. Run `tests/run.sh` (`CI=true tests/run.sh` also renders the web page;
   needs sudo).
5. Commit everything, including `quick_archvm.plg`, and push. Unraid servers
   see the update under *Plugins → Check for updates*.

CI runs `tests/run.sh` on every push. It also fails when `quick_archvm.plg`
doesn't match the sources (`./build.sh --check`).

## Uninstall

Remove it under **Plugins**. VMs you created stay. The settings folder
(`/boot/config/plugins/quick_archvm`) and the image cache (`.quick_archvm-cache`)
are kept; delete them by hand if you don't want them.

## License

[MIT](LICENSE)

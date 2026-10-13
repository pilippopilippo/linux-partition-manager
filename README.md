# Linux Partition Manager

**Partition Wizard** is a Bash script with a guided interface (wizard) to
**grow and modify disk partitions** on Linux. It works on **Debian-based**
distributions (Debian, Ubuntu, Linux Mint, Pop!_OS, ...) and on
**Fedora-based** ones (Fedora, RHEL, CentOS Stream, Rocky, AlmaLinux, ...).

The distribution is detected automatically; you can also choose it yourself
with `--distro debian` or `--distro fedora`. Missing tools are installed with
the right package manager (`apt` or `dnf`), only after you confirm.

## Quick start

Run the script straight from GitHub:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/pilippopilippo/linux-partition-manager/main/partition-wizard.sh)"
```

Already root (for example after `su -` on a Debian installed without sudo)?
Run the same command without `sudo`.

On systems without `curl` (for example a minimal Debian) use `wget`:

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/pilippopilippo/linux-partition-manager/main/partition-wizard.sh)"
```

To **try it without changing anything** (dry-run mode: commands are only
shown), add `partition-wizard --dry-run` at the end:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/pilippopilippo/linux-partition-manager/main/partition-wizard.sh)" partition-wizard --dry-run
```

You can also download it first, or install it as a command:

```bash
curl -fsSLO https://raw.githubusercontent.com/pilippopilippo/linux-partition-manager/main/partition-wizard.sh
chmod +x partition-wizard.sh
sudo ./partition-wizard.sh

# or, to always have it available as "partition-wizard":
sudo curl -fsSL -o /usr/local/bin/partition-wizard https://raw.githubusercontent.com/pilippopilippo/linux-partition-manager/main/partition-wizard.sh
sudo chmod +x /usr/local/bin/partition-wizard
```

> **Why not `curl ... | sudo bash`?** On Debian 13, Ubuntu 24.04 and other
> recent systems sudo runs commands in a separate pseudo-terminal (`use_pty`)
> and does not forward the keyboard to a script that arrives through a pipe:
> the wizard would show its first window but never react to keys. The script
> detects this case and prints the command to use instead.

## What it does

The main menu offers:

| Item | Description |
|------|-------------|
| **Show disks, partitions and free space** | Disk tree, unallocated space, LVM volume groups. |
| **Grow a partition** | Grows the partition into the free space that follows it, then grows its contents: LUKS encrypted volume -> LVM physical volume -> file system. Also works on the running system's own partition. |
| **Shrink a partition** | Shrinks the file system first and then the partition, leaving unallocated space. |
| **Create a new partition** | Creates the partition table (GPT or MBR) if missing, creates the partition in free space, formats it and, if you want, mounts it and adds it to `/etc/fstab`. |
| **Delete a partition** | Deletes a partition (you confirm by typing its name) and comments out the `/etc/fstab` and `/etc/crypttab` lines that refer to it. |
| **Manage LVM** | Extends a logical volume using the free space of its group, or adds a partition to a volume group. |
| **Detect new space on an enlarged disk** | After enlarging a virtual disk: re-reads the disk size and, if needed, extends the GPT to the end of the disk. |
| **Restore a partition table from a backup** | Restores one of the backups saved automatically before every change. |

### Supported file systems

| Contents | Grow | Shrink | Create |
|----------|------|--------|--------|
| ext2 / ext3 / ext4 | yes, even mounted | yes, unmounted | yes (ext4) |
| XFS | yes, even mounted | no (XFS cannot shrink) | yes |
| Btrfs | yes, even mounted | yes, even mounted | yes |
| NTFS | yes, unmounted | yes, unmounted | yes |
| FAT32 | no | no | yes (FAT16 below 64 MiB) |
| swap | yes (UUID kept) | yes (UUID kept) | yes |
| LVM physical volume | yes: `pvresize` + logical volume extension | no | yes |
| LUKS (open encrypted volume) | yes: `cryptsetup resize` + contents | no | no |

Partition tables: **GPT** and **MBR/DOS**, including logical partitions inside
an extended partition (the extended partition is grown automatically when
needed).

## Examples

**I enlarged my virtual machine's disk and want to use the new space**
1. *Grow a partition* -> pick the disk. The script detects the new size and
   offers to extend the GPT.
2. Pick the partition (usually the last one, e.g. the root `/`) and press
   Enter on `max`.
3. Partition and file system are grown online, no reboot needed.

**Ubuntu with LVM: the logical volume does not use the whole group**
*Manage LVM* -> *Extend a logical volume* -> pick `ubuntu-vg/ubuntu-lv` -> `max`.

**Adding a data disk**
*Create a new partition* -> pick the new disk -> GPT -> `max` -> ext4 ->
label -> mount point (e.g. `/srv/data`). The partition is mounted and added
to `/etc/fstab` with the `nofail` option.

**Making room for a new partition**
*Shrink a partition* -> enter the new size (e.g. `100G` or `-50G`), then
*Create a new partition* in the freed space.

Sizes use the units `M`, `G`, `T` (powers of 1024), decimals allowed:
`500M`, `20G`, `1.5T`, `+10G` (add), `-5G` (remove), `max` (all the available
space).

## Safety

Changing partitions is always delicate: **back up your important data
before starting**. The script still does its best to reduce the risks:

- before every change it saves the partition table to
  `/var/backups/partition-wizard/`; restore it from the menu or with
  `sudo sfdisk /dev/sdX < backup-file`;
- every command it runs is logged to `/var/log/partition-wizard.log`;
- it shows a summary and asks for confirmation before every operation; to
  delete or overwrite data you have to type the device name;
- `Ctrl+C` is ignored during critical operations, so that file systems and
  partition tables are never left half done;
- it never deletes system partitions (`/`, `/boot`, `/home`, ...) nor any
  partition that is still in use, and never unmounts the ones the running
  system needs (`/`, `/usr`, `/var`, `/boot`);
- before restoring a backup it checks that the backup was taken from the same
  disk (disk identifier), because device names such as `sda`/`sdb` can change
  between boots;
- after every change it checks that the kernel sees the new partition layout
  and tells you when a reboot is needed;
- with `--dry-run` you can see exactly which commands would be run;
- all text is plain ASCII, so it renders correctly even on consoles without a
  UTF-8 locale.

### Limitations

- A partition can only grow into the free space **right after** it: the
  script does not move partitions (use for example GParted from a live USB
  for that).
- Shrinking an ext4 or NTFS file system requires it to be unmounted: for the
  system partition, boot from a live USB and run the script from there.
- XFS cannot be shrunk; shrinking LVM and LUKS volumes is not automated.

## Options

```
Usage: partition-wizard.sh [options]

  -n, --dry-run        simulation: show the commands without changing anything
  -t, --text           plain text interface (no whiptail)
  -d, --distro NAME    force the distribution family: debian | fedora
  -l, --list           show disks, partitions and free space, then exit
      --install-deps   install all the required tools, then exit
  -y, --yes            install dependencies without asking for confirmation
      --include-loop   also show loop devices (for tests on image files)
  -h, --help           show this help
  -V, --version        show the version
```

When the script is started with `bash -c "$(curl ...)"`, put the options
after a name for the script, e.g. `... partition-wizard --text`.

## Requirements

- Bash 4.2 or newer and root privileges (the script restarts itself with
  `sudo` when needed).
- Tools are installed automatically when needed, or all at once with
  `sudo ./partition-wizard.sh --install-deps`:

| Feature | Debian / Ubuntu | Fedora / RHEL |
|---------|-----------------|---------------|
| Partition tables (`sfdisk`, `partx`, `lsblk`, ...) | `fdisk`, `util-linux` | `util-linux` |
| Dialog interface (`whiptail`) | `whiptail` | `newt` |
| ext2/3/4 | `e2fsprogs` | `e2fsprogs` |
| XFS | `xfsprogs` | `xfsprogs` |
| Btrfs | `btrfs-progs` | `btrfs-progs` |
| LVM | `lvm2` | `lvm2` |
| LUKS | `cryptsetup` | `cryptsetup` |
| FAT32 | `dosfstools` | `dosfstools` |
| NTFS | `ntfs-3g` | `ntfsprogs` |

If `whiptail` is not available (or with `--text`) the wizard uses a simple
numbered-menu interface.

## Development and tests

The tests create virtual disks (image files attached to loop devices) and
check the real operations on ext4, XFS, Btrfs, swap, LVM, GPT, MBR with
logical partitions and complete wizard flows. They never touch real disks.

```bash
sudo ./partition-wizard.sh --install-deps --yes
sudo tests/run-tests.sh
```

You can also try the wizard on a fake disk:

```bash
truncate -s 2G /tmp/disk.img
sudo losetup -fP --show /tmp/disk.img     # e.g. /dev/loop0
sudo ./partition-wizard.sh --include-loop
sudo losetup -d /dev/loop0                # when done
```

GitHub Actions CI runs ShellCheck, the tests on Ubuntu and the dependency
installation on Debian, Ubuntu, Fedora and Rocky Linux.

## License

[MIT](LICENSE)

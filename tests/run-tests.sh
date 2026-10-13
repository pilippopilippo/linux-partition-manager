#!/usr/bin/env bash
# =============================================================================
#  Automated tests for partition-wizard.sh
#
#  They create virtual disks (image files + loop devices) and check the real
#  operations: creating, growing, shrinking and deleting partitions with
#  several file systems, GPT after a disk has been enlarged, MBR logical
#  partitions, LVM and some complete wizard flows in text mode.
#
#  Usage (as root):  sudo tests/run-tests.sh
#  Real disks are never touched: only the loop devices created here are used.
# =============================================================================

set -o pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../partition-wizard.sh"

if (( EUID != 0 )); then
    echo "The tests must be run as root (loop devices are needed)." >&2
    exit 1
fi

WORK=$(mktemp -d /tmp/pw-tests.XXXXXX)
PASS=0
FAIL=0
SKIP=0

PW_NO_MAIN=1
PW_LOG_FILE="$WORK/wizard.log"
PW_BACKUP_DIR="$WORK/backups"
# shellcheck source=../partition-wizard.sh source-path=SCRIPTDIR
source "$SCRIPT"
PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"
init_colors
detect_distro
init_sfdisk_opts
PW_ASSUME_YES=1
PW_NO_TUI=1
PW_INCLUDE_LOOP=1
ui_init

cleanup_tests() {
    local l f m
    for m in $(findmnt -rn -o TARGET | grep -E "^($WORK|/tmp/partition-wizard\.)" | sort -r); do
        umount "$m" 2>/dev/null
    done
    if command -v vgs >/dev/null 2>&1; then
        vgchange -an pwtestvg >/dev/null 2>&1
        vgremove -f pwtestvg >/dev/null 2>&1
    fi
    [[ -e /dev/mapper/pwtestcrypt ]] && cryptsetup close pwtestcrypt 2>/dev/null
    # new_disk runs in a subshell, so the loop devices are found through
    # their backing files
    while read -r l f; do
        [[ $f == "$WORK"/* ]] || continue
        swapoff "$l"p* 2>/dev/null
        losetup -d "$l" 2>/dev/null
    done < <(losetup -nO NAME,BACK-FILE 2>/dev/null)
    rm -rf "$WORK"
}
trap cleanup_tests EXIT

# --- helpers -------------------------------------------------------------------

pass() { PASS=$(( PASS + 1 )); printf '\e[32mPASS\e[0m %s\n' "$*"; }
fail() { FAIL=$(( FAIL + 1 )); printf '\e[31mFAIL\e[0m %s\n' "$*"; }
skip() { SKIP=$(( SKIP + 1 )); printf '\e[33mSKIP\e[0m %s\n' "$*"; }

check() {   # description command...
    local desc=$1
    shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}

not() { ! "$@"; }

# The file system fills the partition (up to block-size rounding)
fills() {   # partition_bytes file_system_bytes
    (( $1 >= $2 && $1 - $2 < 65536 ))
}

check_eq() {   # description expected actual
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

new_disk() {   # size -> prints the loop device
    local img l
    img=$(mktemp "$WORK/disk.XXXXXX.img")
    truncate -s "$1" "$img"
    l=$(losetup -fP --show "$img") || return 1
    printf '%s\n' "$l"
}

img_of() { losetup -nO BACK-FILE "$1"; }

# bytes of an ext2/3/4 file system
ext_bytes() {
    local bc bs
    bc=$(dumpe2fs -h "$1" 2>/dev/null | awk -F': *' '/^Block count/ { print $2 }')
    bs=$(dumpe2fs -h "$1" 2>/dev/null | awk -F': *' '/^Block size/ { print $2 }')
    echo $(( bc * bs ))
}

mib() { echo $(( $1 * 1048576 )); }

sectors_for_mib() { echo $(( $1 * 2048 )); }   # 512-byte sectors

# Creates an N MiB partition in the first free region; prints the device
create_part() {   # disk MiB fs [label]
    local disk=$1 size=$2 fs=$3 label=${4:-} s
    load_table "$disk" || return 1
    read -r s _ < <(free_regions | head -n1)
    [[ -n $s ]] || return 1
    op_create "$disk" "$s" $(( s + $(sectors_for_mib "$size") - 1 )) "$fs" "$label" >/dev/null 2>&1 || return 1
    printf '%s\n' "$CREATED_PART"
}

part_end_of() {   # disk nr -> end sector
    local i
    load_table "$1"
    i=$(tbl_idx "$2") || return 1
    echo $(( T_START[i] + T_SIZE[i] - 1 ))
}

# End sector that makes partition NR exactly SIZE MiB
end_for_size() {   # disk nr MiB
    local i
    load_table "$1"
    i=$(tbl_idx "$2") || return 1
    echo $(( T_START[i] + $(sectors_for_mib "$3") - 1 ))
}

# --- unit tests ------------------------------------------------------------------

test_units() {
    echo "== Basic functions"
    check_eq "parse_size 20G" "$(( 20 * 1024 * 1048576 ))" "$(parse_size 20G)"
    check_eq "parse_size 1.5T" "$(( 3 * 512 * 1024 * 1048576 ))" "$(parse_size 1.5T)"
    check_eq "parse_size 2,5g" "$(( 5 * 512 * 1048576 ))" "$(parse_size 2,5g)"
    check_eq "parse_size 500MiB" "$(( 500 * 1048576 ))" "$(parse_size 500MiB)"
    check "parse_size rejects values without a unit" not parse_size 123
    check "parse_size rejects text" not parse_size abc
    check_eq "human 1 GiB" "1.00 GiB" "$(human 1073741824)"
    check_eq "human 512 B" "512 B" "$(human 512)"

    T_SS=512
    compute_end max 2048 4095 100000 grow
    check_eq "compute_end max" 100000 "$NEW_END"
    compute_end +1M 2048 4095 100000 grow
    check_eq "compute_end +1M" 6143 "$NEW_END"
    compute_end 10M 2048 4095 100000 grow
    check_eq "compute_end 10M" $(( 2048 + 20480 - 1 )) "$NEW_END"
    check "compute_end rejects sizes beyond the maximum" not compute_end 100G 2048 4095 100000 grow
    check "compute_end rejects shrinking in grow mode" not compute_end 1M 2048 4095 100000 grow
    compute_end -1M 2048 8191 8191 shrink 0
    check_eq "compute_end -1M (shrink)" 6143 "$NEW_END"
    check "compute_end enforces the minimum when shrinking" not compute_end 1M 2048 8191 8191 shrink 2097152

    check "valid mount point /srv/data" valid_mount_point /srv/data
    check "valid mount point /mnt/disk_2.backup" valid_mount_point /mnt/disk_2.backup
    check "mount point / rejected" not valid_mount_point /
    check "relative mount point rejected" not valid_mount_point data
    check "mount point with spaces rejected" not valid_mount_point "/mnt/my data"
    check "mount point with # rejected" not valid_mount_point "/mnt/a#b"
    check "mount point with .. rejected" not valid_mount_point /mnt/../etc

    # Text must render on terminals without a UTF-8 locale
    check "the script contains only ASCII characters" not env LC_ALL=C grep -q '[^[:print:][:space:]]' "$SCRIPT"
}

# --- GPT: ext4, grow, shrink, delete ----------------------------------------------

test_gpt_ext4() {
    echo "== GPT + ext4"
    local d p p2 nr before after
    d=$(new_disk 1G) || { fail "disk creation"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 200 ext4 DATA)
    check "ext4 partition created" test -b "$p"
    check_eq "ext4 file system" ext4 "$(fs_type "$p")"
    check_eq "label" DATA "$(fs_prop "$p" LABEL)"
    check_eq "partition size" "$(mib 200)" "$(dev_bytes "$p")"
    check "partition table backup saved" compgen -G "$PW_BACKUP_DIR/$(kname "$d")-*.sfdisk" >/dev/null

    nr=$(part_nr "$p")
    load_table "$d"
    check_eq "part_max_end reaches the end of the disk" "$T_LAST" "$(part_max_end "$nr")"
    echo "hello" >"$WORK/marker"
    mkdir -p "$WORK/m" && mount "$p" "$WORK/m" && cp "$WORK/marker" "$WORK/m/" && umount "$WORK/m"

    # grow to 300 MiB (file system unmounted)
    set_part_end "$d" "$nr" "$(end_for_size "$d" "$nr" 300)" >/dev/null 2>&1
    check_eq "partition grown to 300 MiB" "$(mib 300)" "$(dev_bytes "$p")"
    grow_contents "$p" >/dev/null 2>&1
    check_eq "file system grown to 300 MiB" "$(mib 300)" "$(ext_bytes "$p")"

    # grow to "max"
    load_table "$d"
    set_part_end "$d" "$nr" "$(part_max_end "$nr")" >/dev/null 2>&1 && grow_contents "$p" >/dev/null 2>&1
    load_table "$d"
    check "max grow reaches the end of the disk" test "$(part_end_of "$d" "$nr")" -eq "$T_LAST"
    check "file system = partition after max" fills "$(dev_bytes "$p")" "$(ext_bytes "$p")"

    # shrink to 150 MiB
    op_shrink "$d" "$nr" "$(end_for_size "$d" "$nr" 150)" >/dev/null 2>&1
    check_eq "partition shrunk to 150 MiB" "$(mib 150)" "$(dev_bytes "$p")"
    check_eq "shrunk file system = partition" "$(mib 150)" "$(ext_bytes "$p")"
    check "e2fsck clean after shrinking" e2fsck -f -n "$p" >/dev/null 2>&1
    mount "$p" "$WORK/m" && check "data preserved across changes" cmp -s "$WORK/marker" "$WORK/m/marker"
    umount "$WORK/m"

    # second partition in the freed space, then delete it
    before=$(lsblk -lnpo NAME "$d" | wc -l)
    p2=$(create_part "$d" 50 none)
    check "second partition without file system created" test -b "$p2"
    op_delete "$d" "$(part_nr "$p2")" 1 >/dev/null 2>&1
    after=$(lsblk -lnpo NAME "$d" | wc -l)
    check_eq "partition deleted" "$before" "$after"
    load_table "$d"
    check_eq "only one partition left in the table" 1 "${#T_NR[@]}"
}

# --- online grow (mounted file system) ---------------------------------------------

test_online_grow() {
    echo "== Online grow of a mounted ext4"
    local d p nr
    d=$(new_disk 512M) || { fail "disk creation"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 100 ext4)
    nr=$(part_nr "$p")
    mount "$p" "$WORK/m" || { fail "mount"; return; }
    set_part_end "$d" "$nr" "$(end_for_size "$d" "$nr" 200)" >/dev/null 2>&1
    check_eq "mounted partition grown" "$(mib 200)" "$(dev_bytes "$p")"
    if grow_contents "$p" >/dev/null 2>&1; then
        check_eq "mounted file system grown" "$(mib 200)" "$(ext_bytes "$p")"
    else
        skip "online ext4 resize is not allowed in this environment"
    fi
    check "the partition is still mounted" test "$(mountpoint_of "$p")" = "$WORK/m"
    umount "$WORK/m"
}

# --- references in /etc/fstab --------------------------------------------------------

test_fstab_refs() {
    echo "== References in fstab"
    local d p uuid fake lines
    d=$(new_disk 256M) || { fail "disk creation"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 64 ext4 REFTEST)
    uuid=$(fs_prop "$p" UUID)
    fake="$WORK/fstab"
    printf '%s\n' "# comment UUID=$uuid / ext4" "UUID=$uuid /data ext4 defaults 0 2" \
        "LABEL=other /other ext4 defaults 0 2" "LABEL=REFTEST /ref ext4 defaults 0 2" \
        "$p /dev-path ext4 defaults 0 2" >"$fake"
    lines=$(config_refs "$p" "$fake" 1 | tr '\n' ' ')
    check_eq "lines referring to the partition" "2 4 5 " "$lines"
    comment_config_lines "$fake" 2 4 5 >/dev/null 2>&1
    check_eq "lines commented out" 4 "$(grep -c '^#' "$fake")"
    check "unrelated line untouched" grep -q '^LABEL=other' "$fake"
    check "backup copy created" compgen -G "$fake.partition-wizard-*.bak" >/dev/null
}

# --- GPT after the disk has been enlarged --------------------------------------------

test_gpt_disk_growth() {
    echo "== GPT after enlarging the disk (e.g. a virtual disk)"
    local d p nr gap
    d=$(new_disk 256M) || { fail "disk creation"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    load_table "$d"
    p=$(create_part "$d" 200 ext4)
    nr=$(part_nr "$p")
    truncate -s 512M "$(img_of "$d")"
    losetup -c "$d"
    load_table "$d"
    gap=$(gpt_tail_gap)
    check "space beyond the end of the GPT detected" test "$gap" -ge "$(mib 200)"
    prepare_disk_growth "$d" >/dev/null 2>&1
    load_table "$d"
    check_eq "GPT extended to the end of the disk" 0 "$(gpt_tail_gap)"
    set_part_end "$d" "$nr" "$(part_max_end "$nr")" >/dev/null 2>&1 && grow_contents "$p" >/dev/null 2>&1
    check "partition grown into the new space" test "$(dev_bytes "$p")" -gt "$(mib 500)"
    check "file system grown into the new space" fills "$(dev_bytes "$p")" "$(ext_bytes "$p")"
}

# --- MBR with logical partitions --------------------------------------------------

test_mbr_logical() {
    echo "== MBR with extended and logical partitions"
    local d p5 old regions=()
    d=$(new_disk 512M) || { fail "disk creation"; return; }
    printf 'label: dos\nstart=2048, size=204800, type=83\nstart=206848, size=104448, type=5\nstart=208896, size=102400, type=83\n' |
        sfdisk -q "$d" >/dev/null 2>&1
    reread_table "$d"
    p5=$(part_dev "$d" 5)
    wait_for_dev "$p5"
    mkfs.ext4 -q "$p5"
    load_table "$d"
    old=$(part_max_end 5)
    check "logical partition can grow beyond the extended one" test "$old" -eq "$T_LAST"
    set_part_end "$d" 5 "$(end_for_size "$d" 5 150)" >/dev/null 2>&1
    check_eq "logical partition grown to 150 MiB" "$(mib 150)" "$(dev_bytes "$p5")"
    load_table "$d"
    check "extended partition grown accordingly" test $(( T_START[1] + T_SIZE[1] - 1 )) -ge $(( T_START[2] + T_SIZE[2] - 1 ))
    grow_contents "$p5" >/dev/null 2>&1
    check_eq "file system of the logical partition grown" "$(mib 150)" "$(ext_bytes "$p5")"
    load_table "$d"
    mapfile -t regions < <(free_regions)
    check "free space computed outside the extended partition" test "${#regions[@]}" -ge 1
}

# --- swap ------------------------------------------------------------------------------

test_swap() {
    echo "== swap"
    local d p uuid nr
    d=$(new_disk 256M) || { fail "disk creation"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 64 swap SWAPTEST)
    check_eq "swap created" swap "$(fs_type "$p")"
    uuid=$(fs_prop "$p" UUID)
    nr=$(part_nr "$p")
    set_part_end "$d" "$nr" "$(end_for_size "$d" "$nr" 128)" >/dev/null 2>&1 && grow_contents "$p" >/dev/null 2>&1
    check_eq "swap grown" "$(mib 128)" "$(dev_bytes "$p")"
    check_eq "swap UUID preserved" "$uuid" "$(fs_prop "$p" UUID)"
    check_eq "swap label preserved" SWAPTEST "$(fs_prop "$p" LABEL)"
    op_shrink "$d" "$nr" "$(end_for_size "$d" "$nr" 32)" >/dev/null 2>&1
    check_eq "swap shrunk" "$(mib 32)" "$(dev_bytes "$p")"
    check_eq "UUID preserved after shrinking" "$uuid" "$(fs_prop "$p" UUID)"
}

# --- xfs and btrfs (they need to be mounted) ---------------------------------------

test_xfs() {
    echo "== xfs"
    local d p nr size
    if ! command -v mkfs.xfs >/dev/null; then skip "xfsprogs not installed"; return; fi
    d=$(new_disk 1G) || { fail "disk creation"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 320 xfs)
    check_eq "xfs created" xfs "$(fs_type "$p")"
    nr=$(part_nr "$p")
    set_part_end "$d" "$nr" "$(end_for_size "$d" "$nr" 512)" >/dev/null 2>&1
    if ! grow_contents "$p" >/dev/null 2>&1; then
        skip "xfs_growfs is not allowed in this environment"
        return
    fi
    mount "$p" "$WORK/m"
    size=$(df -B1 --output=size "$WORK/m" | tail -n1)
    umount "$WORK/m"
    check "xfs grown (unmounted: temporary mount)" test "$size" -gt "$(mib 400)"
}

test_btrfs() {
    echo "== btrfs"
    local d p nr total
    if ! command -v mkfs.btrfs >/dev/null; then skip "btrfs-progs not installed"; return; fi
    if ! grep -qw btrfs /proc/filesystems && ! modprobe btrfs 2>/dev/null; then
        skip "the kernel does not support btrfs"
        return
    fi
    d=$(new_disk 1G) || { fail "disk creation"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 400 btrfs)
    check_eq "btrfs created" btrfs "$(fs_type "$p")"
    nr=$(part_nr "$p")
    set_part_end "$d" "$nr" "$(end_for_size "$d" "$nr" 600)" >/dev/null 2>&1
    if ! grow_contents "$p" >/dev/null 2>&1; then
        skip "btrfs resize is not allowed in this environment"
        return
    fi
    mount "$p" "$WORK/m"
    total=$(btrfs filesystem show --raw "$WORK/m" | awk '/devid/ { print $4 }')
    check_eq "btrfs grown" "$(mib 600)" "$total"
    umount "$WORK/m"
    op_shrink "$d" "$nr" "$(end_for_size "$d" "$nr" 300)" >/dev/null 2>&1
    check_eq "btrfs: partition shrunk" "$(mib 300)" "$(dev_bytes "$p")"
    mount "$p" "$WORK/m"
    total=$(btrfs filesystem show --raw "$WORK/m" | awk '/devid/ { print $4 }')
    umount "$WORK/m"
    check_eq "btrfs: file system = partition" "$(mib 300)" "$total"
}

# --- MBR: deleting a logical partition renumbers the following ones ----------------

test_mbr_logical_delete() {
    echo "== MBR: deleting a logical partition"
    local d dn
    d=$(new_disk 600M) || { fail "disk creation"; return; }
    printf 'label: dos\nstart=2048, size=204800, type=83\nstart=206848, size=409600, type=5\nstart=208896, size=102400, type=83\nstart=313344, size=102400, type=83\nstart=417792, size=102400, type=83\n' |
        sfdisk -q "$d" >/dev/null 2>&1
    reread_table "$d" >/dev/null 2>&1
    wait_for_dev "$(part_dev "$d" 7)"
    mkfs.ext4 -q -L SIX "$(part_dev "$d" 6)"
    mkfs.ext4 -q -L SEVEN "$(part_dev "$d" 7)"
    op_delete "$d" 5 1 >/dev/null 2>&1
    dn=$(kname "$d")
    check_eq "former partition 6 is now partition 5" SIX "$(fs_prop "$(part_dev "$d" 5)" LABEL)"
    check_eq "former partition 7 is now partition 6" SEVEN "$(fs_prop "$(part_dev "$d" 6)" LABEL)"
    check "no stale partition 7 left in the kernel" test ! -e "/sys/class/block/${dn}p7"
    check "kernel and partition table agree" kernel_in_sync "$d"
}

# --- deleting partitions that are in use ------------------------------------------

test_delete_in_use() {
    echo "== Deleting partitions in use"
    local d p idx
    d=$(new_disk 256M) || { fail "disk creation"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 64 ext4)
    mount "$p" "$WORK/m"
    check "op_delete refuses a mounted partition" not op_delete "$d" "$(part_nr "$p")" 1 2>/dev/null
    load_table "$d"
    check_eq "the mounted partition is still in the table" 1 "${#T_NR[@]}"
    # mounted twice: the wizard must unmount it everywhere before deleting
    mkdir -p "$WORK/m2"
    mount --bind "$WORK/m" "$WORK/m2"
    idx=$(disk_index "$d")
    printf '5\n%s\n1\n9\n' "$idx" | main_menu >"$WORK/flow-del.log" 2>&1
    load_table "$d"
    check_eq "wizard: partition mounted twice deleted" 0 "${#T_NR[@]}"
    check "wizard: every mount point was unmounted" not findmnt -n "$WORK/m2"
}

# --- partition table backups ----------------------------------------------------------

test_backups() {
    echo "== Partition table backups"
    local d n f other
    d=$(new_disk 128M) || { fail "disk creation"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    n=$(compgen -G "$PW_BACKUP_DIR/$(kname "$d")-*" | wc -l)
    backup_table "$d" 2>/dev/null
    backup_table "$d" 2>/dev/null
    backup_table "$d" 2>/dev/null
    check_eq "backups taken in the same second do not overwrite each other" $(( n + 3 )) "$(compgen -G "$PW_BACKUP_DIR/$(kname "$d")-*" | wc -l)"
    f=$(compgen -G "$PW_BACKUP_DIR/$(kname "$d")-*" | head -n1)
    check_eq "no warning when restoring a backup on its own disk" "" "$(backup_id_warning "$f" "$d")"
    other=$(new_disk 128M) || { fail "disk creation"; return; }
    run_input "label: gpt" sfdisk -q "$other" >/dev/null 2>&1
    check "warning when the backup comes from another disk" test -n "$(backup_id_warning "$f" "$other")"
}

# --- disks without a supported partition table -----------------------------------------

test_signatures() {
    echo "== Disks without a supported partition table"
    local d rc
    d=$(new_disk 128M) || { fail "disk creation"; return; }
    mkfs.ext4 -q "$d"
    load_table "$d"
    rc=$?
    check_eq "whole-disk file system: no partition table" 1 "$rc"
    check_eq "whole-disk file system signature detected" ext4 "$(dev_signatures "$d")"
    run_input "label: sun" sfdisk -q "$d" >/dev/null 2>&1
    load_table "$d"
    rc=$?
    check_eq "unsupported partition table type detected" 2 "$rc"
}

# --- NTFS and FAT ----------------------------------------------------------------------

test_ntfs() {
    echo "== NTFS"
    local d p nr
    if ! command -v mkfs.ntfs >/dev/null || ! command -v ntfsresize >/dev/null; then skip "NTFS tools not installed"; return; fi
    d=$(new_disk 512M) || { fail "disk creation"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 100 ntfs WINDATA)
    check_eq "NTFS created" "ntfs WINDATA" "$(fs_type "$p") $(fs_prop "$p" LABEL)"
    check_eq "Microsoft basic data partition type" "$GPT_MSDATA" "$(sfdisk --part-type "$d" "$(part_nr "$p")" 2>/dev/null)"
    nr=$(part_nr "$p")
    set_part_end "$d" "$nr" "$(end_for_size "$d" "$nr" 200)" >/dev/null 2>&1 && grow_contents "$p" >/dev/null 2>&1
    check "NTFS grown" test "$(ntfsresize -f -i "$p" 2>/dev/null | awk '/Current volume size/ { print $4 }')" -gt "$(mib 199)"
    op_shrink "$d" "$nr" "$(end_for_size "$d" "$nr" 80)" >/dev/null 2>&1
    check_eq "NTFS partition shrunk" "$(mib 80)" "$(dev_bytes "$p")"
    check "NTFS file system fits the partition" test "$(ntfsresize -f -i "$p" 2>/dev/null | awk '/Current volume size/ { print $4 }')" -le "$(mib 80)"
}

test_vfat() {
    echo "== FAT"
    local d p
    if ! command -v mkfs.vfat >/dev/null; then skip "dosfstools not installed"; return; fi
    d=$(new_disk 256M) || { fail "disk creation"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 128 vfat EFI)
    check_eq "128 MiB partition formatted as FAT32" "vfat FAT32 EFI" "$(fs_type "$p") $(fs_prop "$p" VERSION) $(fs_prop "$p" LABEL)"
    p=$(create_part "$d" 16 vfat SMALL)
    check "16 MiB partition formatted as FAT12/FAT16" test "$(fs_prop "$p" VERSION)" != FAT32
}

# --- LUKS ------------------------------------------------------------------------------

test_luks() {
    echo "== LUKS"
    local d p nr before
    if ! command -v cryptsetup >/dev/null || ! dmsetup version >/dev/null 2>&1; then
        skip "cryptsetup/device-mapper not available"
        return
    fi
    d=$(new_disk 512M) || { fail "disk creation"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 128 none)
    printf 'pw-test-secret' | cryptsetup luksFormat -q --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 "$p" - >/dev/null 2>&1
    printf 'pw-test-secret' | cryptsetup open --key-file - "$p" pwtestcrypt >/dev/null 2>&1
    if [[ ! -e /dev/mapper/pwtestcrypt ]]; then
        skip "could not open the test LUKS volume"
        return
    fi
    mkfs.ext4 -q /dev/mapper/pwtestcrypt
    before=$(dev_bytes /dev/mapper/pwtestcrypt)
    nr=$(part_nr "$p")
    set_part_end "$d" "$nr" "$(end_for_size "$d" "$nr" 256)" >/dev/null 2>&1
    # cryptsetup may ask for the passphrase to resize a LUKS2 volume
    grow_contents "$p" >/dev/null 2>&1 <<<"pw-test-secret"
    # the partition grew by 128 MiB, so the mapping must grow by the same amount
    # (the LUKS header size does not change)
    check_eq "LUKS mapping grown by 128 MiB" $(( before + $(mib 128) )) "$(dev_bytes /dev/mapper/pwtestcrypt)"
    check "file system inside LUKS grown" test "$(ext_bytes /dev/mapper/pwtestcrypt)" -gt "$before"
    check "file system fills the LUKS mapping" fills "$(dev_bytes /dev/mapper/pwtestcrypt)" "$(ext_bytes /dev/mapper/pwtestcrypt)"
    cryptsetup close pwtestcrypt
}

# --- LVM ---------------------------------------------------------------------------------

test_lvm() {
    echo "== LVM"
    local d p nr lv
    if ! command -v lvm >/dev/null || ! dmsetup version >/dev/null 2>&1; then
        skip "LVM/device-mapper not available"
        return
    fi
    d=$(new_disk 1G) || { fail "disk creation"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 300 lvm)
    check_eq "physical volume created" LVM2_member "$(fs_type "$p")"
    vgcreate -q pwtestvg "$p" >/dev/null 2>&1
    lvcreate -q -y -L 200M -n data pwtestvg >/dev/null 2>&1
    lv=/dev/pwtestvg/data
    mkfs.ext4 -q "$lv"
    nr=$(part_nr "$p")
    set_part_end "$d" "$nr" "$(end_for_size "$d" "$nr" 600)" >/dev/null 2>&1
    # grow_contents: pvresize, then the wizard offers to extend an LV:
    # choice 1 (the only LV in the group) and "max"
    grow_contents "$p" >/dev/null 2>&1 <<<$'1\nmax'
    check "physical volume grown" test "$(pvs --noheadings --units b --nosuffix -o pv_size "$p" | tr -d ' ')" -gt "$(mib 590)"
    check "logical volume extended" test "$(dev_bytes "$lv")" -gt "$(mib 500)"
    check "file system of the logical volume grown" fills "$(dev_bytes "$lv")" "$(ext_bytes "$lv")"
    vgchange -an pwtestvg >/dev/null 2>&1
}

# --- complete wizard flows (text interface) ------------------------------------------

disk_index() {   # position of the disk in the selection menu
    local i disks=()
    mapfile -t disks < <(list_disks)
    for i in "${!disks[@]}"; do
        [[ ${disks[i]} == "$1" ]] && { echo $(( i + 1 )); return 0; }
    done
    return 1
}

test_wizard_flows() {
    echo "== Complete wizard (text mode)"
    local d idx p
    d=$(new_disk 512M) || { fail "disk creation"; return; }
    idx=$(disk_index "$d")
    # Create: GPT table, 100M ext4 partition with a label, no mount point
    main_menu >"$WORK/flow1.log" 2>&1 <<EOF
4
$idx
1
100M
1
WIZ

9
EOF
    p=$(part_dev "$d" 1)
    check "wizard: GPT table created" test "$(fs_prop "$d" PTTYPE)" = gpt
    check_eq "wizard: 100 MiB partition created" "$(mib 100)" "$(dev_bytes "$p")"
    check_eq "wizard: ext4 with label" "ext4 WIZ" "$(fs_type "$p") $(fs_prop "$p" LABEL)"

    # Grow: +50M
    main_menu >"$WORK/flow2.log" 2>&1 <<EOF
2
$idx
1
+50M
9
EOF
    check_eq "wizard: partition grown by 50 MiB" "$(mib 150)" "$(dev_bytes "$p")"
    check_eq "wizard: file system grown" "$(mib 150)" "$(ext_bytes "$p")"

    # Shrink: 80M
    main_menu >"$WORK/flow3.log" 2>&1 <<EOF
3
$idx
1
80M
9
EOF
    check_eq "wizard: partition shrunk to 80 MiB" "$(mib 80)" "$(dev_bytes "$p")"
    check_eq "wizard: file system shrunk" "$(mib 80)" "$(ext_bytes "$p")"

    # Dry run: nothing changes
    PW_DRY_RUN=1
    main_menu >"$WORK/flow4.log" 2>&1 <<EOF
2
$idx
1

9
EOF
    PW_DRY_RUN=0
    check_eq "wizard: dry run changes nothing" "$(mib 80)" "$(dev_bytes "$p")"
    check "wizard: dry run shows the commands" grep -q 'dry-run.*sfdisk' "$WORK/flow4.log"
    check "wizard: an empty answer selects the default size (max)" grep -q "dry-run.*echo ', [0-9]*' | sfdisk" "$WORK/flow4.log"

    # Delete a mounted partition (it is unmounted after the confirmation)
    mount "$p" "$WORK/m"
    main_menu >"$WORK/flow5.log" 2>&1 <<EOF
5
$idx
1
9
EOF
    load_table "$d"
    check_eq "wizard: partition deleted" 0 "${#T_NR[@]}"
    check "wizard: partition unmounted before deletion" not findmnt -n "$WORK/m"
}

# --- command line -----------------------------------------------------------------------

test_cli() {
    echo "== Command line"
    local out
    out=$(PW_LOG_FILE="$WORK/cli.log" "$SCRIPT" --list --include-loop 2>/dev/null)
    check "--list writes to standard output" grep -q "Disks and partitions" <<<"$out"
    check "--version" grep -q "^partition-wizard [0-9]" <<<"$("$SCRIPT" --version)"
    check "unknown options are rejected" not "$SCRIPT" --no-such-option 2>/dev/null
}

# --- run ---------------------------------------------------------------------------------

mkdir -p "$WORK/m"
test_units
test_gpt_ext4
test_online_grow
test_fstab_refs
test_gpt_disk_growth
test_mbr_logical
test_swap
test_xfs
test_btrfs
test_mbr_logical_delete
test_delete_in_use
test_backups
test_signatures
test_ntfs
test_vfat
test_luks
test_lvm
test_wizard_flows
test_cli

echo
printf 'Result: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))

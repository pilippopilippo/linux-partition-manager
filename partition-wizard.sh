#!/usr/bin/env bash
# =============================================================================
#  partition-wizard.sh
#
#  Interactive wizard to grow and modify disk partitions on Debian-based
#  (Debian, Ubuntu, Mint, ...) and Fedora-based (Fedora, RHEL, CentOS Stream,
#  Rocky, Alma, ...) Linux distributions.
#
#  Run it straight from GitHub:
#    sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/pilippopilippo/linux-partition-manager/main/partition-wizard.sh)"
#
#  Project: https://github.com/pilippopilippo/linux-partition-manager
#  License: MIT
# =============================================================================
#
# All code lives in functions and `main` is invoked on the very last line, so
# the script also works when bash reads it from a pipe.
# User-facing text is plain ASCII on purpose: it must render correctly on
# terminals and consoles that are not using a UTF-8 locale.

set -o pipefail

PW_VERSION="1.2.0"
PW_REPO="pilippopilippo/linux-partition-manager"
PW_RAW_URL="https://raw.githubusercontent.com/${PW_REPO}/main/partition-wizard.sh"
PW_RUN_CMD="sudo bash -c \"\$(curl -fsSL $PW_RAW_URL)\""
PW_SELF="${BASH_SOURCE[0]:-}"

# Options (set from the command line)
PW_MODE="wizard"          # wizard | list | install-deps | help | version
PW_DRY_RUN=0              # 1 = show commands without running them
PW_ASSUME_YES=0           # 1 = answer "yes" to every question (automated tests only)
PW_YES_DEPS=0             # 1 = install dependencies without asking
PW_NO_TUI=0               # 1 = plain text interface even if whiptail is available
PW_INCLUDE_LOOP=0         # 1 = also list loop devices
PW_DISTRO=""              # debian | fedora (empty = auto-detect)
PW_LOG_FILE="${PW_LOG_FILE:-/var/log/partition-wizard.log}"
PW_BACKUP_DIR="${PW_BACKUP_DIR:-/var/backups/partition-wizard}"

# Internal state
PW_ARGS=()
PW_UI="text"
PW_DISTRO_NAME=""
PW_PKG_UPDATED=0
PW_TMP_MOUNTS=()
PW_LAST_MNT=""
PW_FSCK_DONE=""           # last ext2/3/4 device checked with e2fsck
PW_DISK_CHANGED=0         # 1 if prepare_disk_growth detected or changed something
SFDISK_OPTS=(--no-reread)

MIB=1048576

# GPT partition types
GPT_LINUX="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
GPT_SWAP="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"
GPT_LVM="E6D6D379-F507-44C2-A23C-238F2A3DF928"
GPT_MSDATA="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

# Core commands (always needed) and optional ones (per file system)
PW_CORE_CMDS=(sfdisk partx lsblk blkid findmnt wipefs blockdev awk)
PW_OPTIONAL_CMDS=(whiptail resize2fs xfs_growfs btrfs pvresize cryptsetup mkfs.vfat ntfsresize)

# -----------------------------------------------------------------------------
# Messages, log and command execution
# -----------------------------------------------------------------------------

init_colors() {
    C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD="" C_RESET=""
    if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
        C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m'
        C_BOLD=$'\e[1m' C_RESET=$'\e[0m'
    fi
}

log() {
    [[ -n $PW_LOG_FILE ]] || return 0
    { printf '%s [%d] %s\n' "$(date '+%F %T')" "$$" "$*" >>"$PW_LOG_FILE"; } 2>/dev/null || true
}

info() { printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*" >&2; log "INFO  $*"; }
ok() {
    if (( PW_DRY_RUN )); then
        printf '%s[OK]%s %s (simulated)\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2
    else
        printf '%s[OK]%s %s\n' "$C_GREEN$C_BOLD" "$C_RESET" "$*" >&2
    fi
    log "OK    $*"
}
warn() { printf '%sWARNING:%s %s\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2; log "WARN  $*"; }
err()  { printf '%sERROR:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; log "ERROR $*"; }
die()  { err "$*"; exit 1; }

# Runs a command, printing it on screen and recording it in the log.
# In dry-run mode the command is only printed.
run() {
    local cmdline rc
    printf -v cmdline '%q ' "$@"
    cmdline=${cmdline% }
    if (( PW_DRY_RUN )); then
        printf '%s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$cmdline" >&2
        log "DRY   $cmdline"
        return 0
    fi
    printf '%s#%s %s\n' "$C_BOLD" "$C_RESET" "$cmdline" >&2
    log "RUN   $cmdline"
    "$@"
    rc=$?
    (( rc == 0 )) || log "EXIT  $rc: $cmdline"
    return "$rc"
}

# Like run, but feeds the first argument to the command's standard input.
run_input() {
    local input=$1 cmdline rc
    shift
    printf -v cmdline '%q ' "$@"
    if [[ $input == *$'\n'* ]]; then
        cmdline="${cmdline% } <<< ($(wc -l <<<"$input") lines of input)"
    else
        cmdline="echo '${input//\'/\'\\\'\'}' | ${cmdline% }"
    fi
    if (( PW_DRY_RUN )); then
        printf '%s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$cmdline" >&2
        log "DRY   $cmdline"
        return 0
    fi
    printf '%s#%s %s\n' "$C_BOLD" "$C_RESET" "$cmdline" >&2
    log "RUN   $cmdline"
    printf '%s\n' "$input" | "$@"
    rc=$?
    (( rc == 0 )) || log "EXIT  $rc: $cmdline"
    return "$rc"
}

# During critical operations Ctrl+C is ignored (also by the commands that are
# started), so that file systems and partition tables are never left half done.
critical_begin() { trap '' INT QUIT; }
critical_end()   { trap on_interrupt INT QUIT; }

on_interrupt() {
    printf '\n' >&2
    warn "Interrupted by the user."
    exit 130
}

cleanup() {
    local d
    for d in "${PW_TMP_MOUNTS[@]}"; do
        umount "$d" 2>/dev/null
        rmdir "$d" 2>/dev/null
    done
    PW_TMP_MOUNTS=()
}

# -----------------------------------------------------------------------------
# Utilities
# -----------------------------------------------------------------------------

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# Bytes -> human readable string (e.g. 21474836480 -> "20.00 GiB"), rounded
# down so that it never shows more space than is really available
human() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB PiB", u, " "); i = 1
        if (b < 0) { s = "-"; b = -b } else s = ""
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%s%d %s\n", s, b, u[i]
        else printf "%s%.2f %s\n", s, int(b * 100 + 1e-9) / 100, u[i]
    }'
}

# Human readable size -> bytes. Accepts K, M, G, T (powers of 1024), also with
# decimals: 500M, 20G, 1.5T, 2,5G, 10GiB, 10GB.
parse_size() {
    local s num unit mult
    s=${1^^}
    s=${s// /}
    [[ $s =~ ^([0-9]+([.,][0-9]+)?)([KMGT])(I?B)?$ ]] || return 1
    num=${BASH_REMATCH[1]/,/.}
    unit=${BASH_REMATCH[3]}
    case $unit in
        K) mult=1024 ;;
        M) mult=$MIB ;;
        G) mult=$(( 1024 * MIB )) ;;
        T) mult=$(( 1024 * 1024 * MIB )) ;;
    esac
    awk -v n="$num" -v m="$mult" 'BEGIN { printf "%.0f\n", n * m }'
}

kname()     { basename "$(readlink -f "$1")"; }
dev_bytes() { blockdev --getsize64 "$1" 2>/dev/null || echo 0; }

# Content type of a device: ext4, xfs, btrfs, swap, crypto_LUKS, LVM2_member,
# ntfs, vfat, ... (empty if not recognised)
fs_type() {
    local t
    t=$(blkid -p -o value -s TYPE "$1" 2>/dev/null | head -n1)
    [[ -n $t ]] || t=$(lsblk -dno FSTYPE "$1" 2>/dev/null | head -n1)
    trim "$t"
}

fs_prop() { blkid -p -o value -s "$2" "$1" 2>/dev/null | head -n1; }

mountpoint_of() {
    local m
    m=$(findmnt -ln -o TARGET --source "$1" 2>/dev/null | head -n1)
    trim "$m"
}

# All the places where DEV is mounted (bind mounts, btrfs subvolumes ...)
mountpoints_of() {
    local m
    while IFS= read -r m; do
        m=$(trim "$m")
        [[ -n $m ]] && printf '%s\n' "$m"
    done < <(findmnt -ln -o TARGET --source "$1" 2>/dev/null)
}

# Unmounts every mount point of DEV; fails if it is still mounted afterwards
unmount_all() {
    local m mnts=()
    mapfile -t mnts < <(mountpoints_of "$1" | sort -r)
    for m in "${mnts[@]}"; do
        run umount "$m" || return 1
    done
    (( PW_DRY_RUN )) || [[ -z $(mountpoint_of "$1") ]]
}

# Signatures found on a device (file systems, partition tables, RAID, LVM ...)
dev_signatures() {
    local s
    s=$(wipefs -n -O TYPE --noheadings "$1" 2>/dev/null | awk 'NF && !seen[$1]++ { print $1 }' | paste -sd, -)
    [[ -n $s ]] || s=$(fs_type "$1")
    printf '%s' "$s"
}

clear_screen() { clear 2>/dev/null || printf '\033[H\033[2J'; }

swap_active() {
    local d n
    d=$(readlink -f "$1")
    while read -r n _; do
        [[ $n == /dev/* && $(readlink -f "$n") == "$d" ]] && return 0
    done </proc/swaps
    return 1
}

# Devices built on top of DEV (LVM, LUKS, RAID ...)
dev_holders() {
    local h
    for h in /sys/class/block/"$(kname "$1")"/holders/*; do
        [[ -e $h ]] && printf '/dev/%s\n' "${h##*/}"
    done
}

# First "child" device shown by lsblk (e.g. /dev/mapper/vg-root)
dev_child() { lsblk -lnpo NAME "$1" 2>/dev/null | sed -n '2p'; }

dev_in_use() {
    [[ -n $(mountpoint_of "$1") ]] && return 0
    swap_active "$1" && return 0
    [[ -n $(dev_holders "$1") ]] && return 0
    return 1
}

disk_in_use() {
    local disk=$1 p t
    dev_in_use "$disk" && return 0
    while read -r p t; do
        [[ $t == part ]] && dev_in_use "$p" && return 0
    done < <(lsblk -lnpo NAME,TYPE "$disk" 2>/dev/null)
    return 1
}

# Partition number of a partition device
part_nr() {
    local f
    f="/sys/class/block/$(kname "$1")/partition"
    if [[ -r $f ]]; then cat "$f"; else printf '%s\n' "${1##*[!0-9]}"; fi
}

# Device of partition NR on disk DISK (e.g. /dev/sda 2 -> /dev/sda2,
# /dev/nvme0n1 2 -> /dev/nvme0n1p2)
part_dev() {
    local disk=$1 nr=$2 dn p
    dn=$(kname "$disk")
    for p in /sys/class/block/"$dn"/"$dn"*; do
        if [[ -r $p/partition && $(<"$p/partition") == "$nr" ]]; then
            printf '/dev/%s\n' "${p##*/}"
            return 0
        fi
    done
    if [[ $dn == *[0-9] ]]; then printf '/dev/%sp%s\n' "$dn" "$nr"; else printf '/dev/%s%s\n' "$dn" "$nr"; fi
}

wait_for_dev() {
    local i
    for i in $(seq 1 40); do
        [[ -b $1 ]] && return 0
        sleep 0.25
    done
    [[ -b $1 ]]
}

# -----------------------------------------------------------------------------
# Terminal checks
# -----------------------------------------------------------------------------

# Fields of /proc/PID/stat after the command name: state ppid pgrp session tty_nr
proc_field() {   # pid field_number
    local stat rest f
    stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    rest=${stat##*) }
    read -r -a f <<<"$rest"
    printf '%s\n' "${f[$2 - 1]}"
}

# True when keystrokes can never reach this script: it was piped into a sudo
# that runs it in its own pseudo-terminal ("use_pty", the default on Debian 13
# and Ubuntu 24.04). That sudo only forwards the keyboard when its own standard
# input is a terminal, which is not the case with "curl ... | sudo bash".
keyboard_unreachable() {
    local mytty pid n comm fd0
    mytty=$(proc_field $$ 5) || return 1
    pid=$PPID
    for (( n = 0; n < 16 && pid > 1; n++ )); do
        if [[ $(proc_field "$pid" 5) != "$mytty" ]]; then
            # first ancestor attached to a different terminal
            comm=$(cat "/proc/$pid/comm" 2>/dev/null)
            fd0=$(readlink "/proc/$pid/fd/0" 2>/dev/null)
            [[ $comm == sudo && $fd0 != /dev/pts/* && $fd0 != /dev/tty* ]]
            return
        fi
        pid=$(proc_field "$pid" 2) || return 1
    done
    return 1
}

pipe_hint() {
    cat >&2 <<EOF

The wizard cannot read the keyboard when it is piped into sudo:
sudo runs it in a separate pseudo-terminal ("use_pty", the default on
Debian 13 and Ubuntu 24.04) and does not forward keystrokes to it.

Run it like this instead:

  $PW_RUN_CMD

EOF
}

# -----------------------------------------------------------------------------
# Distribution and dependencies
# -----------------------------------------------------------------------------

detect_distro() {
    local id="" like=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        id=$(. /etc/os-release && printf '%s' "${ID:-}")
        # shellcheck disable=SC1091
        like=$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")
        # shellcheck disable=SC1091
        PW_DISTRO_NAME=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$ID}")
    fi
    [[ -n $PW_DISTRO ]] && return 0
    case " $id $like " in
        *" debian "* | *" ubuntu "*) PW_DISTRO="debian" ;;
        *" fedora "* | *" rhel "* | *" centos "*) PW_DISTRO="fedora" ;;
        *)
            if command -v apt-get >/dev/null 2>&1; then
                PW_DISTRO="debian"
            elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
                PW_DISTRO="fedora"
            fi
            ;;
    esac
}

# Package providing a command, for the current distribution family
pkg_for_cmd() {
    case "$PW_DISTRO:$1" in
        debian:sfdisk) echo fdisk ;;
        debian:swapon | debian:swapoff | debian:mount | debian:umount) echo mount ;;
        *:sfdisk | *:partx | *:lsblk | *:blkid | *:findmnt | *:wipefs | *:blockdev | *:mkswap | *:swapon | *:swapoff | *:mount | *:umount) echo util-linux ;;
        debian:awk) echo mawk ;;
        fedora:awk) echo gawk ;;
        *:sgdisk) echo gdisk ;;
        debian:whiptail) echo whiptail ;;
        fedora:whiptail) echo newt ;;
        *:resize2fs | *:e2fsck | *:dumpe2fs | *:mkfs.ext4) echo e2fsprogs ;;
        *:xfs_growfs | *:mkfs.xfs) echo xfsprogs ;;
        *:btrfs | *:mkfs.btrfs) echo btrfs-progs ;;
        *:lvm | *:pvresize | *:pvcreate | *:pvs | *:vgs | *:lvs | *:vgextend | *:lvextend) echo lvm2 ;;
        *:cryptsetup) echo cryptsetup ;;
        *:mkfs.vfat) echo dosfstools ;;
        debian:ntfsresize | debian:mkfs.ntfs) echo ntfs-3g ;;
        fedora:ntfsresize | fedora:mkfs.ntfs) echo ntfsprogs ;;
        *) return 1 ;;
    esac
}

install_pkgs() {
    case $PW_DISTRO in
        debian)
            if (( ! PW_PKG_UPDATED )); then
                run apt-get update -q && PW_PKG_UPDATED=1
            fi
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$@"
            ;;
        fedora)
            if command -v dnf >/dev/null 2>&1; then
                run dnf install -y "$@"
            else
                run yum install -y "$@"
            fi
            ;;
        *)
            err "Unknown distribution: please install these packages manually: $*"
            return 1
            ;;
    esac
}

# Checks that the given commands exist; offers to install the packages that
# provide the missing ones. Returns 1 if something is still missing.
ensure_cmds() {
    local c p missing=() pkgs=() unknown=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 && continue
        missing+=("$c")
        if p=$(pkg_for_cmd "$c"); then
            [[ " ${pkgs[*]} " == *" $p "* ]] || pkgs+=("$p")
        else
            unknown+=("$c")
        fi
    done
    (( ${#missing[@]} == 0 )) && return 0

    if (( ${#unknown[@]} )) || [[ -z $PW_DISTRO ]]; then
        err "Missing commands: ${missing[*]}. Please install them manually and try again."
        return 1
    fi
    if (( PW_DRY_RUN )); then
        err "Missing commands: ${missing[*]} (packages: ${pkgs[*]}). Nothing is installed in dry-run mode."
        return 1
    fi
    if (( ! PW_YES_DEPS )); then
        ui_yesno "Missing dependencies" "These commands are needed to continue: ${missing[*]}\n\nPackages to install: ${pkgs[*]}\n\nInstall them now?" || return 1
    fi
    install_pkgs "${pkgs[@]}" || { err "Package installation failed: ${pkgs[*]}"; return 1; }
    for c in "${missing[@]}"; do
        command -v "$c" >/dev/null 2>&1 || { err "The command '$c' is still not available."; return 1; }
    done
    return 0
}

install_all_deps() {
    local c p pkgs=() failed=() core_missing=()
    for c in "${PW_CORE_CMDS[@]}" "${PW_OPTIONAL_CMDS[@]}"; do
        command -v "$c" >/dev/null 2>&1 && continue
        p=$(pkg_for_cmd "$c") || continue
        [[ " ${pkgs[*]} " == *" $p "* ]] || pkgs+=("$p")
    done
    if (( ${#pkgs[@]} == 0 )); then
        ok "All dependencies are already installed."
        return 0
    fi
    info "Packages to install: ${pkgs[*]}"
    if (( ! PW_YES_DEPS )); then
        ui_yesno "Dependencies" "These packages will be installed:\n${pkgs[*]}\n\nContinue?" || return 1
    fi
    if ! install_pkgs "${pkgs[@]}"; then
        warn "Installing all packages at once failed: trying one package at a time."
        for p in "${pkgs[@]}"; do
            install_pkgs "$p" || failed+=("$p")
        done
    fi
    for c in "${PW_CORE_CMDS[@]}"; do
        command -v "$c" >/dev/null 2>&1 || core_missing+=("$c")
    done
    (( ${#failed[@]} )) && warn "Packages not installed (the related features are unavailable): ${failed[*]}"
    if (( ${#core_missing[@]} )); then
        err "Essential commands are still missing: ${core_missing[*]}"
        return 1
    fi
    ok "Dependencies installed."
}

# sfdisk options: the table is written without asking the kernel to re-read
# the whole disk (which fails when the disk is in use); the kernel is then
# updated partition by partition with partx.
init_sfdisk_opts() {
    local help
    help=$(LC_ALL=C sfdisk --help 2>/dev/null)
    if ! grep -q -- '--delete' <<<"$help"; then
        err "This sfdisk (util-linux) is too old: util-linux 2.28 or newer is required."
        return 1
    fi
    SFDISK_OPTS=(--no-reread)
    grep -q -- '--no-tell-kernel' <<<"$help" && SFDISK_OPTS+=(--no-tell-kernel)
    return 0
}

# -----------------------------------------------------------------------------
# User interface: whiptail when available, plain text otherwise
# -----------------------------------------------------------------------------

ui_init() {
    PW_UI="text"
    if (( ! PW_NO_TUI )) && command -v whiptail >/dev/null 2>&1 && [[ ${TERM:-dumb} != dumb ]]; then
        PW_UI="whiptail"
    fi
}

ui_size() {
    local rows=24 cols=80 sz
    if sz=$(stty size 2>/dev/null) && [[ $sz =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
        rows=${BASH_REMATCH[1]} cols=${BASH_REMATCH[2]}
    fi
    UI_W=$(( cols - 4 ))
    (( UI_W > 100 )) && UI_W=100
    (( UI_W < 40 )) && UI_W=40
    UI_HMAX=$(( rows - 2 ))
    (( UI_HMAX < 10 )) && UI_HMAX=10
}

# Number of lines a text takes inside the window
ui_lines() {
    awk -v w=$(( UI_W - 4 )) '{ l = length($0); n += (l > w) ? int((l + w - 1) / w) : 1 } END { print n + 0 }' <<<"$1"
}

# Turns "\n" sequences into real newlines
ui_fmt() { printf '%s' "${1//\\n/$'\n'}"; }

ui_header() { printf '\n%s=== %s ===%s\n' "$C_BOLD" "$1" "$C_RESET" >&2; }

screen_start() {
    [[ $PW_UI == whiptail && -t 1 ]] && clear_screen
    ui_header "$1"
}

pause() {
    (( PW_ASSUME_YES )) && return 0
    printf '\n' >&2
    read -r -p "Press Enter to ${1:-return to the menu}... " _
}

# Before opening a whiptail window after command output, give the user time
# to read it (whiptail clears the screen).
pause_if_tui() { [[ $PW_UI == whiptail ]] && pause "continue"; return 0; }

ui_msg() {
    local title=$1 text h
    text=$(ui_fmt "$2")
    if [[ $PW_UI == whiptail ]]; then
        ui_size
        h=$(( $(ui_lines "$text") + 7 ))
        if (( h > UI_HMAX )); then
            whiptail --title "$title" --scrolltext --msgbox "$text" "$UI_HMAX" "$UI_W"
        else
            whiptail --title "$title" --msgbox "$text" "$h" "$UI_W"
        fi
    else
        ui_header "$title"
        printf '%s\n' "$text" >&2
        (( PW_ASSUME_YES )) || read -r -p "Press Enter to continue... " _
    fi
    return 0
}

# ui_yesno TITLE TEXT [yes|no]  (third argument: default answer)
ui_yesno() {
    local title=$1 text def=${3:-yes} h ans
    (( PW_ASSUME_YES )) && return 0
    text=$(ui_fmt "$2")
    if [[ $PW_UI == whiptail ]]; then
        local args=(--title "$title" --yes-button "Yes" --no-button "No")
        [[ $def == no ]] && args+=(--defaultno)
        ui_size
        h=$(( $(ui_lines "$text") + 7 ))
        (( h > UI_HMAX )) && { h=$UI_HMAX; args+=(--scrolltext); }
        whiptail "${args[@]}" --yesno "$text" "$h" "$UI_W"
        return
    fi
    ui_header "$title"
    printf '%s\n' "$text" >&2
    while :; do
        if [[ $def == no ]]; then read -r -p "[y/N] " ans || return 1; else read -r -p "[Y/n] " ans || return 1; fi
        ans=$(trim "${ans,,}")
        case $ans in
            "") [[ $def != no ]]; return ;;
            y | yes) return 0 ;;
            n | no) return 1 ;;
        esac
    done
}

# ui_input TITLE TEXT [DEFAULT] -> prints the value entered.
# The field starts empty (a pre-filled value would be extended rather than
# replaced by what the user types); an empty answer means DEFAULT.
ui_input() {
    local title=$1 text def=${3:-} h val rc
    text=$(ui_fmt "$2")
    [[ -n $def ]] && text+=$'\n\n'"(Press Enter for: $def)"
    if [[ $PW_UI == whiptail ]]; then
        ui_size
        h=$(( $(ui_lines "$text") + 8 ))
        (( h > UI_HMAX )) && h=$UI_HMAX
        val=$(whiptail --title "$title" --ok-button "OK" --cancel-button "Cancel" \
            --inputbox "$text" "$h" "$UI_W" "" 3>&1 1>&2 2>&3)
        rc=$?
        (( rc == 0 )) || return "$rc"
    else
        ui_header "$title"
        printf '%s\n' "$text" >&2
        read -r -e -p "> " val || return 1
    fi
    val=$(trim "$val")
    printf '%s\n' "${val:-$def}"
}

# ui_menu TITLE TEXT tag1 item1 [tag2 item2 ...] -> prints the selected tag
# Optional variables: UI_CANCEL (label of the "Back" button),
# UI_NOTAGS=1 (show the items only, not the tags).
ui_menu() {
    local title=$1 text n tl lh h ans i
    text=$(ui_fmt "$2")
    shift 2
    n=$(( $# / 2 ))
    if [[ $PW_UI == whiptail ]]; then
        ui_size
        tl=$(ui_lines "$text")
        lh=$n
        (( lh > UI_HMAX - tl - 7 )) && lh=$(( UI_HMAX - tl - 7 ))
        (( lh < 2 )) && lh=2
        h=$(( tl + lh + 7 ))
        (( h > UI_HMAX )) && h=$UI_HMAX
        local wt_opts=()
        [[ -n ${UI_NOTAGS:-} ]] && wt_opts+=(--notags)
        whiptail --title "$title" --ok-button "Select" --cancel-button "${UI_CANCEL:-Back}" \
            "${wt_opts[@]}" --menu "$text" "$h" "$UI_W" "$lh" "$@" 3>&1 1>&2 2>&3
        return
    fi
    local tags=()
    ui_header "$title"
    printf '%s\n\n' "$text" >&2
    i=1
    while (( $# >= 2 )); do
        tags+=("$1")
        if [[ $1 == /* ]]; then
            printf '  %2d) %-18s %s\n' "$i" "$1" "$2" >&2
        else
            printf '  %2d) %s\n' "$i" "$2" >&2
        fi
        shift 2
        i=$(( i + 1 ))
    done
    printf '   0) %s\n' "${UI_CANCEL:-Back}" >&2
    while :; do
        read -r -p "Choice: " ans || return 1
        ans=$(trim "$ans")
        [[ -z $ans || $ans == 0 ]] && return 1
        if [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#tags[@]} )); then
            printf '%s\n' "${tags[ans - 1]}"
            return 0
        fi
    done
}

# Strong confirmation: the user must type an exact word.
ui_confirm_typed() {
    local title=$1 text=$2 word=$3 ans
    (( PW_ASSUME_YES )) && return 0
    ans=$(ui_input "$title" "$text\n\nTo confirm, type exactly: $word") || return 1
    [[ $(trim "$ans") == "$word" ]] && return 0
    ui_msg "$title" "The text you typed does not match: operation cancelled."
    return 1
}

# -----------------------------------------------------------------------------
# Reading the partition table (via sfdisk --dump)
# -----------------------------------------------------------------------------
# After load_table DISK the following are available:
#   T_LABEL  gpt | dos      T_SS     logical sector size (bytes)
#   T_TOTAL  total sectors  T_FIRST/T_LAST first/last usable sector
#   T_NR[] T_START[] T_SIZE[] T_TYPE[]  partitions (logical sectors)
#   T_ERR    reason when load_table fails (no table / unsupported table)
# Returns 1 when the disk has no partition table, 2 when its table type is
# not supported (only GPT and MBR/DOS are).

load_table() {
    local disk=$1 dump line
    T_LABEL="" T_FIRST=0 T_LAST=0 T_ERR=""
    T_NR=() T_START=() T_SIZE=() T_TYPE=()
    T_SS=$(blockdev --getss "$disk" 2>/dev/null) || T_SS=512
    [[ $T_SS =~ ^[0-9]+$ ]] || T_SS=512
    T_TOTAL=$(( $(dev_bytes "$disk") / T_SS ))
    if ! dump=$(LC_ALL=C sfdisk --dump "$disk" 2>/dev/null); then
        T_ERR="Disk $disk has no partition table."
        return 1
    fi
    while IFS= read -r line; do
        case $line in
            label:*) T_LABEL=$(trim "${line#label:}") ;;
            first-lba:*) T_FIRST=$(trim "${line#first-lba:}") ;;
            last-lba:*) T_LAST=$(trim "${line#last-lba:}") ;;
            /*)
                if [[ $line =~ ^([^[:space:]]+)[[:space:]]*:[[:space:]]*start=[[:space:]]*([0-9]+),[[:space:]]*size=[[:space:]]*([0-9]+),[[:space:]]*type=([^,[:space:]]+) ]]; then
                    T_NR+=("${BASH_REMATCH[1]##*[!0-9]}")
                    T_START+=("${BASH_REMATCH[2]}")
                    T_SIZE+=("${BASH_REMATCH[3]}")
                    T_TYPE+=("${BASH_REMATCH[4]}")
                fi
                ;;
        esac
    done <<<"$dump"
    case $T_LABEL in
        dos)
            T_FIRST=1
            T_LAST=$(( T_TOTAL - 1 ))
            # MBR: sectors are addressed with 32 bits (2 TiB with 512-byte sectors)
            (( T_LAST > 4294967295 )) && T_LAST=4294967295
            ;;
        gpt)
            (( T_FIRST > 0 )) || T_FIRST=34
            (( T_LAST > 0 )) || T_LAST=$(( T_TOTAL - 34 ))
            ;;
        "")
            T_ERR="Disk $disk has no partition table."
            return 1
            ;;
        *)
            T_ERR="Disk $disk uses a \"$T_LABEL\" partition table, which this wizard does not support (only GPT and MBR)."
            return 2
            ;;
    esac
    return 0
}

tbl_idx() {
    local i
    for i in "${!T_NR[@]}"; do
        [[ ${T_NR[i]} == "$1" ]] && { printf '%s\n' "$i"; return 0; }
    done
    return 1
}

is_extended_type() {
    case ${1,,} in
        5 | f | 85) return 0 ;;
    esac
    return 1
}

is_extended_idx() { [[ $T_LABEL == dos ]] && is_extended_type "${T_TYPE[$1]}"; }

# Last sector partition NR can reach without moving the other partitions
part_max_end() {
    local nr=$1 i j start limit e align
    i=$(tbl_idx "$nr") || return 1
    start=${T_START[i]}
    limit=$T_LAST
    align=$(( MIB / T_SS ))
    for j in "${!T_NR[@]}"; do
        (( j == i )) && continue
        (( T_START[j] > start )) || continue
        if [[ $T_LABEL == dos ]] && (( nr >= 5 )) && (( T_NR[j] >= 5 )); then
            # next logical partition: leave room for its EBR
            e=$(( T_START[j] - align - 1 ))
        else
            e=$(( T_START[j] - 1 ))
        fi
        (( e < limit )) && limit=$e
    done
    printf '%s\n' "$limit"
}

# Unallocated regions (>= 1 MiB, start aligned to 1 MiB) where a primary/GPT
# partition can be created. Prints "start end".
free_regions() {
    local i s e pos align lines=()
    align=$(( MIB / T_SS ))
    for i in "${!T_NR[@]}"; do
        [[ $T_LABEL == dos ]] && (( T_NR[i] >= 5 )) && continue
        lines+=("${T_START[i]} $(( T_START[i] + T_SIZE[i] - 1 ))")
    done
    pos=$T_FIRST
    while read -r s e; do
        [[ -n $s ]] || continue
        _emit_gap "$pos" $(( s - 1 )) "$align"
        (( e + 1 > pos )) && pos=$(( e + 1 ))
    done < <(printf '%s\n' "${lines[@]}" | sort -n)
    _emit_gap "$pos" "$T_LAST" "$align"
}

_emit_gap() {
    local a=$(( ($1 + $3 - 1) / $3 * $3 ))
    (( $2 - a + 1 >= $3 )) && printf '%s %s\n' "$a" "$2"
    return 0
}

# Space (bytes) beyond the end of the GPT: non-zero after a virtual disk has
# been enlarged, until the backup header is moved to the new end.
gpt_tail_gap() {
    local entries std_last
    [[ $T_LABEL == gpt ]] || { echo 0; return; }
    entries=$(( (16384 + T_SS - 1) / T_SS ))
    std_last=$(( T_TOTAL - 2 - entries ))
    if (( std_last > T_LAST )); then echo $(( (std_last - T_LAST) * T_SS )); else echo 0; fi
}

# First free partition number (to predict the device name in dry-run mode)
first_free_nr() {
    local n max=128
    [[ $T_LABEL == dos ]] && max=4
    for (( n = 1; n <= max; n++ )); do
        tbl_idx "$n" >/dev/null || { echo "$n"; return 0; }
    done
    return 1
}

ptype_code() {
    if [[ $1 == gpt ]]; then
        case $2 in
            swap) echo "$GPT_SWAP" ;;
            lvm) echo "$GPT_LVM" ;;
            vfat | ntfs) echo "$GPT_MSDATA" ;;
            *) echo "$GPT_LINUX" ;;
        esac
    else
        case $2 in
            swap) echo 82 ;;
            lvm) echo 8e ;;
            vfat) echo c ;;
            ntfs) echo 7 ;;
            *) echo 83 ;;
        esac
    fi
}

# -----------------------------------------------------------------------------
# Disk and partition lists and descriptions
# -----------------------------------------------------------------------------

list_disks() {
    local name type ro
    while read -r name type ro; do
        case $type in
            disk) ;;
            loop) (( PW_INCLUDE_LOOP )) || continue ;;
            *) continue ;;
        esac
        [[ $name == /dev/zram* ]] && continue
        [[ $ro == 1 ]] && continue
        (( $(dev_bytes "$name") > 0 )) || continue
        printf '%s\n' "$name"
    done < <(lsblk -dnpo NAME,TYPE,RO 2>/dev/null)
}

disk_desc() {
    local d=$1 model pt nparts
    model=$(trim "$(lsblk -dno MODEL "$d" 2>/dev/null)")
    pt=$(fs_prop "$d" PTTYPE)
    case $pt in
        gpt) pt="GPT" ;;
        dos) pt="MBR" ;;
        "") pt=$(fs_type "$d"); pt=${pt:+contains $pt}; pt=${pt:-no table} ;;
    esac
    nparts=$(lsblk -lno TYPE "$d" 2>/dev/null | grep -c '^part$')
    printf '%10s  %-16s %2s part.  %s' "$(human "$(dev_bytes "$d")")" "$pt" "$nparts" "$model"
}

select_disk() {
    local title=$1 text=$2 d disks=() items=()
    mapfile -t disks < <(list_disks)
    if (( ${#disks[@]} == 0 )); then
        ui_msg "$title" "No disks available."
        return 1
    fi
    for d in "${disks[@]}"; do
        items+=("$d" "$(disk_desc "$d")")
    done
    ui_menu "$title" "$text" "${items[@]}"
}

# Description of the partition at index I of the loaded table
part_desc() {
    local dev=$1 i=$2 size t label where
    size=$(human $(( T_SIZE[i] * T_SS )))
    if is_extended_idx "$i"; then
        printf '%10s  extended partition (holds the logical ones)' "$size"
        return
    fi
    t=$(fs_type "$dev")
    label=$(fs_prop "$dev" LABEL)
    where=$(mountpoint_of "$dev")
    swap_active "$dev" && where="[active swap]"
    if [[ -z $where && -n $(dev_holders "$dev") ]]; then
        where="-> $(dev_child "$dev")"
    fi
    printf '%10s  %-12s %-14s %s' "$size" "${t:--}" "${label:+[$label]}" "$where"
}

# select_partition DISK TITLE TEXT [1 = include extended partitions]
select_partition() {
    local disk=$1 title=$2 text=$3 with_ext=${4:-0} i dev items=()
    if ! load_table "$disk"; then
        ui_msg "$title" "$T_ERR"
        return 1
    fi
    for i in "${!T_NR[@]}"; do
        if is_extended_idx "$i" && (( ! with_ext )); then
            continue
        fi
        dev=$(part_dev "$disk" "${T_NR[i]}")
        items+=("$dev" "$(part_desc "$dev" "$i")")
    done
    if (( ${#items[@]} == 0 )); then
        ui_msg "$title" "No partitions found on $disk."
        return 1
    fi
    ui_menu "$title" "$text" "${items[@]}"
}

show_disk() {
    printf '\n' >&2
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$1" >&2 2>/dev/null
}

# -----------------------------------------------------------------------------
# Low-level operations
# -----------------------------------------------------------------------------

backup_table() {
    local disk=$1 base f n=1
    base="$PW_BACKUP_DIR/$(kname "$disk")-$(date +%Y%m%d-%H%M%S)"
    f="$base.sfdisk"
    while [[ -e $f ]]; do
        f="$base-$n.sfdisk"
        n=$(( n + 1 ))
    done
    if (( PW_DRY_RUN )); then
        printf '%s[dry-run]%s partition table backup to %s\n' "$C_YELLOW" "$C_RESET" "$f" >&2
        return 0
    fi
    if mkdir -p "$PW_BACKUP_DIR" && sfdisk --dump "$disk" >"$f" 2>/dev/null; then
        info "Partition table backup: $f"
        info "To restore it: sfdisk $disk < $f"
        log "BACKUP $disk -> $f"
    else
        rm -f "$f"
        warn "Could not save a backup of the partition table of $disk."
    fi
    return 0
}

# Kernel partitions of DISK: prints "number start size" (512-byte units)
kernel_parts() {
    local dn p
    dn=$(kname "$1")
    for p in /sys/class/block/"$dn"/"$dn"*; do
        [[ -r $p/partition && -r $p/start && -r $p/size ]] || continue
        printf '%s %s %s\n' "$(<"$p/partition")" "$(<"$p/start")" "$(<"$p/size")"
    done
}

# True when the kernel sees exactly the partitions of the table on disk
kernel_in_sync() {
    local disk=$1 nr kstart ksize i n=0
    load_table "$disk" || return 0
    while read -r nr kstart ksize; do
        i=$(tbl_idx "$nr") || return 1
        (( kstart == T_START[i] * T_SS / 512 )) || return 1
        is_extended_idx "$i" || (( ksize == T_SIZE[i] * T_SS / 512 )) || return 1
        n=$(( n + 1 ))
    done < <(kernel_parts "$disk")
    (( n == ${#T_NR[@]} ))
}

# Tells the kernel about partition table changes. Kernel partitions that no
# longer exist, or that now start elsewhere (e.g. logical partitions that were
# renumbered), are removed first so that they can be added again correctly;
# partitions in use cannot be removed and keep their old layout until reboot.
# With "quiet" as second argument no warning is printed if that happens.
reread_table() {
    local disk=$1 quiet=${2:-} nr kstart i
    (( PW_DRY_RUN )) && return 0
    sync
    if load_table "$disk"; then
        while read -r nr kstart _; do
            if ! i=$(tbl_idx "$nr") || (( T_START[i] * T_SS / 512 != kstart )); then
                partx -d --nr "$nr" "$disk" >/dev/null 2>&1
            fi
        done < <(kernel_parts "$disk")
    fi
    partx -u "$disk" >/dev/null 2>&1
    partx -a "$disk" >/dev/null 2>&1
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=15 >/dev/null 2>&1
    fi
    if ! kernel_in_sync "$disk"; then
        [[ -n $quiet ]] || warn "The kernel still uses the old layout for some partitions of $disk (probably because they are in use). Reboot before making further changes to this disk."
        return 1
    fi
    return 0
}

rescan_disk() {
    local disk=$1 dn f
    dn=$(kname "$disk")
    f="/sys/class/block/$dn/device/rescan"
    if [[ -w $f ]]; then
        run_input 1 tee "$f" >/dev/null
    elif [[ $dn == loop* ]]; then
        run losetup -c "$disk"
    fi
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=15 >/dev/null 2>&1
    fi
    return 0
}

fix_gpt() {
    local disk=$1
    backup_table "$disk"
    if run sfdisk "${SFDISK_OPTS[@]}" --relocate gpt-bak-std "$disk"; then
        :
    elif ensure_cmds sgdisk && run sgdisk -e "$disk"; then
        :
    else
        err "Could not move the backup GPT header of $disk."
        return 1
    fi
    reread_table "$disk"
    ok "GPT now extends to the end of the disk."
}

# Detects a disk that has been enlarged and fixes the GPT if needed
prepare_disk_growth() {
    local disk=$1 before after gap
    PW_DISK_CHANGED=0
    before=$(dev_bytes "$disk")
    rescan_disk "$disk"
    after=$(dev_bytes "$disk")
    if (( after != before )); then
        info "New size detected for $disk: $(human "$before") -> $(human "$after")"
        PW_DISK_CHANGED=1
    fi
    load_table "$disk" || return 0
    gap=$(gpt_tail_gap)
    if (( gap >= MIB )); then
        if ui_yesno "Extend GPT" "The GPT of $disk does not cover the whole disk: $(human "$gap") at the end cannot be used.\n\nThis is normal after enlarging a virtual disk. Move the backup GPT header to the end of the disk to make this space available?\n\n(This is safe and does not change the existing partitions.)"; then
            fix_gpt "$disk"
            load_table "$disk"
            PW_DISK_CHANGED=1
        fi
    fi
    return 0
}

# Sets the end sector of partition NR (grow or shrink).
# Returns 2 if the table was written but the kernel still uses the old size
# (a reboot is needed).
set_part_end() {
    local disk=$1 nr=$2 new_end=$3 i j start ext_end part expected actual
    load_table "$disk" || return 1
    i=$(tbl_idx "$nr") || { err "Partition $nr not found on $disk."; return 1; }
    start=${T_START[i]}
    backup_table "$disk"
    if [[ $T_LABEL == dos ]] && (( nr >= 5 )); then
        for j in "${!T_NR[@]}"; do
            is_extended_idx "$j" || continue
            ext_end=$(( T_START[j] + T_SIZE[j] - 1 ))
            if (( new_end > ext_end )); then
                info "Growing extended partition ${T_NR[j]} first, since it holds the logical partition."
                run_input ", $(( new_end - T_START[j] + 1 ))" sfdisk "${SFDISK_OPTS[@]}" -N "${T_NR[j]}" "$disk" || return 1
            fi
        done
    fi
    run_input ", $(( new_end - start + 1 ))" sfdisk "${SFDISK_OPTS[@]}" -N "$nr" "$disk" || return 1
    reread_table "$disk" quiet
    (( PW_DRY_RUN )) && return 0
    part=$(part_dev "$disk" "$nr")
    expected=$(( (new_end - start + 1) * T_SS ))
    actual=$(dev_bytes "$part")
    if (( actual != expected )); then
        warn "The table was updated, but the kernel still sees $part with its old size ($(human "$actual"))."
        warn "Reboot, then run \"Grow\" again on the same partition to finish the operation."
        return 2
    fi
    ok "Partition $part is now $(human "$expected")."
}

temp_mount() {   # device [mount options...]
    local dev=$1 d
    shift
    d=$(mktemp -d /tmp/partition-wizard.XXXXXX) || return 1
    if ! run mount "$@" "$dev" "$d"; then
        rmdir "$d" 2>/dev/null
        return 1
    fi
    PW_TMP_MOUNTS+=("$d")
    PW_LAST_MNT=$d
}

temp_umount() {
    local d=$1 i
    run umount "$d" && rmdir "$d" 2>/dev/null
    for i in "${!PW_TMP_MOUNTS[@]}"; do
        [[ ${PW_TMP_MOUNTS[i]} == "$d" ]] && unset 'PW_TMP_MOUNTS[i]'
    done
    PW_TMP_MOUNTS=("${PW_TMP_MOUNTS[@]}")
}

# ID of the device inside a (possibly multi-device) btrfs file system
btrfs_devid() {
    local dev=$1 mnt=$2 real line
    real=$(readlink -f "$dev")
    while IFS= read -r line; do
        if [[ $line =~ devid[[:space:]]+([0-9]+).*path[[:space:]]+([^[:space:]]+) ]]; then
            if [[ $(readlink -f "${BASH_REMATCH[2]}") == "$real" ]]; then
                printf '%s\n' "${BASH_REMATCH[1]}"
                return 0
            fi
        fi
    done < <(LC_ALL=C btrfs filesystem show "$mnt" 2>/dev/null)
    echo 1
}

e2fsck_ok() {
    local rc
    run e2fsck -f -p "$1"
    rc=$?
    if (( rc >= 4 )); then
        err "e2fsck found errors it cannot fix automatically (code $rc). Run 'e2fsck -f $1' manually."
        return 1
    fi
    return 0
}

# Grows file system TYPE on device DEV to fill the whole device
grow_fs() {
    local dev=$1 t=$2 mnt tmp="" rc=0 devid uuid label was_active=0 args=()
    case $t in
        ext2 | ext3 | ext4)
            ensure_cmds resize2fs e2fsck || return 1
            mnt=$(mountpoint_of "$dev")
            if [[ -z $mnt ]]; then
                e2fsck_ok "$dev" || return 1
            fi
            run resize2fs "$dev" || rc=$?
            ;;
        xfs)
            ensure_cmds xfs_growfs || return 1
            mnt=$(mountpoint_of "$dev")
            if [[ -z $mnt ]]; then
                # nouuid: also works for a copy of a file system that is mounted
                temp_mount "$dev" -o nouuid || return 1
                mnt=$PW_LAST_MNT tmp=$PW_LAST_MNT
            fi
            run xfs_growfs "$mnt" || rc=$?
            ;;
        btrfs)
            ensure_cmds btrfs || return 1
            mnt=$(mountpoint_of "$dev")
            if [[ -z $mnt ]]; then
                temp_mount "$dev" || return 1
                mnt=$PW_LAST_MNT tmp=$PW_LAST_MNT
            fi
            devid=$(btrfs_devid "$dev" "$mnt")
            run btrfs filesystem resize "$devid:max" "$mnt" || rc=$?
            ;;
        ntfs)
            ensure_cmds ntfsresize || return 1
            if [[ -n $(mountpoint_of "$dev") ]]; then
                err "NTFS partition $dev is mounted: unmount it before growing it."
                return 1
            fi
            run_input y ntfsresize -f "$dev" || rc=$?
            (( rc == 0 )) && info "Windows will run a disk check at its next boot: this is normal."
            ;;
        swap)
            uuid=$(fs_prop "$dev" UUID)
            label=$(fs_prop "$dev" LABEL)
            [[ -n $uuid ]] && args+=(-U "$uuid")
            [[ -n $label ]] && args+=(-L "$label")
            if swap_active "$dev"; then
                was_active=1
                run swapoff "$dev" || return 1
            fi
            run mkswap "${args[@]}" "$dev" || rc=$?
            (( was_active )) && run swapon "$dev"
            ;;
        *)
            warn "Automatic growing is not supported for '$t'."
            return 1
            ;;
    esac
    [[ -n $tmp ]] && temp_umount "$tmp"
    if (( rc == 0 )); then
        ok "File system $t on $dev grown."
    else
        err "Growing file system $t on $dev failed (code $rc)."
    fi
    return "$rc"
}

grow_luks() {
    local dev=$1 mapper
    mapper=$(lsblk -lnpo NAME,TYPE "$dev" 2>/dev/null | awk '$2 == "crypt" { print $1; exit }')
    if [[ -z $mapper ]]; then
        warn "The LUKS volume on $dev is not open: it will use all the space the next time it is opened."
        warn "After opening it, grow its contents with this wizard (\"Grow\" option)."
        return 0
    fi
    ensure_cmds cryptsetup || return 1
    info "Resizing encrypted volume $mapper (the passphrase may be requested)."
    run cryptsetup resize "${mapper##*/}" || { err "cryptsetup resize failed."; return 1; }
    ok "Encrypted volume $mapper grown."
    grow_contents "$mapper"
}

grow_pv() {
    local dev=$1 vg
    ensure_cmds pvresize pvs || return 1
    run pvresize "$dev" || { err "pvresize failed."; return 1; }
    ok "LVM physical volume $dev grown."
    vg=$(trim "$(pvs --noheadings -o vg_name "$dev" 2>/dev/null)")
    [[ -n $vg ]] || return 0
    pause_if_tui
    if ui_yesno "LVM" "The new space is now available in volume group \"$vg\".\n\nAssign it to a logical volume now (growing its file system too)?"; then
        lvm_extend "$vg"
    fi
}

# Recursively grows the contents of a device that has just been enlarged:
# LUKS -> LVM -> file system.
grow_contents() {
    local dev=$1 t
    t=$(fs_type "$dev")
    case $t in
        crypto_LUKS) grow_luks "$dev" ;;
        LVM2_member) grow_pv "$dev" ;;
        ext2 | ext3 | ext4 | xfs | btrfs | ntfs | swap) grow_fs "$dev" "$t" ;;
        "")
            info "No file system found on $dev: only the partition was grown."
            return 0
            ;;
        *)
            warn "Contents '$t' of $dev cannot be grown automatically: please grow it manually."
            return 0
            ;;
    esac
}

# Minimum size (bytes) of the file system, for shrinking
fs_min_bytes() {
    local dev=$1 t=$2 mnt=${3:-} devid=${4:-1} blocks bs out
    case $t in
        ext2 | ext3 | ext4)
            blocks=$(LC_ALL=C resize2fs -P "$dev" 2>/dev/null | awk -F': *' '/minimum size/ { print $2 }')
            bs=$(LC_ALL=C dumpe2fs -h "$dev" 2>/dev/null | awk -F': *' '/^Block size/ { print $2 }')
            [[ $blocks =~ ^[0-9]+$ && $bs =~ ^[0-9]+$ ]] || return 1
            echo $(( blocks * bs ))
            ;;
        btrfs)
            out=$(LC_ALL=C btrfs inspect-internal min-dev-size --id "$devid" "$mnt" 2>/dev/null)
            [[ $out =~ ^([0-9]+) ]] || return 1
            echo "${BASH_REMATCH[1]}"
            ;;
        ntfs)
            out=$(LC_ALL=C ntfsresize -f -i "$dev" 2>/dev/null | sed -n 's/.*resize at \([0-9][0-9]*\) bytes.*/\1/p' | head -n1)
            [[ $out =~ ^[0-9]+$ ]] || return 1
            echo "$out"
            ;;
        swap | "")
            echo "$MIB"
            ;;
        *) return 1 ;;
    esac
}

# Shrinks partition NR so that it ends at sector NEW_END: first the file system
# is shrunk (with a small margin), then the partition, and finally the file
# system is grown again to fill the new partition exactly.
# ext2/3/4 and NTFS file systems must be unmounted.
op_shrink() {
    local disk=$1 nr=$2 new_end=$3 i start part t new_bytes fs_target margin mnt tmp="" devid
    local rc=0 uuid label was_active=0 args=()
    load_table "$disk" || return 1
    i=$(tbl_idx "$nr") || return 1
    start=${T_START[i]}
    part=$(part_dev "$disk" "$nr")
    t=$(fs_type "$part")
    new_bytes=$(( (new_end - start + 1) * T_SS ))
    margin=$(( 16 * MIB ))
    (( margin > new_bytes / 4 )) && margin=$(( new_bytes / 4 / MIB * MIB ))
    fs_target=$(( new_bytes - margin ))

    case $t in
        ext2 | ext3 | ext4)
            ensure_cmds resize2fs e2fsck || return 1
            if [[ $PW_FSCK_DONE != "$part" ]]; then
                e2fsck_ok "$part" || return 1
            fi
            PW_FSCK_DONE=""
            run resize2fs "$part" "$(( fs_target / 1024 ))K" || { err "Shrinking the file system failed: the partition was not changed."; return 1; }
            set_part_end "$disk" "$nr" "$new_end" || return $?
            run resize2fs "$part" || rc=$?
            ;;
        btrfs)
            ensure_cmds btrfs || return 1
            mnt=$(mountpoint_of "$part")
            if [[ -z $mnt ]]; then
                temp_mount "$part" || return 1
                mnt=$PW_LAST_MNT tmp=$PW_LAST_MNT
            fi
            devid=$(btrfs_devid "$part" "$mnt")
            if ! run btrfs filesystem resize "$devid:$fs_target" "$mnt"; then
                err "Shrinking the file system failed: the partition was not changed."
                [[ -n $tmp ]] && temp_umount "$tmp"
                return 1
            fi
            set_part_end "$disk" "$nr" "$new_end" || rc=$?
            (( rc == 0 )) && { run btrfs filesystem resize "$devid:max" "$mnt" || rc=$?; }
            [[ -n $tmp ]] && temp_umount "$tmp"
            ;;
        ntfs)
            ensure_cmds ntfsresize || return 1
            run_input y ntfsresize -f -s "$fs_target" "$part" || { err "Shrinking the file system failed: the partition was not changed."; return 1; }
            set_part_end "$disk" "$nr" "$new_end" || return $?
            run_input y ntfsresize -f "$part" || rc=$?
            (( rc == 0 )) && info "Windows will run a disk check at its next boot: this is normal."
            ;;
        swap)
            uuid=$(fs_prop "$part" UUID)
            label=$(fs_prop "$part" LABEL)
            [[ -n $uuid ]] && args+=(-U "$uuid")
            [[ -n $label ]] && args+=(-L "$label")
            if swap_active "$part"; then
                was_active=1
                run swapoff "$part" || return 1
            fi
            set_part_end "$disk" "$nr" "$new_end" || rc=$?
            if (( rc == 0 )); then
                run mkswap "${args[@]}" "$part" || rc=$?
                (( was_active && rc == 0 )) && run swapon "$part"
            fi
            ;;
        "")
            set_part_end "$disk" "$nr" "$new_end" || rc=$?
            ;;
        *)
            err "Shrinking '$t' is not supported."
            return 1
            ;;
    esac
    return "$rc"
}

# Creates a partition from START to END (sectors) and formats it.
# Sets CREATED_PART to the new device.
op_create() {
    local disk=$1 start=$2 end=$3 fs=$4 label=$5 type nr="" i part
    CREATED_PART=""
    load_table "$disk" || return 1
    type=$(ptype_code "$T_LABEL" "$fs")
    backup_table "$disk"
    if (( PW_DRY_RUN )); then
        nr=$(first_free_nr) || nr=N
    fi
    run_input "start=$start, size=$(( end - start + 1 )), type=$type" \
        sfdisk "${SFDISK_OPTS[@]}" --append "$disk" || return 1
    reread_table "$disk"
    if (( ! PW_DRY_RUN )); then
        load_table "$disk"
        for i in "${!T_NR[@]}"; do
            [[ ${T_START[i]} == "$start" ]] && nr=${T_NR[i]}
        done
        [[ -n $nr ]] || { err "The new partition was not found in the table."; return 1; }
    fi
    part=$(part_dev "$disk" "$nr")
    if (( ! PW_DRY_RUN )) && ! wait_for_dev "$part"; then
        err "Device $part did not appear: reboot and format the partition manually."
        return 1
    fi
    ok "Partition $part created."
    CREATED_PART=$part
    [[ $fs == none ]] && return 0
    run wipefs -a "$part" >/dev/null
    make_fs "$part" "$fs" "$label" $(( (end - start + 1) * T_SS ))
}

make_fs() {   # device fs label [size_bytes]
    local dev=$1 fs=$2 label=$3 bytes=${4:-} args=()
    [[ -n $bytes ]] || bytes=$(dev_bytes "$dev")
    case $fs in
        ext4)
            ensure_cmds mkfs.ext4 || return 1
            [[ -n $label ]] && args+=(-L "$label")
            run mkfs.ext4 -q "${args[@]}" "$dev"
            ;;
        xfs)
            ensure_cmds mkfs.xfs || return 1
            [[ -n $label ]] && args+=(-L "$label")
            run mkfs.xfs -f "${args[@]}" "$dev"
            ;;
        btrfs)
            ensure_cmds mkfs.btrfs || return 1
            [[ -n $label ]] && args+=(-L "$label")
            run mkfs.btrfs -f "${args[@]}" "$dev"
            ;;
        vfat)
            ensure_cmds mkfs.vfat || return 1
            [[ -n $label ]] && args+=(-n "$label")
            # FAT32 needs enough clusters: smaller partitions get FAT16/FAT12
            (( bytes >= 64 * MIB )) && args+=(-F 32)
            run mkfs.vfat "${args[@]}" "$dev"
            ;;
        ntfs)
            ensure_cmds mkfs.ntfs || return 1
            [[ -n $label ]] && args+=(-L "$label")
            run mkfs.ntfs -Q "${args[@]}" "$dev"
            ;;
        swap)
            [[ -n $label ]] && args+=(-L "$label")
            run mkswap "${args[@]}" "$dev"
            ;;
        lvm)
            ensure_cmds pvcreate || return 1
            run pvcreate "$dev"
            ;;
        none) return 0 ;;
    esac
}

op_delete() {
    local disk=$1 nr=$2 wipe=$3 part
    part=$(part_dev "$disk" "$nr")
    if (( ! PW_DRY_RUN )) && [[ -b $part ]] && dev_in_use "$part"; then
        err "Partition $part is still in use (mounted, active swap or used by LVM/LUKS): not deleted."
        return 1
    fi
    backup_table "$disk"
    if (( wipe )) && [[ -b $part ]]; then
        run wipefs -a "$part" || warn "wipefs failed: continuing anyway."
    fi
    run sfdisk "${SFDISK_OPTS[@]}" --delete "$disk" "$nr" || return 1
    (( PW_DRY_RUN )) || partx -d --nr "$nr" "$disk" >/dev/null 2>&1
    reread_table "$disk"
    ok "Partition $part deleted."
}

# Lines of FILE (fstab or crypttab) that refer to device DEV.
# FIELD is the field holding the device (1 for fstab, 2 for crypttab).
config_refs() {
    local dev=$1 file=$2 field=$3 keys=() v link
    [[ -r $file ]] || return 0
    keys+=("$dev" "$(readlink -f "$dev")")
    v=$(fs_prop "$dev" UUID) && [[ -n $v ]] && keys+=("UUID=$v" "/dev/disk/by-uuid/$v")
    v=$(fs_prop "$dev" LABEL) && [[ -n $v ]] && keys+=("LABEL=$v" "/dev/disk/by-label/$v")
    v=$(fs_prop "$dev" PART_ENTRY_UUID) && [[ -n $v ]] && keys+=("PARTUUID=$v" "/dev/disk/by-partuuid/$v")
    v=$(fs_prop "$dev" PART_ENTRY_NAME) && [[ -n $v ]] && keys+=("PARTLABEL=$v")
    for link in /dev/disk/by-id/* /dev/disk/by-path/*; do
        [[ -e $link && $(readlink -f "$link") == "$(readlink -f "$dev")" ]] && keys+=("$link")
    done
    awk -v keys="$(printf '%s\n' "${keys[@]}")" -v f="$field" '
        BEGIN { n = split(keys, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") k[a[i]] = 1 }
        /^[[:space:]]*#/ { next }
        { d = $f; gsub(/"/, "", d); if (d in k) print NR }' "$file"
}

comment_config_lines() {   # file line_numbers...
    local file=$1 n bak
    shift
    bak="$file.partition-wizard-$(date +%Y%m%d-%H%M%S).bak"
    run cp -a "$file" "$bak" || return 1
    for n in "$@"; do
        run sed -i "${n}s/^/# removed by partition-wizard: /" "$file" || return 1
    done
    ok "Lines commented out in $file (backup copy: $bak)."
}

systemd_reload() {
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        run systemctl daemon-reload
    fi
    return 0
}

# Absolute path, not "/", without characters that would need escaping in fstab
valid_mount_point() {
    [[ $1 =~ ^/[A-Za-z0-9._@:+/-]+$ && $1 != *//* && $1 != */../* && $1 != */.. ]]
}

# Adds the new partition to /etc/fstab and mounts it
setup_mount() {
    local dev=$1 t=$2 mnt uuid pass=2 line bak
    while :; do
        mnt=$(ui_input "Automatic mount" "Mount the new partition $dev automatically at boot?\n\nEnter the mount point (e.g. /mnt/data or /srv/backup)\nor leave it empty to skip mounting." "") || return 0
        mnt=$(trim "$mnt")
        [[ -z $mnt ]] && return 0
        if ! valid_mount_point "$mnt"; then
            ui_msg "Automatic mount" "Invalid path: it must be absolute, not \"/\", and use only letters, digits and . _ - + @ :"
            continue
        fi
        if findmnt -n "$mnt" >/dev/null 2>&1; then
            ui_msg "Automatic mount" "Another file system is already mounted on $mnt: choose a different path."
            continue
        fi
        if [[ -d $mnt && -n $(ls -A "$mnt" 2>/dev/null) ]]; then
            ui_yesno "Automatic mount" "Directory $mnt is not empty: its contents would be hidden by the new partition.\n\nUse it anyway?" no || continue
        fi
        break
    done
    uuid=$(fs_prop "$dev" UUID)
    [[ -n $uuid ]] || uuid="<UUID-of-$dev>"
    case $t in xfs | btrfs | vfat) pass=0 ;; esac
    line="UUID=$uuid  $mnt  $t  defaults,nofail  0  $pass"
    bak="/etc/fstab.partition-wizard-$(date +%Y%m%d-%H%M%S).bak"
    run cp -a /etc/fstab "$bak" || return 1
    run mkdir -p "$mnt" || return 1
    run_input "$line" tee -a /etc/fstab >/dev/null || return 1
    systemd_reload
    if run mount "$mnt"; then
        ok "Partition mounted on $mnt and added to /etc/fstab."
    else
        err "Mounting failed: restoring /etc/fstab from the backup copy."
        run cp -a "$bak" /etc/fstab
        systemd_reload
    fi
}

setup_swap() {
    local dev=$1 uuid bak
    ui_yesno "Swap" "Activate the new swap $dev now and add it to /etc/fstab for the next boots?" || return 0
    uuid=$(fs_prop "$dev" UUID)
    [[ -n $uuid ]] || uuid="<UUID-of-$dev>"
    bak="/etc/fstab.partition-wizard-$(date +%Y%m%d-%H%M%S).bak"
    run cp -a /etc/fstab "$bak" || return 1
    run_input "UUID=$uuid  none  swap  sw  0  0" tee -a /etc/fstab >/dev/null || return 1
    systemd_reload
    run swapon "$dev" && ok "Swap activated."
}

# Computes the new end sector from the user's answer.
# compute_end ANSWER START CURRENT_END LIMIT MODE [MIN_BYTES]
#   MODE: grow | shrink | create
# Sets NEW_END, or sets SIZE_ERR and returns 1.
compute_end() {
    local spec start=$2 cur_end=$3 limit=$4 mode=$5 min=${6:-0} cur align bytes secs
    spec=$(trim "${1,,}")
    spec=${spec// /}
    align=$(( MIB / T_SS ))
    cur=$(( (cur_end - start + 1) * T_SS ))
    [[ $mode == create ]] && cur=0
    NEW_END="" SIZE_ERR=""
    if [[ $spec == max || $spec == all || $spec == 100% ]]; then
        if [[ $mode == shrink ]]; then
            SIZE_ERR="To shrink, enter a size (e.g. 20G or -5G)."
            return 1
        fi
        NEW_END=$limit
        return 0
    fi
    case $spec in
        +*) bytes=$(parse_size "${spec#+}") && bytes=$(( cur + bytes )) ;;
        -*) bytes=$(parse_size "${spec#-}") && bytes=$(( cur - bytes )) ;;
        *) bytes=$(parse_size "$spec") ;;
    esac || { SIZE_ERR="Invalid size: \"$1\". Examples: 500M, 20G, 1.5T."; return 1; }
    secs=$(( bytes / T_SS / align * align ))
    if (( secs <= 0 )); then
        SIZE_ERR="The size must be at least 1 MiB."
        return 1
    fi
    NEW_END=$(( start + secs - 1 ))
    case $mode in
        grow)
            if (( NEW_END <= cur_end )); then
                SIZE_ERR="The new size must be larger than the current one ($(human "$cur"))."
                return 1
            fi
            ;;
        shrink)
            if (( NEW_END >= cur_end )); then
                SIZE_ERR="The new size must be smaller than the current one ($(human "$cur"))."
                return 1
            fi
            if (( secs * T_SS < min )); then
                SIZE_ERR="Size too small: the recommended minimum is $(human "$min")."
                return 1
            fi
            ;;
    esac
    if (( NEW_END > limit )); then
        SIZE_ERR="Not enough space: the maximum size is $(human $(( (limit - start + 1) * T_SS )))."
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# LVM
# -----------------------------------------------------------------------------

vg_field() { trim "$(vgs --noheadings --units b --nosuffix -o "$2" "$1" 2>/dev/null)"; }

# Extends a logical volume (optionally only those of volume group VG)
lvm_extend() {
    local title="Extend logical volume" only_vg=${1:-} path size vg attr items=() lv
    local vgfree ext lvsize ans bytes n args=()
    ensure_cmds lvs vgs lvextend || return 0
    while IFS='|' read -r path size vg attr; do
        path=$(trim "$path") size=$(trim "$size") vg=$(trim "$vg") attr=$(trim "$attr")
        [[ -n $path ]] || continue
        [[ ${attr:0:1} == "-" || ${attr:0:1} == "o" ]] || continue
        [[ -z $only_vg || $vg == "$only_vg" ]] || continue
        items+=("$path" "$(human "$size")  (group $vg, $(human "$(vg_field "$vg" vg_free)") free)")
    done < <(lvs --noheadings --units b --nosuffix --separator '|' -o lv_path,lv_size,vg_name,lv_attr 2>/dev/null)
    if (( ${#items[@]} == 0 )); then
        ui_msg "$title" "No logical volumes found${only_vg:+ in group $only_vg}."
        return 0
    fi
    lv=$(ui_menu "$title" "Select the logical volume to extend:" "${items[@]}") || return 0
    vg=$(trim "$(lvs --noheadings -o vg_name "$lv" 2>/dev/null)")
    lvsize=$(trim "$(lvs --noheadings --units b --nosuffix -o lv_size "$lv" 2>/dev/null)")
    vgfree=$(vg_field "$vg" vg_free)
    ext=$(vg_field "$vg" vg_extent_size)
    if ! [[ $vgfree =~ ^[0-9]+$ && $ext =~ ^[0-9]+$ ]] || (( vgfree < ext )); then
        ui_msg "$title" "Volume group \"$vg\" has no free space.\n\nTo add space you can:\n * grow the partition holding the physical volume (\"Grow a partition\" menu);\n * add a partition or a disk to the group (LVM menu -> \"Add a partition\")."
        return 0
    fi
    while :; do
        ans=$(ui_input "$title" "Logical volume: $lv\nCurrent size: $(human "$lvsize")\nFree space in group $vg: $(human "$vgfree")\n\nHow much space do you want to add?\n  max  -> all the free space\n  10G  -> add 10 GiB\n(accepted units: M, G, T)" "max") || return 0
        ans=$(trim "${ans,,}")
        ans=${ans#+}
        if [[ $ans == max || $ans == all || $ans == 100% ]]; then
            args=(-l +100%FREE)
            bytes=$(( vgfree / ext * ext ))
            break
        fi
        if bytes=$(parse_size "$ans"); then
            n=$(( bytes / ext ))
            if (( n > 0 && n * ext <= vgfree )); then
                args=(-l "+$n")
                bytes=$(( n * ext ))
                break
            fi
        fi
        ui_msg "$title" "Invalid value: enter an amount between $(human "$ext") and $(human "$vgfree"), or max."
    done
    ui_yesno "$title" "Summary:\n\n  Logical volume: $lv\n  Size:           $(human "$lvsize") -> $(human $(( lvsize + bytes )))\n  Contents:       $(fs_type "$lv")\n\nThe file system will be grown too. Continue?" || return 0
    screen_start "$title"
    critical_begin
    if run lvextend "${args[@]}" "$lv"; then
        ok "Logical volume $lv extended."
        grow_contents "$lv"
    else
        err "lvextend failed."
    fi
    critical_end
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$lv" >&2 2>/dev/null
}

lvm_add_pv() {
    local title="Add space to a volume group" vgs_list=() items=() v disk part t pvvg vg
    ensure_cmds pvcreate vgextend vgs pvs || return 0
    mapfile -t vgs_list < <(vgs --noheadings -o vg_name 2>/dev/null | awk 'NF { print $1 }')
    if (( ${#vgs_list[@]} == 0 )); then
        ui_msg "$title" "No LVM volume groups found on this system."
        return 0
    fi
    disk=$(select_disk "$title" "Select the disk holding the partition to add:") || return 0
    part=$(select_partition "$disk" "$title" "Select the partition to add to the volume group.\nWARNING: its current contents will be erased.") || return 0
    if dev_in_use "$part"; then
        ui_msg "$title" "Partition $part is in use (mounted, active swap or used by LVM/LUKS): it cannot be added."
        return 0
    fi
    t=$(fs_type "$part")
    if [[ $t == LVM2_member ]]; then
        pvvg=$(trim "$(pvs --noheadings -o vg_name "$part" 2>/dev/null)")
        if [[ -n $pvvg ]]; then
            ui_msg "$title" "Partition $part already belongs to volume group \"$pvvg\"."
            return 0
        fi
    fi
    for v in "${vgs_list[@]}"; do
        items+=("$v" "$(human "$(vg_field "$v" vg_free)") free of $(human "$(vg_field "$v" vg_size)")")
    done
    vg=$(ui_menu "$title" "Which volume group should $part be added to?" "${items[@]}") || return 0
    if [[ -n $t && $t != LVM2_member ]]; then
        ui_confirm_typed "$title" "Partition $part contains: $t.\nALL THE DATA ON IT WILL BE ERASED." "$(basename "$part")" || return 0
    else
        ui_yesno "$title" "Add $part ($(human "$(dev_bytes "$part")")) to volume group \"$vg\"?" || return 0
    fi
    screen_start "$title"
    critical_begin
    if [[ $t != LVM2_member ]]; then
        if ! { run wipefs -a "$part" && run pvcreate "$part"; }; then
            critical_end
            err "Creating the physical volume failed."
            pause
            return 0
        fi
    fi
    if run vgextend "$vg" "$part"; then
        ok "$part added to volume group $vg."
        critical_end
        pause_if_tui
        if ui_yesno "$title" "Assign the new space to a logical volume now?"; then
            lvm_extend "$vg"
        fi
    else
        critical_end
        err "vgextend failed."
    fi
    pause
}

wizard_lvm() {
    local choice
    if ! command -v lvm >/dev/null 2>&1; then
        ensure_cmds lvm || return 0
    fi
    while :; do
        choice=$(ui_menu "LVM" "Logical volume management (LVM):" \
            1 "Extend a logical volume (and its file system)" \
            2 "Add a partition to a volume group" \
            3 "Show LVM summary") || return 0
        case $choice in
            1) lvm_extend; pause ;;
            2) lvm_add_pv ;;
            3)
                screen_start "LVM summary"
                printf '\nPhysical volumes:\n' >&2;  pvs >&2 2>/dev/null
                printf '\nVolume groups:\n' >&2; vgs >&2 2>/dev/null
                printf '\nLogical volumes:\n' >&2; lvs >&2 2>/dev/null
                pause
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Wizards
# -----------------------------------------------------------------------------

show_overview() {
    local d s e args=(-o "NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT") regions=() r gap
    (( PW_INCLUDE_LOOP )) || args+=(-e 7)
    [[ $PW_UI == whiptail && -t 1 ]] && clear_screen
    ui_header "Disks and partitions"
    lsblk "${args[@]}" >&2
    ui_header "Unallocated space"
    for d in $(list_disks); do
        if ! load_table "$d"; then
            printf '%s (%s): %s%s\n' "$d" "$(human "$(dev_bytes "$d")")" "$T_ERR" \
                "$(t=$(dev_signatures "$d"); [[ -n $t ]] && printf ' Signatures found: %s.' "$t")" >&2
            continue
        fi
        printf '%s (%s, %s):\n' "$d" "$(human "$(dev_bytes "$d")")" "${T_LABEL^^}" >&2
        mapfile -t regions < <(free_regions)
        if (( ${#regions[@]} == 0 )); then
            printf '    no free space\n' >&2
        fi
        for r in "${regions[@]}"; do
            read -r s e <<<"$r"
            printf '    free: %-12s (sectors %s - %s)\n' "$(human $(( (e - s + 1) * T_SS )))" "$s" "$e" >&2
        done
        gap=$(gpt_tail_gap)
        if (( gap >= MIB )); then
            printf '    %s%s at the end of the disk cannot be used yet: use "Detect new space".%s\n' \
                "$C_YELLOW" "$(human "$gap")" "$C_RESET" >&2
        fi
    done
    if command -v vgs >/dev/null 2>&1 && [[ -n $(vgs --noheadings 2>/dev/null) ]]; then
        ui_header "LVM volume groups"
        vgs >&2 2>/dev/null
        printf '\n' >&2
        lvs >&2 2>/dev/null
    fi
    [[ $PW_MODE == list ]] || pause
}

wizard_expand() {
    local title="Grow partition" disk part nr i start cur_end max_end free t mnt ans cur new_size j next="" rc
    disk=$(select_disk "$title" "Select the disk holding the partition to grow:") || return 0
    screen_start "$title"
    prepare_disk_growth "$disk"
    (( PW_DISK_CHANGED )) && pause_if_tui

    load_table "$disk"
    rc=$?
    if (( rc == 2 )); then
        ui_msg "$title" "$T_ERR"
        return 0
    fi
    if (( rc != 0 )); then
        t=$(fs_type "$disk")
        if [[ -n $t ]]; then
            if ui_yesno "$title" "Disk $disk has no partitions but directly contains: $t.\n\nGrow its contents to fill the whole disk ($(human "$(dev_bytes "$disk")"))?"; then
                screen_start "$title"
                critical_begin
                grow_contents "$disk"
                critical_end
                show_disk "$disk"
                pause
            fi
        elif [[ -n $(dev_signatures "$disk") ]]; then
            ui_msg "$title" "Disk $disk has no supported partition table or file system (signatures found: $(dev_signatures "$disk"))."
        else
            ui_msg "$title" "Disk $disk contains neither a partition table nor a file system.\nUse \"Create a new partition\"."
        fi
        return 0
    fi

    part=$(select_partition "$disk" "$title" "Select the partition to grow:") || return 0
    nr=$(part_nr "$part")
    i=$(tbl_idx "$nr") || return 0
    start=${T_START[i]}
    cur_end=$(( start + T_SIZE[i] - 1 ))
    cur=$(( T_SIZE[i] * T_SS ))
    max_end=$(part_max_end "$nr")
    free=$(( (max_end - cur_end) * T_SS ))
    (( free < 0 )) && free=0
    t=$(fs_type "$part")
    mnt=$(mountpoint_of "$part")

    if (( free < MIB )); then
        for j in "${!T_NR[@]}"; do
            if (( T_START[j] > cur_end )) && { [[ -z $next ]] || (( T_START[j] < T_START[next] )); }; then
                next=$j
            fi
        done
        local why="There is no unallocated space right after $part, so it cannot be grown."
        if [[ -n $next ]]; then
            if is_extended_idx "$next"; then
                why+="\n\nIt is followed by extended partition ${T_NR[next]} (with the logical partitions, often the swap). To grow $part you would first have to delete the partitions that follow it."
            else
                why+="\n\nIt is followed by $(part_dev "$disk" "${T_NR[next]}") ($(fs_type "$(part_dev "$disk" "${T_NR[next]}")")). To grow $part you would first have to delete it (if it is not needed) or move it with a tool such as GParted from a live USB."
            fi
        fi
        if [[ -n $t ]]; then
            if ui_yesno "$title" "$why\n\nIf the partition was already enlarged earlier, its contents ($t) can still be grown to fill the whole partition.\n\nDo it now?" no; then
                screen_start "$title"
                critical_begin
                grow_contents "$part"
                critical_end
                show_disk "$disk"
                pause
            fi
        else
            ui_msg "$title" "$why"
        fi
        return 0
    fi

    while :; do
        ans=$(ui_input "$title" "Partition: $part (${t:-no file system})\nCurrent size: $(human "$cur")\nFree space right after it: $(human "$free")\nMaximum size: $(human $(( (max_end - start + 1) * T_SS )))\n\nEnter the new size:\n  max   -> use all the free space\n  50G   -> total size of 50 GiB\n  +10G  -> add 10 GiB\n(accepted units: M, G, T)" "max") || return 0
        compute_end "$ans" "$start" "$cur_end" "$max_end" grow && break
        ui_msg "$title" "$SIZE_ERR"
    done
    new_size=$(( (NEW_END - start + 1) * T_SS ))

    ui_yesno "$title" "Summary:\n\n  Disk:       $disk\n  Partition:  $part\n  Contents:   ${t:-none}${mnt:+ (mounted on $mnt)}\n  Size:       $(human "$cur") -> $(human "$new_size")\n\nThe partition and its contents (LUKS, LVM, file system) will be grown. This also works while the partition is in use.\nA backup of the partition table is saved before the change.\n\nContinue?" || return 0

    screen_start "$title"
    critical_begin
    if set_part_end "$disk" "$nr" "$NEW_END"; then
        grow_contents "$part"
    fi
    critical_end
    show_disk "$disk"
    pause
}

wizard_shrink() {
    local title="Shrink partition" disk part nr i start cur_end cur t mnt min suggested ans new_size
    local unmounted="" tmp="" devid=1 was_swap=0
    disk=$(select_disk "$title" "Select the disk holding the partition to shrink:") || return 0
    part=$(select_partition "$disk" "$title" "Select the partition to shrink:") || return 0
    nr=$(part_nr "$part")
    i=$(tbl_idx "$nr") || return 0
    start=${T_START[i]}
    cur_end=$(( start + T_SIZE[i] - 1 ))
    cur=$(( T_SIZE[i] * T_SS ))
    t=$(fs_type "$part")

    case $t in
        ext2 | ext3 | ext4 | btrfs | ntfs | swap) ;;
        "")
            ui_yesno "$title" "Partition $part does not contain a recognised file system.\nShrinking it permanently destroys any data stored in its last part.\n\nContinue?" no || return 0
            ;;
        xfs)
            ui_msg "$title" "XFS file systems cannot be shrunk.\n\nThe only alternative is to copy the data elsewhere, recreate a smaller partition and restore the data."
            return 0
            ;;
        LVM2_member)
            ui_msg "$title" "$part is an LVM physical volume: automatic shrinking is not supported.\n\nShrink the logical volumes first (lvreduce -r), then the physical volume (pvresize --setphysicalvolumesize) and only then the partition."
            return 0
            ;;
        crypto_LUKS)
            ui_msg "$title" "$part is a LUKS encrypted volume: automatic shrinking is not supported."
            return 0
            ;;
        *)
            ui_msg "$title" "Shrinking file system \"$t\" is not supported."
            return 0
            ;;
    esac

    if [[ -n $(dev_holders "$part") ]]; then
        ui_msg "$title" "Partition $part is used by $(dev_child "$part"): it cannot be shrunk."
        return 0
    fi

    # ext2/3/4 and NTFS can only be shrunk while unmounted; btrfs also mounted.
    mnt=$(mountpoint_of "$part")
    if [[ -n $mnt && $t != btrfs && $t != swap ]]; then
        if (( $(mountpoints_of "$part" | wc -l) > 1 )); then
            ui_msg "$title" "Partition $part is mounted in several places:\n$(mountpoints_of "$part")\n\nUnmount it everywhere and try again."
            return 0
        fi
        if [[ $mnt == / || $mnt == /usr || $mnt == /var || $mnt == /boot ]]; then
            ui_msg "$title" "Partition $part is mounted on $mnt and is needed by the running system: it cannot be unmounted.\n\nTo shrink it, boot the computer from a live USB (e.g. Ubuntu or Fedora live) and run this script from there."
            return 0
        fi
        ui_yesno "$title" "Partition $part is mounted on $mnt.\nA $t file system must be unmounted to be shrunk.\n\nUnmount it now? (It will be mounted again at the end.)" || return 0
        screen_start "$title"
        if ! run umount "$mnt"; then
            pause_if_tui
            ui_msg "$title" "Could not unmount $mnt: close the programs using it and try again."
            return 0
        fi
        unmounted=$mnt
    fi
    if [[ $t == swap ]] && swap_active "$part"; then
        was_swap=1
    fi

    screen_start "$title"
    info "Computing the minimum space required..."
    case $t in
        ext2 | ext3 | ext4)
            ensure_cmds resize2fs e2fsck dumpe2fs || { _shrink_restore_mount "$part" "$unmounted"; return 0; }
            e2fsck_ok "$part" || { pause; _shrink_restore_mount "$part" "$unmounted"; return 0; }
            PW_FSCK_DONE=$part
            ;;
        btrfs)
            ensure_cmds btrfs || return 0
            mnt=$(mountpoint_of "$part")
            if [[ -z $mnt ]]; then
                temp_mount "$part" || { pause; return 0; }
                mnt=$PW_LAST_MNT tmp=$PW_LAST_MNT
            fi
            devid=$(btrfs_devid "$part" "$mnt")
            ;;
        ntfs)
            ensure_cmds ntfsresize || { _shrink_restore_mount "$part" "$unmounted"; return 0; }
            ;;
    esac
    if ! min=$(fs_min_bytes "$part" "$t" "$mnt" "$devid"); then
        pause_if_tui
        if [[ $t == ntfs ]]; then
            ui_msg "$title" "Could not determine the minimum size of the NTFS file system on $part.\n\nMake sure Windows was shut down completely (disable Fast Startup and hibernation) and, if needed, run \"chkdsk /f\" from Windows."
        else
            ui_msg "$title" "Could not determine the minimum size required by the file system on $part."
        fi
        [[ -n $tmp ]] && temp_umount "$tmp"
        _shrink_restore_mount "$part" "$unmounted"
        return 0
    fi
    # margin: +10% over the minimum and 32 MiB for the two-step shrink
    suggested=$(( min + min / 10 + 32 * MIB ))
    suggested=$(( (suggested + MIB - 1) / MIB * MIB ))
    pause_if_tui

    if (( suggested >= cur - MIB )); then
        ui_msg "$title" "Partition $part ($(human "$cur")) is almost full: the file system needs at least $(human "$suggested").\nIt cannot be shrunk."
        [[ -n $tmp ]] && temp_umount "$tmp"
        _shrink_restore_mount "$part" "$unmounted"
        return 0
    fi

    while :; do
        ans=$(ui_input "$title" "Partition: $part (${t:-no file system})\nCurrent size: $(human "$cur")\nRecommended minimum size: $(human "$suggested")\n\nEnter the new size:\n  20G   -> total size of 20 GiB\n  -10G  -> shrink by 10 GiB\n(accepted units: M, G, T)" "") || {
            [[ -n $tmp ]] && temp_umount "$tmp"
            _shrink_restore_mount "$part" "$unmounted"
            return 0
        }
        compute_end "$ans" "$start" "$cur_end" "$cur_end" shrink "$suggested" && break
        ui_msg "$title" "$SIZE_ERR"
    done
    new_size=$(( (NEW_END - start + 1) * T_SS ))

    if ! ui_yesno "$title" "Summary:\n\n  Disk:       $disk\n  Partition:  $part (${t:-no file system})\n  Size:       $(human "$cur") -> $(human "$new_size")\n  Space freed: $(human $(( cur - new_size )))\n\nWARNING: shrinking moves data inside the file system. An interruption (e.g. a power failure) can cause data loss. Make sure you have a backup.\n\nContinue?" no; then
        [[ -n $tmp ]] && temp_umount "$tmp"
        _shrink_restore_mount "$part" "$unmounted"
        return 0
    fi

    screen_start "$title"
    critical_begin
    if op_shrink "$disk" "$nr" "$NEW_END"; then
        ok "Shrink completed: $(human $(( cur - new_size ))) are now unallocated and can be used with \"Create a new partition\"."
    else
        err "The shrink was not completed. Check the messages above."
    fi
    critical_end
    [[ -n $tmp ]] && temp_umount "$tmp"
    (( was_swap )) && ! swap_active "$part" && (( ! PW_DRY_RUN )) && run swapon "$part"
    _shrink_restore_mount "$part" "$unmounted"
    show_disk "$disk"
    pause
}

_shrink_restore_mount() {
    local part=$1 mnt=$2
    [[ -n $mnt ]] || return 0
    if findmnt --fstab -n "$mnt" >/dev/null 2>&1; then
        run mount "$mnt"
    else
        run mount "$part" "$mnt"
    fi || warn "Could not mount $part on $mnt again."
}

wizard_create() {
    local title="Create partition" disk sigs label_type regions=() items=() r s e k n primaries=0
    local ans fs fslabel maxlen part fsitems vgs_list=() v vg rc
    disk=$(select_disk "$title" "Select the disk to create the partition on:") || return 0

    load_table "$disk"
    rc=$?
    if (( rc == 2 )); then
        ui_msg "$title" "$T_ERR"
        return 0
    fi
    if (( rc != 0 )); then
        if disk_in_use "$disk"; then
            ui_msg "$title" "Disk $disk has no partition table but is in use (mounted, swap or LVM): cannot continue."
            return 0
        fi
        sigs=$(dev_signatures "$disk")
        label_type=$(UI_NOTAGS=1 ui_menu "$title" "Disk $disk has no partition table.\nChoose the type of table to create:" \
            gpt "GPT (recommended: modern disks, UEFI, larger than 2 TiB)" \
            dos "MBR/DOS (compatible with old BIOSes, max 2 TiB)") || return 0
        if [[ -n $sigs ]]; then
            ui_confirm_typed "$title" "Disk $disk contains: $sigs.\nCreating a new partition table WILL DESTROY ALL THE DATA ON THE DISK." "$(basename "$disk")" || return 0
        else
            ui_yesno "$title" "Create an empty $label_type partition table on $disk ($(human "$(dev_bytes "$disk")"))?" || return 0
        fi
        screen_start "$title"
        run_input "label: $label_type" sfdisk --wipe always "$disk" || { pause; return 0; }
        reread_table "$disk"
        pause_if_tui
        if (( PW_DRY_RUN )); then
            ui_msg "$title" "Dry run: the table was not really created, so the partition cannot be created either."
            return 0
        fi
        load_table "$disk" || { ui_msg "$title" "Creating the partition table failed."; return 0; }
    else
        screen_start "$title"
        prepare_disk_growth "$disk"
        (( PW_DISK_CHANGED )) && pause_if_tui
    fi

    if [[ $T_LABEL == dos ]]; then
        for k in "${T_NR[@]}"; do (( k <= 4 )) && primaries=$(( primaries + 1 )); done
        if (( primaries >= 4 )); then
            ui_msg "$title" "Disk $disk uses an MBR table and already has 4 primary (or extended) partitions: no more can be created.\n\nTip: delete a partition you do not need or, if the disk is empty, recreate it with a GPT table."
            return 0
        fi
    fi

    mapfile -t regions < <(free_regions)
    if (( ${#regions[@]} == 0 )); then
        ui_msg "$title" "There is no unallocated space on $disk.\n\nYou can free some by shrinking or deleting a partition."
        return 0
    fi
    n=1
    for r in "${regions[@]}"; do
        read -r s e <<<"$r"
        items+=("$n" "$(human $(( (e - s + 1) * T_SS )))  free (sectors $s - $e)")
        n=$(( n + 1 ))
    done
    if (( ${#regions[@]} == 1 )); then
        k=1
    else
        k=$(ui_menu "$title" "Select the free space to use:" "${items[@]}") || return 0
    fi
    read -r s e <<<"${regions[k - 1]}"

    while :; do
        ans=$(ui_input "$title" "Selected free space: $(human $(( (e - s + 1) * T_SS )))\n\nSize of the new partition:\n  max  -> all the free space\n  20G  -> 20 GiB\n(accepted units: M, G, T)" "max") || return 0
        compute_end "$ans" "$s" "$s" "$e" create && break
        ui_msg "$title" "$SIZE_ERR"
    done

    fsitems=(ext4 "ext4    - Linux file system (recommended)"
        xfs "xfs     - Linux file system for large volumes (cannot be shrunk)"
        btrfs "btrfs   - Linux file system with snapshots"
        vfat "FAT32   - works with Windows/macOS, USB sticks, EFI (FAT16 below 64 MiB)"
        ntfs "NTFS    - Windows file system"
        swap "swap    - swap space"
        lvm "LVM     - LVM physical volume"
        none "none    - only create the partition")
    fs=$(UI_NOTAGS=1 ui_menu "$title" "How do you want to format the new partition?" "${fsitems[@]}") || return 0

    fslabel=""
    case $fs in
        ext4 | swap) maxlen=16 ;;
        xfs) maxlen=12 ;;
        vfat) maxlen=11 ;;
        btrfs | ntfs) maxlen=32 ;;
        *) maxlen=0 ;;
    esac
    if (( maxlen > 0 )); then
        while :; do
            fslabel=$(ui_input "$title" "File system label (name), at most $maxlen characters.\nLeave it empty for no label." "") || return 0
            fslabel=$(trim "$fslabel")
            [[ $fs == vfat ]] && fslabel=${fslabel^^}
            if (( ${#fslabel} > maxlen )); then
                ui_msg "$title" "Label too long (at most $maxlen characters)."
                continue
            fi
            if [[ $fslabel == *[\"\'\\]* ]]; then
                ui_msg "$title" "The label cannot contain quotes or backslashes."
                continue
            fi
            break
        done
    fi

    ui_yesno "$title" "Summary:\n\n  Disk:         $disk (${T_LABEL^^})\n  Size:         $(human $(( (NEW_END - s + 1) * T_SS )))\n  Sectors:      $s - $NEW_END\n  File system:  $fs\n  Label:        ${fslabel:-(none)}\n\nExisting partitions will not be changed.\n\nContinue?" || return 0

    screen_start "$title"
    critical_begin
    if ! op_create "$disk" "$s" "$NEW_END" "$fs" "$fslabel"; then
        critical_end
        err "Creating the partition failed."
        pause
        return 0
    fi
    critical_end
    part=$CREATED_PART
    show_disk "$disk"
    pause_if_tui

    case $fs in
        ext4 | xfs | btrfs | vfat) setup_mount "$part" "$fs" ;;
        swap) setup_swap "$part" ;;
        lvm)
            if command -v vgs >/dev/null 2>&1; then
                mapfile -t vgs_list < <(vgs --noheadings -o vg_name 2>/dev/null | awk 'NF { print $1 }')
                if (( ${#vgs_list[@]} )); then
                    items=()
                    for v in "${vgs_list[@]}"; do items+=("$v" "$(human "$(vg_field "$v" vg_free)") free"); done
                    if vg=$(ui_menu "$title" "Add the new physical volume $part to an existing volume group?\n(Back = no)" "${items[@]}"); then
                        screen_start "$title"
                        if run vgextend "$vg" "$part"; then
                            ok "$part added to volume group $vg."
                            pause_if_tui
                            ui_yesno "$title" "Assign the new space to a logical volume now?" && lvm_extend "$vg"
                        fi
                    fi
                fi
            fi
            ;;
    esac
    pause
}

wizard_delete() {
    local title="Delete partition" disk part nr i t="" mnt="" is_ext=0 k swap_on=0
    local fstab_lines=() crypt_lines=() warnmsg="" wipe=1
    disk=$(select_disk "$title" "Select the disk holding the partition to delete:") || return 0
    part=$(select_partition "$disk" "$title" "Select the partition to DELETE:" 1) || return 0
    nr=$(part_nr "$part")
    i=$(tbl_idx "$nr") || return 0
    is_extended_idx "$i" && is_ext=1

    if (( is_ext )); then
        for k in "${T_NR[@]}"; do
            if (( k >= 5 )); then
                ui_msg "$title" "Extended partition $part still holds logical partitions: delete them first."
                return 0
            fi
        done
        t="extended partition (empty)"
        wipe=0
    else
        t=$(fs_type "$part")
        mnt=$(mountpoints_of "$part" | paste -sd' ' -)
        for k in $mnt; do
            case $k in
                / | /boot | /boot/efi | /efi | /usr | /var | /home)
                    ui_msg "$title" "Partition $part is mounted on $k and is used by the system: it cannot be deleted."
                    return 0
                    ;;
            esac
        done
        if [[ -n $(dev_holders "$part") ]]; then
            if [[ $t == LVM2_member ]]; then
                ui_msg "$title" "Partition $part is an LVM physical volume in use ($(dev_child "$part")).\nRemove it from its volume group first (pvmove + vgreduce)."
            else
                ui_msg "$title" "Partition $part is used by $(dev_child "$part") (e.g. an open encrypted volume or RAID): close it before deleting the partition."
            fi
            return 0
        fi
        swap_active "$part" && swap_on=1
        [[ -n $mnt ]] && warnmsg+="\n * It is mounted on $mnt: it will be unmounted."
        (( swap_on )) && warnmsg+="\n * It is an active swap: it will be turned off."
        mapfile -t fstab_lines < <(config_refs "$part" /etc/fstab 1)
        [[ $t == crypto_LUKS ]] && mapfile -t crypt_lines < <(config_refs "$part" /etc/crypttab 2)
        (( ${#fstab_lines[@]} )) && warnmsg+="\n * It is listed in /etc/fstab: those lines will be commented out to avoid boot problems."
        (( ${#crypt_lines[@]} )) && warnmsg+="\n * It is listed in /etc/crypttab: those lines will be commented out."
        [[ $t == swap ]] && warnmsg+="\n * If it was used for hibernation, also remove the \"resume\" reference (e.g. /etc/initramfs-tools/conf.d/resume or the kernel parameters)."
    fi
    if [[ $T_LABEL == dos ]] && (( nr >= 5 )); then
        for k in "${T_NR[@]}"; do
            if (( k > nr )); then
                warnmsg+="\n * The following logical partitions will be renumbered (e.g. $(part_dev "$disk" "$k") -> $(part_dev "$disk" $(( k - 1 ))))."
                break
            fi
        done
    fi

    ui_confirm_typed "$title" "You are about to DELETE partition $part ($(human $(( T_SIZE[i] * T_SS ))), contents: ${t:-unknown}).\nALL THE DATA ON IT WILL BE LOST.$warnmsg" "$(basename "$part")" || return 0

    screen_start "$title"
    if [[ -n $mnt ]] && ! unmount_all "$part"; then
        err "Could not unmount $part from $mnt: close the programs using it and try again."
        pause
        return 0
    fi
    if (( swap_on )) && ! run swapoff "$part"; then
        err "Could not turn off swap $part."
        pause
        return 0
    fi
    critical_begin
    if op_delete "$disk" "$nr" "$wipe"; then
        (( ${#fstab_lines[@]} )) && comment_config_lines /etc/fstab "${fstab_lines[@]}" && systemd_reload
        (( ${#crypt_lines[@]} )) && comment_config_lines /etc/crypttab "${crypt_lines[@]}"
    else
        err "Deleting the partition failed."
    fi
    critical_end
    show_disk "$disk"
    pause
}

wizard_rescan() {
    local title="Detect new space" disk regions=() r s e
    disk=$(select_disk "$title" "Select the disk you enlarged (for example from the virtual machine settings):") || return 0
    screen_start "$title"
    prepare_disk_growth "$disk"
    printf '\n' >&2
    if load_table "$disk"; then
        mapfile -t regions < <(free_regions)
        if (( ${#regions[@]} == 0 )); then
            info "No unallocated space on $disk ($(human "$(dev_bytes "$disk")"))."
        fi
        for r in "${regions[@]}"; do
            read -r s e <<<"$r"
            info "Unallocated space on $disk: $(human $(( (e - s + 1) * T_SS ))) (sectors $s - $e)"
        done
        info "You can now use \"Grow a partition\" or \"Create a new partition\"."
    else
        info "$disk ($(human "$(dev_bytes "$disk")")): $T_ERR"
    fi
    show_disk "$disk"
    pause
}

# Prints a warning when backup FILE was not taken from disk DEV (different
# disk identifier), nothing otherwise.
backup_id_warning() {
    local f=$1 dev=$2 bid cid
    bid=$(awk -F': *' '/^label-id:/ { print tolower($2); exit }' "$f")
    cid=$(LC_ALL=C sfdisk --dump "$dev" 2>/dev/null | awk -F': *' '/^label-id:/ { print tolower($2); exit }')
    if [[ -n $bid && $bid != "$cid" ]]; then
        printf '%s' "\n\nWARNING: the identifier of disk $dev (${cid:-none}) differs from the one in the backup ($bid). The backup may come from a DIFFERENT disk: device names can change between boots. Restoring it on the wrong disk can make its data unreachable."
    fi
}

wizard_restore() {
    local title="Restore partition table" files=() items=() f tag dev idwarn
    mapfile -t files < <(ls -1t "$PW_BACKUP_DIR"/*.sfdisk 2>/dev/null)
    if (( ${#files[@]} == 0 )); then
        ui_msg "$title" "No backups found in $PW_BACKUP_DIR."
        return 0
    fi
    for f in "${files[@]}"; do
        dev=$(awk -F': *' '/^device:/ { print $2; exit }' "$f")
        items+=("$(basename "$f")" "disk ${dev:-?}")
    done
    tag=$(ui_menu "$title" "Available backups (newest first):" "${items[@]}") || return 0
    f="$PW_BACKUP_DIR/$tag"
    dev=$(awk -F': *' '/^device:/ { print $2; exit }' "$f")
    if [[ ! -b $dev ]]; then
        ui_msg "$title" "Disk $dev named in the backup does not exist."
        return 0
    fi
    if disk_in_use "$dev"; then
        ui_msg "$title" "Disk $dev is in use (mounted partitions, swap or active LVM/LUKS).\n\nFor safety, a table can only be restored on a disk that is not in use: boot from a live USB or unmount the partitions.\n\nAlternatively, run manually:\n  sfdisk $dev < $f"
        return 0
    fi
    idwarn=$(backup_id_warning "$f" "$dev")
    ui_confirm_typed "$title" "The partition table of $dev ($(human "$(dev_bytes "$dev")")) will be replaced with:\n\n$(sed -n '/^\//p' "$f")\n\nThe data inside the partitions is not touched, but a wrong table can make it unreachable.$idwarn" "$(basename "$dev")" || return 0
    screen_start "$title"
    backup_table "$dev"
    run_input "$(<"$f")" sfdisk "$dev" && ok "Partition table restored."
    reread_table "$dev"
    show_disk "$dev"
    pause
}

welcome() {
    local extra=""
    (( PW_DRY_RUN )) && extra="\n\n*** DRY-RUN MODE: no changes will be made to the disks ***"
    ui_msg "Partition Wizard $PW_VERSION" "Welcome! This wizard guides you through growing and modifying disk partitions.\n\nSystem: ${PW_DISTRO_NAME:-unknown} (family: ${PW_DISTRO:-unknown})\n\nWARNING: changing partitions always puts data at risk. Before continuing, make sure you have a backup of your important data.\n\n * Before every change the partition table is saved in $PW_BACKUP_DIR\n * Operations are logged to ${PW_LOG_FILE:-(logging disabled)}$extra"
}

main_menu() {
    local choice title="Partition Wizard $PW_VERSION"
    (( PW_DRY_RUN )) && title+=" [DRY RUN]"
    while :; do
        choice=$(UI_CANCEL="Exit" ui_menu "$title" "What do you want to do?" \
            1 "Show disks, partitions and free space" \
            2 "Grow a partition (and its file system)" \
            3 "Shrink a partition" \
            4 "Create a new partition" \
            5 "Delete a partition" \
            6 "Manage LVM (logical volumes)" \
            7 "Detect new space on an enlarged disk" \
            8 "Restore a partition table from a backup" \
            9 "Exit") || choice=9
        case $choice in
            1) show_overview ;;
            2) wizard_expand ;;
            3) wizard_shrink ;;
            4) wizard_create ;;
            5) wizard_delete ;;
            6) wizard_lvm ;;
            7) wizard_rescan ;;
            8) wizard_restore ;;
            9) break ;;
        esac
    done
    [[ $PW_UI == whiptail && -t 1 ]] && clear_screen
    info "Goodbye!"
}

# -----------------------------------------------------------------------------
# Startup
# -----------------------------------------------------------------------------

usage() {
    cat <<EOF
Partition Wizard $PW_VERSION
Interactive wizard to grow, shrink, create and delete partitions on
Debian-based (apt) and Fedora/RHEL-based (dnf) distributions.

Usage: partition-wizard.sh [options]

Options:
  -n, --dry-run        simulation: show the commands without changing anything
  -t, --text           plain text interface (no whiptail)
  -d, --distro NAME    force the distribution family: debian | fedora
  -l, --list           show disks, partitions and free space, then exit
      --install-deps   install all the required tools, then exit
  -y, --yes            install dependencies without asking for confirmation
      --include-loop   also show loop devices (for tests on image files)
  -h, --help           show this help
  -V, --version        show the version

Examples:
  $PW_RUN_CMD
  $PW_RUN_CMD partition-wizard --dry-run
  sudo ./partition-wizard.sh --distro fedora
EOF
}

parse_args() {
    while (( $# )); do
        case $1 in
            -n | --dry-run) PW_DRY_RUN=1 ;;
            -t | --text) PW_NO_TUI=1 ;;
            -d | --distro)
                shift
                case ${1:-} in
                    debian | ubuntu) PW_DISTRO="debian" ;;
                    fedora | rhel | centos) PW_DISTRO="fedora" ;;
                    *) die "Invalid value for --distro: '${1:-}' (use debian or fedora)." ;;
                esac
                ;;
            --distro=*)
                set -- "--distro" "${1#--distro=}" "${@:2}"
                continue
                ;;
            -l | --list) PW_MODE="list" ;;
            --install-deps) PW_MODE="install-deps" ;;
            -y | --yes) PW_YES_DEPS=1 ;;
            --include-loop) PW_INCLUDE_LOOP=1 ;;
            -h | --help) PW_MODE="help" ;;
            -V | --version) PW_MODE="version" ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done
}

require_root() {
    (( EUID == 0 )) && return 0
    if [[ -n $PW_SELF && -f $PW_SELF ]] && command -v sudo >/dev/null 2>&1; then
        info "Administrator privileges are required: restarting with sudo..."
        exec sudo -- bash "$PW_SELF" "${PW_ARGS[@]}"
    fi
    die "This script must be run as root, for example: $PW_RUN_CMD"
}

init_log() {
    if ! { mkdir -p "$(dirname "$PW_LOG_FILE")" && touch "$PW_LOG_FILE"; } 2>/dev/null; then
        PW_LOG_FILE=""
    fi
    log "===== partition-wizard $PW_VERSION started (mode=$PW_MODE dry-run=$PW_DRY_RUN) ====="
}

choose_distro() {
    [[ -n $PW_DISTRO ]] && return 0
    local c
    c=$(ui_menu "Distribution" "The distribution could not be recognised (${PW_DISTRO_NAME:-unknown}).\nChoose the package manager to use for installing missing tools:" \
        debian "Debian/Ubuntu based (apt)" \
        fedora "Fedora/RHEL based (dnf)") || c=""
    PW_DISTRO=$c
    [[ -n $PW_DISTRO ]] || warn "No package manager selected: missing tools will have to be installed manually."
}

main() {
    PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"
    PW_ARGS=("$@")
    init_colors
    parse_args "$@"
    case $PW_MODE in
        help) usage; return 0 ;;
        version) echo "partition-wizard $PW_VERSION"; return 0 ;;
    esac

    require_root
    init_log
    detect_distro
    trap cleanup EXIT
    trap on_interrupt INT QUIT
    trap 'exit 143' TERM

    case $PW_MODE in
        install-deps)
            install_all_deps
            return
            ;;
        list)
            ensure_cmds "${PW_CORE_CMDS[@]}" || return 1
            show_overview 2>&1
            return 0
            ;;
    esac

    # The wizard needs a terminal: when the script arrives through a pipe
    # (curl | bash) standard input is reconnected to the terminal, unless
    # sudo makes the keyboard unreachable (see keyboard_unreachable).
    if [[ ! -t 0 ]]; then
        if keyboard_unreachable; then
            pipe_hint
            exit 1
        fi
        { exec 0</dev/tty; } 2>/dev/null || die "An interactive terminal is required to use the wizard."
    fi

    choose_distro
    ensure_cmds "${PW_CORE_CMDS[@]}" || die "Cannot continue without the core tools."
    if (( ! PW_NO_TUI )) && ! command -v whiptail >/dev/null 2>&1 && [[ -n $PW_DISTRO ]] && (( ! PW_DRY_RUN )); then
        if ui_yesno "Interface" "whiptail can be installed for a friendlier interface (menus and dialog boxes).\nInstall it? (Otherwise the plain text interface is used.)"; then
            install_pkgs "$(pkg_for_cmd whiptail)" || warn "Installing whiptail failed: using the text interface."
        fi
    fi
    init_sfdisk_opts || exit 1
    ui_init
    welcome
    main_menu
}

# With PW_NO_MAIN=1 the script can be sourced without starting the wizard,
# for example by the automated tests.
[[ -n ${PW_NO_MAIN:-} ]] || { main "$@"; exit $?; }

#!/usr/bin/env bash
# =============================================================================
#  partition-wizard.sh
#
#  Wizard interattivo per espandere e modificare le partizioni dei dischi su
#  distribuzioni Linux basate su Debian (Debian, Ubuntu, Mint, ...) o su
#  Fedora (Fedora, RHEL, CentOS Stream, Rocky, Alma, ...).
#
#  Esecuzione diretta da GitHub:
#    curl -fsSL https://raw.githubusercontent.com/pilippopilippo/linux-partition-manager/main/partition-wizard.sh | sudo bash
#
#  Progetto: https://github.com/pilippopilippo/linux-partition-manager
#  Licenza:  MIT
# =============================================================================
#
# Tutto il codice è racchiuso in funzioni e `main` viene invocato sull'ultima
# riga: in questo modo lo script funziona anche quando bash lo legge da una
# pipe (curl ... | sudo bash).

set -o pipefail

PW_VERSION="1.0.0"
PW_REPO="pilippopilippo/linux-partition-manager"
PW_RAW_URL="https://raw.githubusercontent.com/${PW_REPO}/main/partition-wizard.sh"
PW_SELF="${BASH_SOURCE[0]:-}"

# Opzioni (impostate dalla riga di comando)
PW_MODE="wizard"          # wizard | list | install-deps | help | version
PW_DRY_RUN=0              # 1 = mostra i comandi senza eseguirli
PW_ASSUME_YES=0           # 1 = risponde "sì" a tutte le domande (solo test automatici)
PW_YES_DEPS=0             # 1 = installa le dipendenze senza chiedere
PW_NO_TUI=0               # 1 = interfaccia testuale semplice anche se c'è whiptail
PW_INCLUDE_LOOP=0         # 1 = mostra anche i dispositivi loop
PW_DISTRO=""              # debian | fedora (vuoto = rilevamento automatico)
PW_LOG_FILE="${PW_LOG_FILE:-/var/log/partition-wizard.log}"
PW_BACKUP_DIR="${PW_BACKUP_DIR:-/var/backups/partition-wizard}"

# Stato interno
PW_ARGS=()
PW_UI="text"
PW_DISTRO_NAME=""
PW_PKG_UPDATED=0
PW_TMP_MOUNTS=()
PW_LAST_MNT=""
PW_FSCK_DONE=""           # ultimo dispositivo ext2/3/4 verificato con e2fsck
PW_DISK_CHANGED=0         # 1 se prepare_disk_growth ha rilevato/modificato qualcosa
SFDISK_OPTS=(--no-reread)

MIB=1048576

# Tipi di partizione GPT
GPT_LINUX="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
GPT_SWAP="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"
GPT_LVM="E6D6D379-F507-44C2-A23C-238F2A3DF928"
GPT_MSDATA="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

# Comandi di base (sempre necessari) e opzionali (per i vari file system)
PW_CORE_CMDS=(sfdisk partx lsblk blkid findmnt wipefs blockdev awk)
PW_OPTIONAL_CMDS=(whiptail resize2fs xfs_growfs btrfs pvresize cryptsetup mkfs.vfat ntfsresize)

# -----------------------------------------------------------------------------
# Messaggi, registro ed esecuzione dei comandi
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
    printf '%s [%d] %s\n' "$(date '+%F %T')" "$$" "$*" >>"$PW_LOG_FILE" 2>/dev/null || true
}

info() { printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*" >&2; log "INFO  $*"; }
ok() {
    if (( PW_DRY_RUN )); then
        printf '%s ✔ %s %s (simulato)\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2
    else
        printf '%s ✔ %s %s\n' "$C_GREEN$C_BOLD" "$C_RESET" "$*" >&2
    fi
    log "OK    $*"
}
warn() { printf '%sATTENZIONE:%s %s\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2; log "WARN  $*"; }
err()  { printf '%sERRORE:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; log "ERROR $*"; }
die()  { err "$*"; exit 1; }

# Esegue un comando mostrandolo a schermo e registrandolo nel log.
# In modalità simulazione (--dry-run) il comando viene solo mostrato.
run() {
    local cmdline rc
    printf -v cmdline '%q ' "$@"
    cmdline=${cmdline% }
    if (( PW_DRY_RUN )); then
        printf '%s[simulazione]%s %s\n' "$C_YELLOW" "$C_RESET" "$cmdline" >&2
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

# Come run, ma passa il primo argomento sullo standard input del comando.
run_input() {
    local input=$1 cmdline rc
    shift
    printf -v cmdline '%q ' "$@"
    if [[ $input == *$'\n'* ]]; then
        cmdline="${cmdline% } <<< ($(wc -l <<<"$input") righe di input)"
    else
        cmdline="echo '${input//\'/\'\\\'\'}' | ${cmdline% }"
    fi
    if (( PW_DRY_RUN )); then
        printf '%s[simulazione]%s %s\n' "$C_YELLOW" "$C_RESET" "$cmdline" >&2
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

# Durante le operazioni critiche Ctrl+C viene ignorato (anche dai comandi
# avviati), per non lasciare file system o tabelle a metà.
critical_begin() { trap '' INT QUIT; }
critical_end()   { trap on_interrupt INT QUIT; }

on_interrupt() {
    printf '\n' >&2
    warn "Interrotto dall'utente."
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
# Funzioni di utilità
# -----------------------------------------------------------------------------

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# Byte -> stringa leggibile (es. 21474836480 -> "20.00 GiB"), arrotondata per
# difetto per non mostrare mai più spazio di quello realmente disponibile
human() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB PiB", u, " "); i = 1
        if (b < 0) { s = "-"; b = -b } else s = ""
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%s%d %s\n", s, b, u[i]
        else printf "%s%.2f %s\n", s, int(b * 100 + 1e-9) / 100, u[i]
    }'
}

# Dimensione leggibile -> byte. Accetta K, M, G, T (multipli di 1024),
# anche con decimali: 500M, 20G, 1.5T, 2,5G, 10GiB, 10GB.
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

# Tipo di contenuto di un dispositivo: ext4, xfs, btrfs, swap, crypto_LUKS,
# LVM2_member, ntfs, vfat, ... (vuoto se non riconosciuto)
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

swap_active() {
    local d n
    d=$(readlink -f "$1")
    while read -r n _; do
        [[ $n == /dev/* && $(readlink -f "$n") == "$d" ]] && return 0
    done </proc/swaps
    return 1
}

# Dispositivi costruiti sopra DEV (LVM, LUKS, RAID ...)
dev_holders() {
    local h
    for h in /sys/class/block/"$(kname "$1")"/holders/*; do
        [[ -e $h ]] && printf '/dev/%s\n' "${h##*/}"
    done
}

# Primo dispositivo "figlio" visibile da lsblk (es. /dev/mapper/vg-root)
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

# Numero di una partizione a partire dal suo dispositivo
part_nr() {
    local f
    f="/sys/class/block/$(kname "$1")/partition"
    if [[ -r $f ]]; then cat "$f"; else printf '%s\n' "${1##*[!0-9]}"; fi
}

# Dispositivo della partizione NR del disco DISK (es. /dev/sda 2 -> /dev/sda2,
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
# Distribuzione e dipendenze
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

# Pacchetto che fornisce un comando, per la famiglia di distribuzione corrente
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
            err "Distribuzione non riconosciuta: installa manualmente i pacchetti: $*"
            return 1
            ;;
    esac
}

# Verifica che i comandi indicati siano presenti; se mancano propone di
# installare i pacchetti corrispondenti. Restituisce 1 se qualcosa manca.
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
        err "Comandi mancanti: ${missing[*]}. Installali manualmente e riprova."
        return 1
    fi
    if (( PW_DRY_RUN )); then
        err "Comandi mancanti: ${missing[*]} (pacchetti: ${pkgs[*]}). In simulazione non installo nulla."
        return 1
    fi
    if (( ! PW_YES_DEPS )); then
        ui_yesno "Dipendenze mancanti" "Per continuare servono questi comandi: ${missing[*]}\n\nPacchetti da installare: ${pkgs[*]}\n\nVuoi installarli ora?" || return 1
    fi
    install_pkgs "${pkgs[@]}" || { err "Installazione dei pacchetti non riuscita: ${pkgs[*]}"; return 1; }
    for c in "${missing[@]}"; do
        command -v "$c" >/dev/null 2>&1 || { err "Il comando '$c' non è ancora disponibile."; return 1; }
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
        ok "Tutte le dipendenze sono già installate."
        return 0
    fi
    info "Pacchetti da installare: ${pkgs[*]}"
    if (( ! PW_YES_DEPS )); then
        ui_yesno "Dipendenze" "Verranno installati questi pacchetti:\n${pkgs[*]}\n\nProcedere?" || return 1
    fi
    if ! install_pkgs "${pkgs[@]}"; then
        warn "Installazione cumulativa non riuscita: provo un pacchetto alla volta."
        for p in "${pkgs[@]}"; do
            install_pkgs "$p" || failed+=("$p")
        done
    fi
    for c in "${PW_CORE_CMDS[@]}"; do
        command -v "$c" >/dev/null 2>&1 || core_missing+=("$c")
    done
    (( ${#failed[@]} )) && warn "Pacchetti non installati (funzioni relative non disponibili): ${failed[*]}"
    if (( ${#core_missing[@]} )); then
        err "Mancano ancora comandi indispensabili: ${core_missing[*]}"
        return 1
    fi
    ok "Dipendenze installate."
}

# Opzioni di sfdisk: la tabella viene scritta senza far rileggere l'intero
# disco al kernel (che fallirebbe se il disco è in uso); il kernel viene poi
# aggiornato partizione per partizione con partx.
init_sfdisk_opts() {
    local help
    help=$(LC_ALL=C sfdisk --help 2>/dev/null)
    if ! grep -q -- '--delete' <<<"$help"; then
        err "La versione di sfdisk (util-linux) è troppo vecchia: serve util-linux 2.28 o successivo."
        return 1
    fi
    SFDISK_OPTS=(--no-reread)
    grep -q -- '--no-tell-kernel' <<<"$help" && SFDISK_OPTS+=(--no-tell-kernel)
    return 0
}

# -----------------------------------------------------------------------------
# Interfaccia utente: whiptail se disponibile, altrimenti testo semplice
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

# Numero di righe occupate da un testo nella finestra
ui_lines() {
    awk -v w=$(( UI_W - 4 )) '{ l = length($0); n += (l > w) ? int((l + w - 1) / w) : 1 } END { print n + 0 }' <<<"$1"
}

# Converte le sequenze "\n" in veri a capo
ui_fmt() { printf '%s' "${1//\\n/$'\n'}"; }

ui_header() { printf '\n%s━━━ %s ━━━%s\n' "$C_BOLD" "$1" "$C_RESET" >&2; }

screen_start() {
    [[ $PW_UI == whiptail && -t 1 ]] && clear
    ui_header "$1"
}

pause() {
    (( PW_ASSUME_YES )) && return 0
    printf '\n' >&2
    read -r -p "Premi Invio per ${1:-tornare al menu}... " _
}

# Prima di aprire una finestra whiptail dopo l'output dei comandi, lascia il
# tempo di leggerlo (whiptail ripulisce lo schermo).
pause_if_tui() { [[ $PW_UI == whiptail ]] && pause "continuare"; return 0; }

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
        (( PW_ASSUME_YES )) || read -r -p "Premi Invio per continuare... " _
    fi
    return 0
}

# ui_yesno TITOLO TESTO [si|no]  (terzo argomento: risposta predefinita)
ui_yesno() {
    local title=$1 text def=${3:-si} h ans
    (( PW_ASSUME_YES )) && return 0
    text=$(ui_fmt "$2")
    if [[ $PW_UI == whiptail ]]; then
        local args=(--title "$title" --yes-button "Sì" --no-button "No")
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
        if [[ $def == no ]]; then read -r -p "[s/N] " ans || return 1; else read -r -p "[S/n] " ans || return 1; fi
        ans=$(trim "${ans,,}")
        case $ans in
            "") [[ $def != no ]]; return ;;
            s | si | sì | y | yes) return 0 ;;
            n | no) return 1 ;;
        esac
    done
}

# ui_input TITOLO TESTO [VALORE_PREDEFINITO] -> stampa il valore inserito
ui_input() {
    local title=$1 text def=${3:-} h val
    text=$(ui_fmt "$2")
    if [[ $PW_UI == whiptail ]]; then
        ui_size
        h=$(( $(ui_lines "$text") + 8 ))
        (( h > UI_HMAX )) && h=$UI_HMAX
        whiptail --title "$title" --ok-button "OK" --cancel-button "Annulla" \
            --inputbox "$text" "$h" "$UI_W" "$def" 3>&1 1>&2 2>&3
        return
    fi
    ui_header "$title"
    printf '%s\n' "$text" >&2
    read -r -e -i "$def" -p "> " val || return 1
    printf '%s\n' "$val"
}

# ui_menu TITOLO TESTO tag1 voce1 [tag2 voce2 ...] -> stampa il tag scelto
# Variabili facoltative: UI_CANCEL (testo del pulsante "Indietro"),
# UI_NOTAGS=1 (non mostra i tag, solo le voci).
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
        whiptail --title "$title" --ok-button "Seleziona" --cancel-button "${UI_CANCEL:-Indietro}" \
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
    printf '   0) %s\n' "${UI_CANCEL:-Indietro}" >&2
    while :; do
        read -r -p "Scelta: " ans || return 1
        ans=$(trim "$ans")
        [[ -z $ans || $ans == 0 ]] && return 1
        if [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#tags[@]} )); then
            printf '%s\n' "${tags[ans - 1]}"
            return 0
        fi
    done
}

# Conferma rinforzata: l'utente deve digitare esattamente una parola.
ui_confirm_typed() {
    local title=$1 text=$2 word=$3 ans
    (( PW_ASSUME_YES )) && return 0
    ans=$(ui_input "$title" "$text\n\nPer confermare digita esattamente: $word") || return 1
    [[ $(trim "$ans") == "$word" ]] && return 0
    ui_msg "$title" "Il testo inserito non corrisponde: operazione annullata."
    return 1
}

# -----------------------------------------------------------------------------
# Lettura della tabella delle partizioni (tramite sfdisk --dump)
# -----------------------------------------------------------------------------
# Dopo load_table DISCO sono disponibili:
#   T_LABEL  gpt | dos        T_SS     dimensione del settore logico (byte)
#   T_TOTAL  settori totali   T_FIRST/T_LAST primo/ultimo settore utilizzabile
#   T_NR[] T_START[] T_SIZE[] T_TYPE[]  partizioni (settori logici)

load_table() {
    local disk=$1 dump line
    T_LABEL="" T_FIRST=0 T_LAST=0
    T_NR=() T_START=() T_SIZE=() T_TYPE=()
    T_SS=$(blockdev --getss "$disk" 2>/dev/null) || T_SS=512
    [[ $T_SS =~ ^[0-9]+$ ]] || T_SS=512
    T_TOTAL=$(( $(dev_bytes "$disk") / T_SS ))
    dump=$(LC_ALL=C sfdisk --dump "$disk" 2>/dev/null) || return 1
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
            # MBR: settori indirizzabili con 32 bit (2 TiB con settori da 512 byte)
            (( T_LAST > 4294967295 )) && T_LAST=4294967295
            ;;
        gpt)
            (( T_FIRST > 0 )) || T_FIRST=34
            (( T_LAST > 0 )) || T_LAST=$(( T_TOTAL - 34 ))
            ;;
    esac
    [[ -n $T_LABEL ]]
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

# Ultimo settore che la partizione NR può raggiungere senza spostare le altre
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
            # partizione logica successiva: lascia spazio per il suo EBR
            e=$(( T_START[j] - align - 1 ))
        else
            e=$(( T_START[j] - 1 ))
        fi
        (( e < limit )) && limit=$e
    done
    printf '%s\n' "$limit"
}

# Regioni di spazio non allocato (>= 1 MiB, inizio allineato a 1 MiB) in cui
# è possibile creare una partizione primaria/GPT. Stampa "inizio fine".
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

# Spazio (byte) oltre la fine della tabella GPT: diverso da zero dopo aver
# ingrandito un disco virtuale finché l'intestazione di backup non viene spostata.
gpt_tail_gap() {
    local entries std_last
    [[ $T_LABEL == gpt ]] || { echo 0; return; }
    entries=$(( (16384 + T_SS - 1) / T_SS ))
    std_last=$(( T_TOTAL - 2 - entries ))
    if (( std_last > T_LAST )); then echo $(( (std_last - T_LAST) * T_SS )); else echo 0; fi
}

# Primo numero di partizione libero (per prevedere il nome in simulazione)
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
# Elenchi e descrizioni di dischi e partizioni
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
        "") pt=$(fs_type "$d"); pt=${pt:+contiene $pt}; pt=${pt:-nessuna tabella} ;;
    esac
    nparts=$(lsblk -lno TYPE "$d" 2>/dev/null | grep -c '^part$')
    printf '%10s  %-16s %2s part.  %s' "$(human "$(dev_bytes "$d")")" "$pt" "$nparts" "$model"
}

select_disk() {
    local title=$1 text=$2 d disks=() items=()
    mapfile -t disks < <(list_disks)
    if (( ${#disks[@]} == 0 )); then
        ui_msg "$title" "Nessun disco disponibile."
        return 1
    fi
    for d in "${disks[@]}"; do
        items+=("$d" "$(disk_desc "$d")")
    done
    ui_menu "$title" "$text" "${items[@]}"
}

# Descrizione della partizione all'indice I della tabella caricata
part_desc() {
    local dev=$1 i=$2 size t label where
    size=$(human $(( T_SIZE[i] * T_SS )))
    if is_extended_idx "$i"; then
        printf '%10s  partizione estesa (contiene le logiche)' "$size"
        return
    fi
    t=$(fs_type "$dev")
    label=$(fs_prop "$dev" LABEL)
    where=$(mountpoint_of "$dev")
    swap_active "$dev" && where="[swap attiva]"
    if [[ -z $where && -n $(dev_holders "$dev") ]]; then
        where="→ $(dev_child "$dev")"
    fi
    printf '%10s  %-12s %-14s %s' "$size" "${t:--}" "${label:+[$label]}" "$where"
}

# select_partition DISCO TITOLO TESTO [1 = includi le partizioni estese]
select_partition() {
    local disk=$1 title=$2 text=$3 with_ext=${4:-0} i dev items=()
    if ! load_table "$disk"; then
        ui_msg "$title" "Il disco $disk non contiene una tabella delle partizioni."
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
        ui_msg "$title" "Nessuna partizione trovata su $disk."
        return 1
    fi
    ui_menu "$title" "$text" "${items[@]}"
}

show_disk() {
    printf '\n' >&2
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$1" >&2 2>/dev/null
}

# -----------------------------------------------------------------------------
# Operazioni di basso livello
# -----------------------------------------------------------------------------

backup_table() {
    local disk=$1 f
    f="$PW_BACKUP_DIR/$(kname "$disk")-$(date +%Y%m%d-%H%M%S).sfdisk"
    if (( PW_DRY_RUN )); then
        printf '%s[simulazione]%s backup della tabella in %s\n' "$C_YELLOW" "$C_RESET" "$f" >&2
        return 0
    fi
    if mkdir -p "$PW_BACKUP_DIR" && sfdisk --dump "$disk" >"$f" 2>/dev/null; then
        info "Backup della tabella delle partizioni: $f"
        info "Per ripristinarlo: sfdisk $disk < $f"
        log "BACKUP $disk -> $f"
    else
        rm -f "$f"
        warn "Impossibile salvare il backup della tabella delle partizioni di $disk."
    fi
    return 0
}

# Comunica al kernel le modifiche alla tabella delle partizioni
reread_table() {
    local disk=$1
    (( PW_DRY_RUN )) && return 0
    sync
    partx -u "$disk" >/dev/null 2>&1
    partx -a "$disk" >/dev/null 2>&1
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=15 >/dev/null 2>&1
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
        err "Impossibile spostare l'intestazione GPT di backup di $disk."
        return 1
    fi
    reread_table "$disk"
    ok "Tabella GPT estesa fino alla fine del disco."
}

# Rileva un eventuale ingrandimento del disco e corregge la GPT se necessario
prepare_disk_growth() {
    local disk=$1 before after gap
    PW_DISK_CHANGED=0
    before=$(dev_bytes "$disk")
    rescan_disk "$disk"
    after=$(dev_bytes "$disk")
    if (( after != before )); then
        info "Nuova dimensione rilevata per $disk: $(human "$before") → $(human "$after")"
        PW_DISK_CHANGED=1
    fi
    load_table "$disk" || return 0
    gap=$(gpt_tail_gap)
    if (( gap >= MIB )); then
        if ui_yesno "Tabella GPT da estendere" "La tabella GPT di $disk non copre tutto il disco: $(human "$gap") alla fine non sono utilizzabili.\n\nSuccede normalmente dopo aver ingrandito un disco virtuale. Vuoi spostare l'intestazione GPT di backup alla fine del disco per rendere disponibile questo spazio?\n\n(L'operazione è sicura e non modifica le partizioni esistenti.)"; then
            fix_gpt "$disk"
            load_table "$disk"
            PW_DISK_CHANGED=1
        fi
    fi
    return 0
}

# Imposta il settore finale della partizione NR (ingrandimento o riduzione).
# Restituisce 2 se la tabella è stata scritta ma il kernel usa ancora la
# vecchia dimensione (serve un riavvio).
set_part_end() {
    local disk=$1 nr=$2 new_end=$3 i j start ext_end part expected actual
    load_table "$disk" || return 1
    i=$(tbl_idx "$nr") || { err "Partizione $nr non trovata su $disk."; return 1; }
    start=${T_START[i]}
    backup_table "$disk"
    if [[ $T_LABEL == dos ]] && (( nr >= 5 )); then
        for j in "${!T_NR[@]}"; do
            is_extended_idx "$j" || continue
            ext_end=$(( T_START[j] + T_SIZE[j] - 1 ))
            if (( new_end > ext_end )); then
                info "Ingrandisco prima la partizione estesa n. ${T_NR[j]} che contiene la partizione logica."
                run_input ", $(( new_end - T_START[j] + 1 ))" sfdisk "${SFDISK_OPTS[@]}" -N "${T_NR[j]}" "$disk" || return 1
            fi
        done
    fi
    run_input ", $(( new_end - start + 1 ))" sfdisk "${SFDISK_OPTS[@]}" -N "$nr" "$disk" || return 1
    reread_table "$disk"
    (( PW_DRY_RUN )) && return 0
    part=$(part_dev "$disk" "$nr")
    expected=$(( (new_end - start + 1) * T_SS ))
    actual=$(dev_bytes "$part")
    if (( actual != expected )); then
        warn "La tabella è aggiornata, ma il kernel vede ancora $part con la vecchia dimensione ($(human "$actual"))."
        warn "Riavvia il sistema e poi esegui di nuovo \"Espandi\" sulla stessa partizione per completare l'operazione."
        return 2
    fi
    ok "Partizione $part ora di $(human "$expected")."
}

temp_mount() {
    local dev=$1 d
    d=$(mktemp -d /tmp/partition-wizard.XXXXXX) || return 1
    if ! run mount "$dev" "$d"; then
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

# ID del dispositivo all'interno di un file system btrfs (multi-dispositivo)
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
        err "e2fsck ha trovato errori che non può correggere automaticamente (codice $rc). Esegui 'e2fsck -f $1' manualmente."
        return 1
    fi
    return 0
}

# Espande il file system TYPE sul dispositivo DEV fino a occuparlo tutto
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
                temp_mount "$dev" || return 1
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
                err "La partizione NTFS $dev è montata: smontala prima di espanderla."
                return 1
            fi
            run_input y ntfsresize -f "$dev" || rc=$?
            (( rc == 0 )) && info "Al prossimo avvio Windows eseguirà un controllo del disco: è normale."
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
            warn "Espansione automatica non supportata per '$t'."
            return 1
            ;;
    esac
    [[ -n $tmp ]] && temp_umount "$tmp"
    if (( rc == 0 )); then
        ok "File system $t su $dev espanso."
    else
        err "Espansione del file system $t su $dev non riuscita (codice $rc)."
    fi
    return "$rc"
}

grow_luks() {
    local dev=$1 mapper
    mapper=$(lsblk -lnpo NAME,TYPE "$dev" 2>/dev/null | awk '$2 == "crypt" { print $1; exit }')
    if [[ -z $mapper ]]; then
        warn "Il volume cifrato LUKS su $dev non è aperto: verrà usato tutto lo spazio alla prossima apertura."
        warn "Dopo averlo aperto, espandi il contenuto con questo wizard (opzione \"Espandi\")."
        return 0
    fi
    ensure_cmds cryptsetup || return 1
    info "Ridimensiono il volume cifrato $mapper (potrebbe essere richiesta la passphrase)."
    run cryptsetup resize "$mapper" || { err "cryptsetup resize non riuscito."; return 1; }
    ok "Volume cifrato $mapper espanso."
    grow_contents "$mapper"
}

grow_pv() {
    local dev=$1 vg
    ensure_cmds pvresize pvs || return 1
    run pvresize "$dev" || { err "pvresize non riuscito."; return 1; }
    ok "Volume fisico LVM $dev espanso."
    vg=$(trim "$(pvs --noheadings -o vg_name "$dev" 2>/dev/null)")
    [[ -n $vg ]] || return 0
    pause_if_tui
    if ui_yesno "LVM" "Il nuovo spazio è ora disponibile nel gruppo di volumi \"$vg\".\n\nVuoi assegnarlo subito a un volume logico (espandendone anche il file system)?"; then
        lvm_extend "$vg"
    fi
}

# Espande ricorsivamente il contenuto di un dispositivo appena ingrandito:
# LUKS -> LVM -> file system.
grow_contents() {
    local dev=$1 t
    t=$(fs_type "$dev")
    case $t in
        crypto_LUKS) grow_luks "$dev" ;;
        LVM2_member) grow_pv "$dev" ;;
        ext2 | ext3 | ext4 | xfs | btrfs | ntfs | swap) grow_fs "$dev" "$t" ;;
        "")
            info "Nessun file system rilevato su $dev: è stata ingrandita solo la partizione."
            return 0
            ;;
        *)
            warn "Il contenuto '$t' di $dev non è supportato per l'espansione automatica: espandilo manualmente."
            return 0
            ;;
    esac
}

# Dimensione minima (byte) del file system, per la riduzione
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

# Riduce la partizione NR fino al settore NEW_END: prima riduce il file
# system (con un piccolo margine), poi la partizione, infine riespande il file
# system per occupare esattamente la nuova partizione.
# Per ext2/3/4 e NTFS il file system deve essere smontato.
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
            run resize2fs "$part" "$(( fs_target / 1024 ))K" || { err "Riduzione del file system non riuscita: nessuna modifica alla partizione."; return 1; }
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
                err "Riduzione del file system non riuscita: nessuna modifica alla partizione."
                [[ -n $tmp ]] && temp_umount "$tmp"
                return 1
            fi
            set_part_end "$disk" "$nr" "$new_end" || rc=$?
            (( rc == 0 )) && { run btrfs filesystem resize "$devid:max" "$mnt" || rc=$?; }
            [[ -n $tmp ]] && temp_umount "$tmp"
            ;;
        ntfs)
            ensure_cmds ntfsresize || return 1
            run_input y ntfsresize -f -s "$fs_target" "$part" || { err "Riduzione del file system non riuscita: nessuna modifica alla partizione."; return 1; }
            set_part_end "$disk" "$nr" "$new_end" || return $?
            run_input y ntfsresize -f "$part" || rc=$?
            (( rc == 0 )) && info "Al prossimo avvio Windows eseguirà un controllo del disco: è normale."
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
            err "La riduzione di '$t' non è supportata."
            return 1
            ;;
    esac
    return "$rc"
}

# Crea una partizione da START a END (settori) e la formatta.
# Imposta CREATED_PART con il dispositivo creato.
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
        [[ -n $nr ]] || { err "Partizione appena creata non trovata nella tabella."; return 1; }
    fi
    part=$(part_dev "$disk" "$nr")
    if (( ! PW_DRY_RUN )) && ! wait_for_dev "$part"; then
        err "Il dispositivo $part non è comparso: riavvia il sistema e formatta la partizione manualmente."
        return 1
    fi
    ok "Creata la partizione $part."
    CREATED_PART=$part
    [[ $fs == none ]] && return 0
    run wipefs -a "$part" >/dev/null
    make_fs "$part" "$fs" "$label"
}

make_fs() {
    local dev=$1 fs=$2 label=$3 args=()
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
            run mkfs.vfat -F 32 "${args[@]}" "$dev"
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
    backup_table "$disk"
    if (( wipe )) && [[ -b $part ]]; then
        run wipefs -a "$part" || warn "wipefs non riuscito: proseguo comunque."
    fi
    run sfdisk "${SFDISK_OPTS[@]}" --delete "$disk" "$nr" || return 1
    (( PW_DRY_RUN )) || partx -d --nr "$nr" "$disk" >/dev/null 2>&1
    reread_table "$disk"
    ok "Partizione $part eliminata."
}

# Righe di FILE (fstab o crypttab) che fanno riferimento al dispositivo DEV.
# FIELD è il campo che contiene il dispositivo (1 per fstab, 2 per crypttab).
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

comment_config_lines() {   # file numeri_di_riga...
    local file=$1 n bak
    shift
    bak="$file.partition-wizard-$(date +%Y%m%d-%H%M%S).bak"
    run cp -a "$file" "$bak" || return 1
    for n in "$@"; do
        run sed -i "${n}s/^/# rimossa da partition-wizard: /" "$file" || return 1
    done
    ok "Righe commentate in $file (copia di sicurezza: $bak)."
}

systemd_reload() {
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        run systemctl daemon-reload
    fi
    return 0
}

# Aggiunge la nuova partizione a /etc/fstab e la monta
setup_mount() {
    local dev=$1 t=$2 mnt uuid pass=2 line bak
    while :; do
        mnt=$(ui_input "Montaggio automatico" "Vuoi montare la nuova partizione $dev automaticamente all'avvio?\n\nInserisci il punto di montaggio (es. /mnt/dati oppure /srv/backup)\noppure lascia vuoto per non montarla." "") || return 0
        mnt=$(trim "$mnt")
        [[ -z $mnt ]] && return 0
        if [[ $mnt != /* || $mnt == *[[:space:]]* || $mnt == / ]]; then
            ui_msg "Montaggio automatico" "Percorso non valido: deve essere assoluto e senza spazi."
            continue
        fi
        if findmnt -n "$mnt" >/dev/null 2>&1; then
            ui_msg "Montaggio automatico" "Su $mnt è già montato un altro file system: scegli un altro percorso."
            continue
        fi
        if [[ -d $mnt && -n $(ls -A "$mnt" 2>/dev/null) ]]; then
            ui_yesno "Montaggio automatico" "La cartella $mnt non è vuota: il suo contenuto verrebbe nascosto dalla nuova partizione.\n\nUsarla comunque?" no || continue
        fi
        break
    done
    uuid=$(fs_prop "$dev" UUID)
    [[ -n $uuid ]] || uuid="<UUID-di-$dev>"
    case $t in xfs | btrfs | vfat) pass=0 ;; esac
    line="UUID=$uuid  $mnt  $t  defaults,nofail  0  $pass"
    bak="/etc/fstab.partition-wizard-$(date +%Y%m%d-%H%M%S).bak"
    run cp -a /etc/fstab "$bak" || return 1
    run mkdir -p "$mnt" || return 1
    run_input "$line" tee -a /etc/fstab >/dev/null || return 1
    systemd_reload
    if run mount "$mnt"; then
        ok "Partizione montata su $mnt e aggiunta a /etc/fstab."
    else
        err "Montaggio non riuscito: ripristino /etc/fstab dalla copia di sicurezza."
        run cp -a "$bak" /etc/fstab
        systemd_reload
    fi
}

setup_swap() {
    local dev=$1 uuid bak
    ui_yesno "Swap" "Vuoi attivare subito la nuova swap $dev e aggiungerla a /etc/fstab per gli avvii successivi?" || return 0
    uuid=$(fs_prop "$dev" UUID)
    [[ -n $uuid ]] || uuid="<UUID-di-$dev>"
    bak="/etc/fstab.partition-wizard-$(date +%Y%m%d-%H%M%S).bak"
    run cp -a /etc/fstab "$bak" || return 1
    run_input "UUID=$uuid  none  swap  sw  0  0" tee -a /etc/fstab >/dev/null || return 1
    systemd_reload
    run swapon "$dev" && ok "Swap attivata."
}

# Calcola il nuovo settore finale a partire dalla risposta dell'utente.
# compute_end RISPOSTA INIZIO FINE_ATTUALE LIMITE MODO [MINIMO_BYTE]
#   MODO: grow | shrink | create
# Imposta NEW_END, oppure SIZE_ERR e restituisce 1.
compute_end() {
    local spec start=$2 cur_end=$3 limit=$4 mode=$5 min=${6:-0} cur align bytes secs
    spec=$(trim "${1,,}")
    spec=${spec// /}
    align=$(( MIB / T_SS ))
    cur=$(( (cur_end - start + 1) * T_SS ))
    [[ $mode == create ]] && cur=0
    NEW_END="" SIZE_ERR=""
    if [[ $spec == max || $spec == tutto || $spec == 100% ]]; then
        if [[ $mode == shrink ]]; then
            SIZE_ERR="Per ridurre indica una dimensione (es. 20G oppure -5G)."
            return 1
        fi
        NEW_END=$limit
        return 0
    fi
    case $spec in
        +*) bytes=$(parse_size "${spec#+}") && bytes=$(( cur + bytes )) ;;
        -*) bytes=$(parse_size "${spec#-}") && bytes=$(( cur - bytes )) ;;
        *) bytes=$(parse_size "$spec") ;;
    esac || { SIZE_ERR="Dimensione non valida: \"$1\". Esempi: 500M, 20G, 1.5T."; return 1; }
    secs=$(( bytes / T_SS / align * align ))
    if (( secs <= 0 )); then
        SIZE_ERR="La dimensione deve essere di almeno 1 MiB."
        return 1
    fi
    NEW_END=$(( start + secs - 1 ))
    case $mode in
        grow)
            if (( NEW_END <= cur_end )); then
                SIZE_ERR="La nuova dimensione deve essere maggiore di quella attuale ($(human "$cur"))."
                return 1
            fi
            ;;
        shrink)
            if (( NEW_END >= cur_end )); then
                SIZE_ERR="La nuova dimensione deve essere minore di quella attuale ($(human "$cur"))."
                return 1
            fi
            if (( secs * T_SS < min )); then
                SIZE_ERR="Dimensione troppo piccola: il minimo consigliato è $(human "$min")."
                return 1
            fi
            ;;
    esac
    if (( NEW_END > limit )); then
        SIZE_ERR="Spazio insufficiente: la dimensione massima è $(human $(( (limit - start + 1) * T_SS )))."
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# LVM
# -----------------------------------------------------------------------------

vg_field() { trim "$(vgs --noheadings --units b --nosuffix -o "$2" "$1" 2>/dev/null)"; }

# Espande un volume logico (facoltativamente solo quelli del gruppo VG)
lvm_extend() {
    local title="Espandi volume logico" only_vg=${1:-} path size vg attr items=() lv
    local vgfree ext lvsize ans bytes n args=()
    ensure_cmds lvs vgs lvextend || return 0
    while IFS='|' read -r path size vg attr; do
        path=$(trim "$path") size=$(trim "$size") vg=$(trim "$vg") attr=$(trim "$attr")
        [[ -n $path ]] || continue
        [[ ${attr:0:1} == "-" || ${attr:0:1} == "o" ]] || continue
        [[ -z $only_vg || $vg == "$only_vg" ]] || continue
        items+=("$path" "$(human "$size")  (gruppo $vg, liberi $(human "$(vg_field "$vg" vg_free)"))")
    done < <(lvs --noheadings --units b --nosuffix --separator '|' -o lv_path,lv_size,vg_name,lv_attr 2>/dev/null)
    if (( ${#items[@]} == 0 )); then
        ui_msg "$title" "Nessun volume logico trovato${only_vg:+ nel gruppo $only_vg}."
        return 0
    fi
    lv=$(ui_menu "$title" "Seleziona il volume logico da espandere:" "${items[@]}") || return 0
    vg=$(trim "$(lvs --noheadings -o vg_name "$lv" 2>/dev/null)")
    lvsize=$(trim "$(lvs --noheadings --units b --nosuffix -o lv_size "$lv" 2>/dev/null)")
    vgfree=$(vg_field "$vg" vg_free)
    ext=$(vg_field "$vg" vg_extent_size)
    if ! [[ $vgfree =~ ^[0-9]+$ && $ext =~ ^[0-9]+$ ]] || (( vgfree < ext )); then
        ui_msg "$title" "Il gruppo di volumi \"$vg\" non ha spazio libero.\n\nPer aggiungere spazio puoi:\n • espandere la partizione che contiene il volume fisico (menu \"Espandi una partizione\");\n • aggiungere una partizione o un disco al gruppo (menu LVM → \"Aggiungi una partizione\")."
        return 0
    fi
    while :; do
        ans=$(ui_input "$title" "Volume logico: $lv\nDimensione attuale: $(human "$lvsize")\nSpazio libero nel gruppo $vg: $(human "$vgfree")\n\nQuanto spazio vuoi aggiungere?\n  max  → tutto lo spazio libero\n  10G  → aggiungi 10 GiB\n(unità accettate: M, G, T)" "max") || return 0
        ans=$(trim "${ans,,}")
        ans=${ans#+}
        if [[ $ans == max || $ans == tutto || $ans == 100% ]]; then
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
        ui_msg "$title" "Valore non valido: indica una quantità tra $(human "$ext") e $(human "$vgfree"), oppure max."
    done
    ui_yesno "$title" "Riepilogo:\n\n  Volume logico: $lv\n  Dimensione:    $(human "$lvsize") → $(human $(( lvsize + bytes )))\n  Contenuto:     $(fs_type "$lv")\n\nAnche il file system verrà espanso. Procedere?" || return 0
    screen_start "$title"
    critical_begin
    if run lvextend "${args[@]}" "$lv"; then
        ok "Volume logico $lv espanso."
        grow_contents "$lv"
    else
        err "lvextend non riuscito."
    fi
    critical_end
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$lv" >&2 2>/dev/null
}

lvm_add_pv() {
    local title="Aggiungi spazio a un gruppo di volumi" vgs_list=() items=() v disk part t pvvg vg
    ensure_cmds pvcreate vgextend vgs pvs || return 0
    mapfile -t vgs_list < <(vgs --noheadings -o vg_name 2>/dev/null | awk 'NF { print $1 }')
    if (( ${#vgs_list[@]} == 0 )); then
        ui_msg "$title" "Nessun gruppo di volumi LVM trovato su questo sistema."
        return 0
    fi
    disk=$(select_disk "$title" "Seleziona il disco che contiene la partizione da aggiungere:") || return 0
    part=$(select_partition "$disk" "$title" "Seleziona la partizione da aggiungere al gruppo di volumi.\nATTENZIONE: il suo contenuto attuale verrà cancellato.") || return 0
    if dev_in_use "$part"; then
        ui_msg "$title" "La partizione $part è in uso (montata, swap attiva o usata da LVM/LUKS): non può essere aggiunta."
        return 0
    fi
    t=$(fs_type "$part")
    if [[ $t == LVM2_member ]]; then
        pvvg=$(trim "$(pvs --noheadings -o vg_name "$part" 2>/dev/null)")
        if [[ -n $pvvg ]]; then
            ui_msg "$title" "La partizione $part fa già parte del gruppo di volumi \"$pvvg\"."
            return 0
        fi
    fi
    for v in "${vgs_list[@]}"; do
        items+=("$v" "liberi $(human "$(vg_field "$v" vg_free)") su $(human "$(vg_field "$v" vg_size)")")
    done
    vg=$(ui_menu "$title" "A quale gruppo di volumi vuoi aggiungere $part?" "${items[@]}") || return 0
    if [[ -n $t && $t != LVM2_member ]]; then
        ui_confirm_typed "$title" "La partizione $part contiene: $t.\nTutti i dati presenti verranno CANCELLATI." "$(basename "$part")" || return 0
    else
        ui_yesno "$title" "Aggiungere $part ($(human "$(dev_bytes "$part")")) al gruppo di volumi \"$vg\"?" || return 0
    fi
    screen_start "$title"
    critical_begin
    if [[ $t != LVM2_member ]]; then
        if ! { run wipefs -a "$part" && run pvcreate "$part"; }; then
            critical_end
            err "Creazione del volume fisico non riuscita."
            pause
            return 0
        fi
    fi
    if run vgextend "$vg" "$part"; then
        ok "$part aggiunta al gruppo di volumi $vg."
        critical_end
        pause_if_tui
        if ui_yesno "$title" "Vuoi assegnare subito il nuovo spazio a un volume logico?"; then
            lvm_extend "$vg"
        fi
    else
        critical_end
        err "vgextend non riuscito."
    fi
    pause
}

wizard_lvm() {
    local choice
    if ! command -v lvm >/dev/null 2>&1; then
        ensure_cmds lvm || return 0
    fi
    while :; do
        choice=$(ui_menu "LVM" "Gestione dei volumi logici (LVM):" \
            1 "Espandi un volume logico (e il suo file system)" \
            2 "Aggiungi una partizione a un gruppo di volumi" \
            3 "Mostra riepilogo LVM") || return 0
        case $choice in
            1) lvm_extend; pause ;;
            2) lvm_add_pv ;;
            3)
                screen_start "Riepilogo LVM"
                printf '\nVolumi fisici:\n' >&2;  pvs >&2 2>/dev/null
                printf '\nGruppi di volumi:\n' >&2; vgs >&2 2>/dev/null
                printf '\nVolumi logici:\n' >&2; lvs >&2 2>/dev/null
                pause
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Wizard
# -----------------------------------------------------------------------------

show_overview() {
    local d s e args=(-o "NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT") regions=() r gap
    (( PW_INCLUDE_LOOP )) || args+=(-e 7)
    [[ $PW_UI == whiptail && -t 1 ]] && clear
    ui_header "Dischi e partizioni"
    lsblk "${args[@]}" >&2
    ui_header "Spazio non allocato"
    for d in $(list_disks); do
        if ! load_table "$d"; then
            printf '%s (%s): nessuna tabella delle partizioni%s\n' "$d" "$(human "$(dev_bytes "$d")")" \
                "$(t=$(fs_type "$d"); [[ -n $t ]] && printf ', contiene direttamente %s' "$t")" >&2
            continue
        fi
        printf '%s (%s, %s):\n' "$d" "$(human "$(dev_bytes "$d")")" "${T_LABEL^^}" >&2
        mapfile -t regions < <(free_regions)
        if (( ${#regions[@]} == 0 )); then
            printf '    nessuno spazio libero\n' >&2
        fi
        for r in "${regions[@]}"; do
            read -r s e <<<"$r"
            printf '    libero: %-12s (settori %s - %s)\n' "$(human $(( (e - s + 1) * T_SS )))" "$s" "$e" >&2
        done
        gap=$(gpt_tail_gap)
        if (( gap >= MIB )); then
            printf '    %s%s alla fine del disco non sono ancora utilizzabili: usa "Rileva il nuovo spazio".%s\n' \
                "$C_YELLOW" "$(human "$gap")" "$C_RESET" >&2
        fi
    done
    if command -v vgs >/dev/null 2>&1 && [[ -n $(vgs --noheadings 2>/dev/null) ]]; then
        ui_header "Gruppi di volumi LVM"
        vgs >&2 2>/dev/null
        printf '\n' >&2
        lvs >&2 2>/dev/null
    fi
    [[ $PW_MODE == list ]] || pause
}

wizard_expand() {
    local title="Espandi partizione" disk part nr i start cur_end max_end free t mnt ans cur new_size j next=""
    disk=$(select_disk "$title" "Seleziona il disco che contiene la partizione da espandere:") || return 0
    screen_start "$title"
    prepare_disk_growth "$disk"
    (( PW_DISK_CHANGED )) && pause_if_tui

    if ! load_table "$disk"; then
        t=$(fs_type "$disk")
        if [[ -n $t ]]; then
            if ui_yesno "$title" "Il disco $disk non ha partizioni ma contiene direttamente: $t.\n\nVuoi espandere il contenuto per occupare l'intero disco ($(human "$(dev_bytes "$disk")"))?"; then
                screen_start "$title"
                critical_begin
                grow_contents "$disk"
                critical_end
                show_disk "$disk"
                pause
            fi
        else
            ui_msg "$title" "Il disco $disk non contiene né una tabella delle partizioni né un file system.\nUsa \"Crea una nuova partizione\"."
        fi
        return 0
    fi

    part=$(select_partition "$disk" "$title" "Seleziona la partizione da espandere:") || return 0
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
        local why="Non c'è spazio non allocato subito dopo $part: la partizione non può essere ingrandita."
        if [[ -n $next ]]; then
            if is_extended_idx "$next"; then
                why+="\n\nSubito dopo si trova la partizione estesa n. ${T_NR[next]} (con le partizioni logiche, spesso la swap). Per ingrandire $part dovresti prima eliminare le partizioni che la seguono."
            else
                why+="\n\nSubito dopo si trova $(part_dev "$disk" "${T_NR[next]}") ($(fs_type "$(part_dev "$disk" "${T_NR[next]}")")). Per ingrandire $part dovresti prima eliminarla (se non serve) o spostarla con uno strumento come GParted da una live USB."
            fi
        fi
        if [[ -n $t ]]; then
            if ui_yesno "$title" "$why\n\nSe la partizione è già stata ingrandita in precedenza, posso comunque espandere il suo contenuto ($t) per occupare tutta la partizione.\n\nVuoi farlo ora?" no; then
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
        ans=$(ui_input "$title" "Partizione: $part (${t:-nessun file system})\nDimensione attuale: $(human "$cur")\nSpazio libero subito dopo: $(human "$free")\nDimensione massima: $(human $(( (max_end - start + 1) * T_SS )))\n\nInserisci la nuova dimensione:\n  max   → usa tutto lo spazio libero\n  50G   → dimensione totale di 50 GiB\n  +10G  → aggiungi 10 GiB\n(unità accettate: M, G, T)" "max") || return 0
        compute_end "$ans" "$start" "$cur_end" "$max_end" grow && break
        ui_msg "$title" "$SIZE_ERR"
    done
    new_size=$(( (NEW_END - start + 1) * T_SS ))

    ui_yesno "$title" "Riepilogo dell'operazione:\n\n  Disco:       $disk\n  Partizione:  $part\n  Contenuto:   ${t:-nessuno}${mnt:+ (montato su $mnt)}\n  Dimensione:  $(human "$cur") → $(human "$new_size")\n\nVerranno espansi la partizione e il suo contenuto (LUKS, LVM, file system). L'operazione si può eseguire anche con la partizione in uso.\nPrima della modifica viene salvato un backup della tabella delle partizioni.\n\nProcedere?" || return 0

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
    local title="Riduci partizione" disk part nr i start cur_end cur t mnt min suggested ans new_size
    local unmounted="" tmp="" devid=1 was_swap=0
    disk=$(select_disk "$title" "Seleziona il disco che contiene la partizione da ridurre:") || return 0
    part=$(select_partition "$disk" "$title" "Seleziona la partizione da ridurre:") || return 0
    nr=$(part_nr "$part")
    i=$(tbl_idx "$nr") || return 0
    start=${T_START[i]}
    cur_end=$(( start + T_SIZE[i] - 1 ))
    cur=$(( T_SIZE[i] * T_SS ))
    t=$(fs_type "$part")

    case $t in
        ext2 | ext3 | ext4 | btrfs | ntfs | swap) ;;
        "")
            ui_yesno "$title" "La partizione $part non contiene un file system riconosciuto.\nLa riduzione cancellerà definitivamente qualsiasi dato presente nella parte finale.\n\nContinuare?" no || return 0
            ;;
        xfs)
            ui_msg "$title" "Il file system XFS non può essere ridotto.\n\nL'unica alternativa è copiare i dati altrove, ricreare una partizione più piccola e ripristinarli."
            return 0
            ;;
        LVM2_member)
            ui_msg "$title" "$part è un volume fisico LVM: la riduzione automatica non è supportata.\n\nOccorre ridurre prima i volumi logici (lvreduce -r), poi il volume fisico (pvresize --setphysicalvolumesize) e solo alla fine la partizione."
            return 0
            ;;
        crypto_LUKS)
            ui_msg "$title" "$part è un volume cifrato LUKS: la riduzione automatica non è supportata."
            return 0
            ;;
        *)
            ui_msg "$title" "La riduzione del file system \"$t\" non è supportata."
            return 0
            ;;
    esac

    if [[ -n $(dev_holders "$part") ]]; then
        ui_msg "$title" "La partizione $part è utilizzata da $(dev_child "$part"): impossibile ridurla."
        return 0
    fi

    # ext2/3/4 e NTFS si possono ridurre solo da smontati; btrfs anche da montato.
    mnt=$(mountpoint_of "$part")
    if [[ -n $mnt && $t != btrfs && $t != swap ]]; then
        if [[ $mnt == / || $mnt == /usr || $mnt == /var || $mnt == /boot ]]; then
            ui_msg "$title" "La partizione $part è montata su $mnt ed è necessaria al sistema in esecuzione: non può essere smontata.\n\nPer ridurla avvia il computer da una live USB (es. Ubuntu o Fedora live) ed esegui questo script da lì."
            return 0
        fi
        ui_yesno "$title" "La partizione $part è montata su $mnt.\nPer ridurre un file system $t è necessario smontarlo.\n\nSmontarlo ora? (Verrà rimontato al termine.)" || return 0
        screen_start "$title"
        if ! run umount "$mnt"; then
            pause_if_tui
            ui_msg "$title" "Impossibile smontare $mnt: chiudi i programmi che lo stanno usando e riprova."
            return 0
        fi
        unmounted=$mnt
    fi
    if [[ $t == swap ]] && swap_active "$part"; then
        was_swap=1
    fi

    screen_start "$title"
    info "Calcolo dello spazio minimo necessario..."
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
        ui_msg "$title" "Impossibile determinare lo spazio minimo richiesto dal file system di $part."
        [[ -n $tmp ]] && temp_umount "$tmp"
        _shrink_restore_mount "$part" "$unmounted"
        return 0
    fi
    # margine: +10% sullo spazio minimo e 32 MiB per la riduzione in due passaggi
    suggested=$(( min + min / 10 + 32 * MIB ))
    suggested=$(( (suggested + MIB - 1) / MIB * MIB ))
    pause_if_tui

    if (( suggested >= cur - MIB )); then
        ui_msg "$title" "La partizione $part ($(human "$cur")) è già quasi piena: il file system richiede almeno $(human "$suggested").\nNon è possibile ridurla."
        [[ -n $tmp ]] && temp_umount "$tmp"
        _shrink_restore_mount "$part" "$unmounted"
        return 0
    fi

    while :; do
        ans=$(ui_input "$title" "Partizione: $part (${t:-nessun file system})\nDimensione attuale: $(human "$cur")\nDimensione minima consigliata: $(human "$suggested")\n\nInserisci la nuova dimensione:\n  20G   → dimensione totale di 20 GiB\n  -10G  → riduci di 10 GiB\n(unità accettate: M, G, T)" "") || {
            [[ -n $tmp ]] && temp_umount "$tmp"
            _shrink_restore_mount "$part" "$unmounted"
            return 0
        }
        compute_end "$ans" "$start" "$cur_end" "$cur_end" shrink "$suggested" && break
        ui_msg "$title" "$SIZE_ERR"
    done
    new_size=$(( (NEW_END - start + 1) * T_SS ))

    if ! ui_yesno "$title" "Riepilogo dell'operazione:\n\n  Disco:       $disk\n  Partizione:  $part (${t:-nessun file system})\n  Dimensione:  $(human "$cur") → $(human "$new_size")\n  Spazio che verrà liberato: $(human $(( cur - new_size )))\n\nATTENZIONE: la riduzione sposta i dati all'interno del file system. Un'interruzione (es. mancanza di corrente) può causare la perdita dei dati. Assicurati di avere un backup.\n\nProcedere?" no; then
        [[ -n $tmp ]] && temp_umount "$tmp"
        _shrink_restore_mount "$part" "$unmounted"
        return 0
    fi

    screen_start "$title"
    critical_begin
    if op_shrink "$disk" "$nr" "$NEW_END"; then
        ok "Riduzione completata: $(human $(( cur - new_size ))) ora sono non allocati e puoi usarli con \"Crea una nuova partizione\"."
    else
        err "La riduzione non è stata completata. Controlla i messaggi qui sopra."
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
    fi || warn "Impossibile rimontare $part su $mnt."
}

wizard_create() {
    local title="Crea partizione" disk sigs label_type regions=() items=() r s e k n primaries=0
    local ans fs fslabel maxlen part fsitems vgs_list=() v vg
    disk=$(select_disk "$title" "Seleziona il disco su cui creare la partizione:") || return 0

    if ! load_table "$disk"; then
        if disk_in_use "$disk"; then
            ui_msg "$title" "Il disco $disk non ha una tabella delle partizioni ma è in uso (montato, swap o LVM): impossibile continuare."
            return 0
        fi
        sigs=$(fs_type "$disk")
        label_type=$(UI_NOTAGS=1 ui_menu "$title" "Il disco $disk non ha una tabella delle partizioni.\nScegli il tipo di tabella da creare:" \
            gpt "GPT (consigliata: dischi moderni, UEFI, oltre 2 TiB)" \
            dos "MBR/DOS (compatibilità con vecchi BIOS, max 2 TiB)") || return 0
        if [[ -n $sigs ]]; then
            ui_confirm_typed "$title" "Il disco $disk contiene: $sigs.\nCreando una nuova tabella delle partizioni TUTTI I DATI DEL DISCO ANDRANNO PERSI." "$(basename "$disk")" || return 0
        else
            ui_yesno "$title" "Creare una tabella delle partizioni $label_type vuota su $disk ($(human "$(dev_bytes "$disk")"))?" || return 0
        fi
        screen_start "$title"
        run_input "label: $label_type" sfdisk --wipe always "$disk" || { pause; return 0; }
        reread_table "$disk"
        pause_if_tui
        if (( PW_DRY_RUN )); then
            ui_msg "$title" "Simulazione: la tabella non è stata creata davvero, quindi non posso proseguire con la creazione della partizione."
            return 0
        fi
        load_table "$disk" || { ui_msg "$title" "Creazione della tabella non riuscita."; return 0; }
    else
        screen_start "$title"
        prepare_disk_growth "$disk"
        (( PW_DISK_CHANGED )) && pause_if_tui
    fi

    if [[ $T_LABEL == dos ]]; then
        for k in "${T_NR[@]}"; do (( k <= 4 )) && primaries=$(( primaries + 1 )); done
        if (( primaries >= 4 )); then
            ui_msg "$title" "Il disco $disk usa una tabella MBR e ha già 4 partizioni primarie (o estese): non è possibile crearne altre.\n\nConsiglio: elimina una partizione non necessaria oppure, se il disco è vuoto, ricrealo con tabella GPT."
            return 0
        fi
    fi

    mapfile -t regions < <(free_regions)
    if (( ${#regions[@]} == 0 )); then
        ui_msg "$title" "Non c'è spazio non allocato su $disk.\n\nPuoi liberarne riducendo o eliminando una partizione."
        return 0
    fi
    n=1
    for r in "${regions[@]}"; do
        read -r s e <<<"$r"
        items+=("$n" "$(human $(( (e - s + 1) * T_SS )))  libero (settori $s - $e)")
        n=$(( n + 1 ))
    done
    if (( ${#regions[@]} == 1 )); then
        k=1
    else
        k=$(ui_menu "$title" "Seleziona lo spazio libero da usare:" "${items[@]}") || return 0
    fi
    read -r s e <<<"${regions[k - 1]}"

    while :; do
        ans=$(ui_input "$title" "Spazio libero selezionato: $(human $(( (e - s + 1) * T_SS )))\n\nDimensione della nuova partizione:\n  max  → tutto lo spazio libero\n  20G  → 20 GiB\n(unità accettate: M, G, T)" "max") || return 0
        compute_end "$ans" "$s" "$s" "$e" create && break
        ui_msg "$title" "$SIZE_ERR"
    done

    fsitems=(ext4 "ext4   — file system Linux (consigliato)"
        xfs "xfs    — file system Linux per grandi volumi (non riducibile)"
        btrfs "btrfs  — file system Linux con snapshot"
        vfat "FAT32  — compatibile con Windows/macOS, chiavette, partizioni EFI"
        ntfs "NTFS   — file system di Windows"
        swap "swap   — area di scambio"
        lvm "LVM    — volume fisico per LVM"
        none "nessuno — crea solo la partizione")
    fs=$(UI_NOTAGS=1 ui_menu "$title" "Come vuoi formattare la nuova partizione?" "${fsitems[@]}") || return 0

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
            fslabel=$(ui_input "$title" "Etichetta (nome) del file system, massimo $maxlen caratteri.\nLascia vuoto per nessuna etichetta." "") || return 0
            fslabel=$(trim "$fslabel")
            [[ $fs == vfat ]] && fslabel=${fslabel^^}
            if (( ${#fslabel} > maxlen )); then
                ui_msg "$title" "Etichetta troppo lunga (massimo $maxlen caratteri)."
                continue
            fi
            if [[ $fslabel == *[\"\'\\]* ]]; then
                ui_msg "$title" "L'etichetta non può contenere virgolette o barre rovesciate."
                continue
            fi
            break
        done
    fi

    ui_yesno "$title" "Riepilogo dell'operazione:\n\n  Disco:        $disk (${T_LABEL^^})\n  Dimensione:   $(human $(( (NEW_END - s + 1) * T_SS )))\n  Settori:      $s - $NEW_END\n  File system:  $fs\n  Etichetta:    ${fslabel:-(nessuna)}\n\nLe partizioni esistenti non verranno modificate.\n\nProcedere?" || return 0

    screen_start "$title"
    critical_begin
    if ! op_create "$disk" "$s" "$NEW_END" "$fs" "$fslabel"; then
        critical_end
        err "Creazione della partizione non riuscita."
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
                    for v in "${vgs_list[@]}"; do items+=("$v" "liberi $(human "$(vg_field "$v" vg_free)")"); done
                    if vg=$(ui_menu "$title" "Vuoi aggiungere il nuovo volume fisico $part a un gruppo di volumi esistente?\n(Indietro = no)" "${items[@]}"); then
                        screen_start "$title"
                        if run vgextend "$vg" "$part"; then
                            ok "$part aggiunta al gruppo di volumi $vg."
                            pause_if_tui
                            ui_yesno "$title" "Vuoi assegnare subito il nuovo spazio a un volume logico?" && lvm_extend "$vg"
                        fi
                    fi
                fi
            fi
            ;;
    esac
    pause
}

wizard_delete() {
    local title="Elimina partizione" disk part nr i t="" mnt="" is_ext=0 k swap_on=0
    local fstab_lines=() crypt_lines=() warnmsg="" wipe=1
    disk=$(select_disk "$title" "Seleziona il disco che contiene la partizione da eliminare:") || return 0
    part=$(select_partition "$disk" "$title" "Seleziona la partizione da ELIMINARE:" 1) || return 0
    nr=$(part_nr "$part")
    i=$(tbl_idx "$nr") || return 0
    is_extended_idx "$i" && is_ext=1

    if (( is_ext )); then
        for k in "${T_NR[@]}"; do
            if (( k >= 5 )); then
                ui_msg "$title" "La partizione estesa $part contiene ancora partizioni logiche: eliminale prima."
                return 0
            fi
        done
        t="partizione estesa (vuota)"
        wipe=0
    else
        t=$(fs_type "$part")
        mnt=$(mountpoint_of "$part")
        case $mnt in
            / | /boot | /boot/efi | /efi | /usr | /var | /home)
                ui_msg "$title" "La partizione $part è montata su $mnt ed è usata dal sistema: non può essere eliminata."
                return 0
                ;;
        esac
        if [[ -n $(dev_holders "$part") ]]; then
            if [[ $t == LVM2_member ]]; then
                ui_msg "$title" "La partizione $part è un volume fisico LVM in uso ($(dev_child "$part")).\nRimuovila prima dal gruppo di volumi (pvmove + vgreduce)."
            else
                ui_msg "$title" "La partizione $part è in uso da $(dev_child "$part") (es. volume cifrato aperto o RAID): chiudilo prima di eliminarla."
            fi
            return 0
        fi
        swap_active "$part" && swap_on=1
        [[ -n $mnt ]] && warnmsg+="\n• È montata su $mnt: verrà smontata."
        (( swap_on )) && warnmsg+="\n• È una swap attiva: verrà disattivata."
        mapfile -t fstab_lines < <(config_refs "$part" /etc/fstab 1)
        [[ $t == crypto_LUKS ]] && mapfile -t crypt_lines < <(config_refs "$part" /etc/crypttab 2)
        (( ${#fstab_lines[@]} )) && warnmsg+="\n• È citata in /etc/fstab: le righe verranno commentate per evitare problemi all'avvio."
        (( ${#crypt_lines[@]} )) && warnmsg+="\n• È citata in /etc/crypttab: le righe verranno commentate."
        [[ $t == swap ]] && warnmsg+="\n• Se era usata per l'ibernazione, rimuovi anche il riferimento \"resume\" (es. /etc/initramfs-tools/conf.d/resume o i parametri del kernel)."
    fi
    if [[ $T_LABEL == dos ]] && (( nr >= 5 )); then
        for k in "${T_NR[@]}"; do
            if (( k > nr )); then
                warnmsg+="\n• Le partizioni logiche successive verranno rinumerate (es. $(part_dev "$disk" "$k") → $(part_dev "$disk" $(( k - 1 ))))."
                break
            fi
        done
    fi

    ui_confirm_typed "$title" "Stai per ELIMINARE la partizione $part ($(human $(( T_SIZE[i] * T_SS ))), contenuto: ${t:-sconosciuto}).\nTUTTI I DATI CHE CONTIENE ANDRANNO PERSI.$warnmsg" "$(basename "$part")" || return 0

    screen_start "$title"
    if [[ -n $mnt ]] && ! run umount "$mnt"; then
        err "Impossibile smontare $mnt: chiudi i programmi che lo stanno usando e riprova."
        pause
        return 0
    fi
    if (( swap_on )) && ! run swapoff "$part"; then
        err "Impossibile disattivare la swap $part."
        pause
        return 0
    fi
    critical_begin
    if op_delete "$disk" "$nr" "$wipe"; then
        (( ${#fstab_lines[@]} )) && comment_config_lines /etc/fstab "${fstab_lines[@]}" && systemd_reload
        (( ${#crypt_lines[@]} )) && comment_config_lines /etc/crypttab "${crypt_lines[@]}"
    else
        err "Eliminazione non riuscita."
    fi
    critical_end
    show_disk "$disk"
    pause
}

wizard_rescan() {
    local title="Rileva nuovo spazio" disk regions=() r s e
    disk=$(select_disk "$title" "Seleziona il disco che hai ingrandito (ad esempio dal pannello di gestione della macchina virtuale):") || return 0
    screen_start "$title"
    prepare_disk_growth "$disk"
    printf '\n' >&2
    if load_table "$disk"; then
        mapfile -t regions < <(free_regions)
        if (( ${#regions[@]} == 0 )); then
            info "Nessuno spazio non allocato su $disk ($(human "$(dev_bytes "$disk")"))."
        fi
        for r in "${regions[@]}"; do
            read -r s e <<<"$r"
            info "Spazio non allocato su $disk: $(human $(( (e - s + 1) * T_SS ))) (settori $s - $e)"
        done
        info "Ora puoi usare \"Espandi una partizione\" o \"Crea una nuova partizione\"."
    else
        info "$disk: $(human "$(dev_bytes "$disk")"), nessuna tabella delle partizioni."
    fi
    show_disk "$disk"
    pause
}

wizard_restore() {
    local title="Ripristina tabella" files=() items=() f tag dev
    mapfile -t files < <(ls -1t "$PW_BACKUP_DIR"/*.sfdisk 2>/dev/null)
    if (( ${#files[@]} == 0 )); then
        ui_msg "$title" "Nessun backup trovato in $PW_BACKUP_DIR."
        return 0
    fi
    for f in "${files[@]}"; do
        dev=$(awk -F': *' '/^device:/ { print $2; exit }' "$f")
        items+=("$(basename "$f")" "disco ${dev:-?}")
    done
    tag=$(ui_menu "$title" "Backup disponibili (dal più recente):" "${items[@]}") || return 0
    f="$PW_BACKUP_DIR/$tag"
    dev=$(awk -F': *' '/^device:/ { print $2; exit }' "$f")
    if [[ ! -b $dev ]]; then
        ui_msg "$title" "Il disco $dev indicato nel backup non esiste."
        return 0
    fi
    if disk_in_use "$dev"; then
        ui_msg "$title" "Il disco $dev è in uso (partizioni montate, swap o LVM/LUKS attivi).\n\nPer sicurezza il ripristino è consentito solo su dischi non in uso: avvia da una live USB oppure smonta le partizioni.\n\nIn alternativa, manualmente:\n  sfdisk $dev < $f"
        return 0
    fi
    ui_confirm_typed "$title" "La tabella delle partizioni di $dev verrà sostituita con:\n\n$(sed -n '/^\//p' "$f")\n\nI dati delle partizioni non vengono toccati, ma una tabella sbagliata può renderli inaccessibili." "$(basename "$dev")" || return 0
    screen_start "$title"
    backup_table "$dev"
    run_input "$(<"$f")" sfdisk "$dev" && ok "Tabella ripristinata."
    reread_table "$dev"
    show_disk "$dev"
    pause
}

welcome() {
    local extra=""
    (( PW_DRY_RUN )) && extra="\n\n*** MODALITÀ SIMULAZIONE: nessuna modifica verrà applicata ai dischi ***"
    ui_msg "Partition Wizard $PW_VERSION" "Benvenuto! Questo wizard ti guida nell'espansione e nella modifica delle partizioni dei dischi.\n\nSistema: ${PW_DISTRO_NAME:-sconosciuto} (famiglia: ${PW_DISTRO:-sconosciuta})\n\nATTENZIONE: modificare le partizioni comporta sempre un rischio per i dati. Prima di continuare assicurati di avere un backup dei dati importanti.\n\n• Prima di ogni modifica la tabella delle partizioni viene salvata in $PW_BACKUP_DIR\n• Le operazioni vengono registrate in ${PW_LOG_FILE:-(registro disattivato)}$extra"
}

main_menu() {
    local choice title="Partition Wizard $PW_VERSION"
    (( PW_DRY_RUN )) && title+=" [SIMULAZIONE]"
    while :; do
        choice=$(UI_CANCEL="Esci" ui_menu "$title" "Cosa vuoi fare?" \
            1 "Visualizza dischi, partizioni e spazio libero" \
            2 "Espandi una partizione (e il suo file system)" \
            3 "Riduci una partizione" \
            4 "Crea una nuova partizione" \
            5 "Elimina una partizione" \
            6 "Gestisci LVM (volumi logici)" \
            7 "Rileva il nuovo spazio di un disco ingrandito" \
            8 "Ripristina una tabella delle partizioni da backup" \
            9 "Esci") || choice=9
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
    [[ $PW_UI == whiptail && -t 1 ]] && clear
    info "Arrivederci!"
}

# -----------------------------------------------------------------------------
# Avvio
# -----------------------------------------------------------------------------

usage() {
    cat <<EOF
Partition Wizard $PW_VERSION
Wizard interattivo per espandere, ridurre, creare ed eliminare partizioni su
distribuzioni basate su Debian (apt) o Fedora/RHEL (dnf).

Uso: partition-wizard.sh [opzioni]

Opzioni:
  -n, --dry-run        simulazione: mostra i comandi senza modificare nulla
  -t, --text           interfaccia testuale semplice (senza whiptail)
  -d, --distro NOME    forza la famiglia di distribuzione: debian | fedora
  -l, --list           mostra dischi, partizioni e spazio libero ed esce
      --install-deps   installa tutti gli strumenti necessari ed esce
  -y, --yes            installa le dipendenze senza chiedere conferma
      --include-loop   mostra anche i dispositivi loop (prove su file immagine)
  -h, --help           mostra questo aiuto
  -V, --version        mostra la versione

Esempi:
  curl -fsSL $PW_RAW_URL | sudo bash
  curl -fsSL $PW_RAW_URL | sudo bash -s -- --dry-run
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
                    *) die "Valore non valido per --distro: '${1:-}' (usa debian oppure fedora)." ;;
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
            *) die "Opzione sconosciuta: $1 (usa --help)" ;;
        esac
        shift
    done
}

require_root() {
    (( EUID == 0 )) && return 0
    if [[ -n $PW_SELF && -f $PW_SELF ]] && command -v sudo >/dev/null 2>&1; then
        info "Servono i privilegi di amministratore: riavvio con sudo..."
        exec sudo -- bash "$PW_SELF" "${PW_ARGS[@]}"
    fi
    die "Questo script deve essere eseguito come root, ad esempio: curl -fsSL $PW_RAW_URL | sudo bash"
}

init_log() {
    if ! { mkdir -p "$(dirname "$PW_LOG_FILE")" && touch "$PW_LOG_FILE"; } 2>/dev/null; then
        PW_LOG_FILE=""
    fi
    log "===== partition-wizard $PW_VERSION avviato (modo=$PW_MODE simulazione=$PW_DRY_RUN) ====="
}

choose_distro() {
    [[ -n $PW_DISTRO ]] && return 0
    local c
    c=$(ui_menu "Distribuzione" "Non riesco a riconoscere la distribuzione (${PW_DISTRO_NAME:-sconosciuta}).\nScegli il gestore di pacchetti da usare per installare gli strumenti mancanti:" \
        debian "Basata su Debian/Ubuntu (apt)" \
        fedora "Basata su Fedora/RHEL (dnf)") || c=""
    PW_DISTRO=$c
    [[ -n $PW_DISTRO ]] || warn "Nessun gestore di pacchetti: gli strumenti mancanti andranno installati a mano."
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
            show_overview
            return 0
            ;;
    esac

    # Il wizard ha bisogno di un terminale: se lo script arriva da una pipe
    # (curl | bash) lo standard input viene ricollegato al terminale.
    if [[ ! -t 0 ]]; then
        { exec 0</dev/tty; } 2>/dev/null || die "Serve un terminale interattivo per usare il wizard."
    fi

    choose_distro
    ensure_cmds "${PW_CORE_CMDS[@]}" || die "Impossibile continuare senza gli strumenti di base."
    if (( ! PW_NO_TUI )) && ! command -v whiptail >/dev/null 2>&1 && [[ -n $PW_DISTRO ]] && (( ! PW_DRY_RUN )); then
        if ui_yesno "Interfaccia" "Per un'interfaccia più comoda (menu e finestre) posso installare whiptail.\nVuoi installarlo? (Altrimenti verrà usata l'interfaccia testuale semplice.)"; then
            install_pkgs "$(pkg_for_cmd whiptail)" || warn "Installazione di whiptail non riuscita: uso l'interfaccia testuale."
        fi
    fi
    init_sfdisk_opts || exit 1
    ui_init
    welcome
    main_menu
}

# Con PW_NO_MAIN=1 lo script può essere incluso (source) senza avviare il
# wizard, ad esempio dai test automatici.
[[ -n ${PW_NO_MAIN:-} ]] || { main "$@"; exit $?; }

#!/usr/bin/env bash
# =============================================================================
#  Test automatici di partition-wizard.sh
#
#  Creano dischi virtuali (file immagine + dispositivi loop) e verificano le
#  operazioni reali: creazione, espansione, riduzione ed eliminazione di
#  partizioni con vari file system, GPT dopo l'ingrandimento del disco,
#  partizioni logiche MBR, LVM e alcuni percorsi completi del wizard in
#  modalità testuale.
#
#  Uso (come root):  sudo tests/run-tests.sh
#  Non tocca i dischi reali: lavora solo sui dispositivi loop che crea.
# =============================================================================

set -o pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../partition-wizard.sh"

if (( EUID != 0 )); then
    echo "I test devono essere eseguiti come root (servono i dispositivi loop)." >&2
    exit 1
fi

WORK=$(mktemp -d /tmp/pw-tests.XXXXXX)
LOOPS=()
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
    local l m
    for m in $(findmnt -rn -o TARGET | grep -E "^($WORK|/tmp/partition-wizard\.)" | sort -r); do
        umount "$m" 2>/dev/null
    done
    if command -v vgs >/dev/null 2>&1; then
        vgchange -an pwtestvg >/dev/null 2>&1
        vgremove -f pwtestvg >/dev/null 2>&1
    fi
    for l in "${LOOPS[@]}"; do
        swapoff "$l"* 2>/dev/null
        losetup -d "$l" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup_tests EXIT

# --- helper -------------------------------------------------------------------

pass() { PASS=$(( PASS + 1 )); printf '\e[32mPASS\e[0m %s\n' "$*"; }
fail() { FAIL=$(( FAIL + 1 )); printf '\e[31mFAIL\e[0m %s\n' "$*"; }
skip() { SKIP=$(( SKIP + 1 )); printf '\e[33mSKIP\e[0m %s\n' "$*"; }

check() {   # descrizione comando...
    local desc=$1
    shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}

not() { ! "$@"; }

# Il file system occupa la partizione (a meno dell'arrotondamento al blocco)
fills() {   # byte_partizione byte_file_system
    (( $1 >= $2 && $1 - $2 < 65536 ))
}

check_eq() {   # descrizione atteso ottenuto
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (atteso '$2', ottenuto '$3')"; fi
}

new_disk() {   # dimensione -> stampa il dispositivo loop
    local img l
    img=$(mktemp "$WORK/disk.XXXXXX.img")
    truncate -s "$1" "$img"
    l=$(losetup -fP --show "$img") || return 1
    LOOPS+=("$l")
    printf '%s\n' "$l"
}

img_of() { losetup -nO BACK-FILE "$1"; }

# byte del file system ext2/3/4
ext_bytes() {
    local bc bs
    bc=$(dumpe2fs -h "$1" 2>/dev/null | awk -F': *' '/^Block count/ { print $2 }')
    bs=$(dumpe2fs -h "$1" 2>/dev/null | awk -F': *' '/^Block size/ { print $2 }')
    echo $(( bc * bs ))
}

mib() { echo $(( $1 * 1048576 )); }

sectors_for_mib() { echo $(( $1 * 2048 )); }   # settori da 512 byte

# Crea una partizione di N MiB nel primo spazio libero; stampa il dispositivo
create_part() {   # disco MiB fs [etichetta]
    local disk=$1 size=$2 fs=$3 label=${4:-} s
    load_table "$disk" || return 1
    read -r s _ < <(free_regions | head -n1)
    [[ -n $s ]] || return 1
    op_create "$disk" "$s" $(( s + $(sectors_for_mib "$size") - 1 )) "$fs" "$label" >/dev/null 2>&1 || return 1
    printf '%s\n' "$CREATED_PART"
}

part_end_of() {   # disco nr -> settore finale
    local i
    load_table "$1"
    i=$(tbl_idx "$2") || return 1
    echo $(( T_START[i] + T_SIZE[i] - 1 ))
}

# Settore finale per portare la partizione NR a SIZE MiB
end_for_size() {   # disco nr MiB
    local i
    load_table "$1"
    i=$(tbl_idx "$2") || return 1
    echo $(( T_START[i] + $(sectors_for_mib "$3") - 1 ))
}

# --- test unitari ------------------------------------------------------------

test_units() {
    echo "== Funzioni di base"
    check_eq "parse_size 20G" "$(( 20 * 1024 * 1048576 ))" "$(parse_size 20G)"
    check_eq "parse_size 1.5T" "$(( 3 * 512 * 1024 * 1048576 ))" "$(parse_size 1.5T)"
    check_eq "parse_size 2,5g" "$(( 5 * 512 * 1048576 ))" "$(parse_size 2,5g)"
    check_eq "parse_size 500MiB" "$(( 500 * 1048576 ))" "$(parse_size 500MiB)"
    check "parse_size rifiuta valori senza unità" not parse_size 123
    check "parse_size rifiuta testo" not parse_size abc
    check_eq "human 1 GiB" "1.00 GiB" "$(human 1073741824)"
    check_eq "human 512 B" "512 B" "$(human 512)"

    T_SS=512
    compute_end max 2048 4095 100000 grow
    check_eq "compute_end max" 100000 "$NEW_END"
    compute_end +1M 2048 4095 100000 grow
    check_eq "compute_end +1M" 6143 "$NEW_END"
    compute_end 10M 2048 4095 100000 grow
    check_eq "compute_end 10M" $(( 2048 + 20480 - 1 )) "$NEW_END"
    check "compute_end rifiuta oltre il massimo" not compute_end 100G 2048 4095 100000 grow
    check "compute_end rifiuta riduzioni in modalità grow" not compute_end 1M 2048 4095 100000 grow
    compute_end -1M 2048 8191 8191 shrink 0
    check_eq "compute_end -1M (riduzione)" 6143 "$NEW_END"
    check "compute_end rispetta il minimo in riduzione" not compute_end 1M 2048 8191 8191 shrink 2097152
}

# --- GPT: ext4, espansione, riduzione, eliminazione ---------------------------

test_gpt_ext4() {
    echo "== GPT + ext4"
    local d p p2 nr before after
    d=$(new_disk 1G) || { fail "creazione disco"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 200 ext4 DATI)
    check "creazione partizione ext4" test -b "$p"
    check_eq "file system ext4" ext4 "$(fs_type "$p")"
    check_eq "etichetta" DATI "$(fs_prop "$p" LABEL)"
    check_eq "dimensione partizione" "$(mib 200)" "$(dev_bytes "$p")"
    check "backup della tabella salvato" compgen -G "$PW_BACKUP_DIR/$(kname "$d")-*.sfdisk" >/dev/null

    nr=$(part_nr "$p")
    load_table "$d"
    check_eq "part_max_end arriva a fine disco" "$T_LAST" "$(part_max_end "$nr")"
    echo "ciao" >"$WORK/marker"
    mkdir -p "$WORK/m" && mount "$p" "$WORK/m" && cp "$WORK/marker" "$WORK/m/" && umount "$WORK/m"

    # espansione a 300 MiB (file system smontato)
    set_part_end "$d" "$nr" "$(end_for_size "$d" "$nr" 300)" >/dev/null 2>&1
    check_eq "espansione partizione a 300 MiB" "$(mib 300)" "$(dev_bytes "$p")"
    grow_contents "$p" >/dev/null 2>&1
    check_eq "file system espanso a 300 MiB" "$(mib 300)" "$(ext_bytes "$p")"

    # espansione "max"
    load_table "$d"
    set_part_end "$d" "$nr" "$(part_max_end "$nr")" >/dev/null 2>&1 && grow_contents "$p" >/dev/null 2>&1
    load_table "$d"
    check "espansione max fino a fine disco" test "$(part_end_of "$d" "$nr")" -eq "$T_LAST"
    check "file system = partizione dopo max" fills "$(dev_bytes "$p")" "$(ext_bytes "$p")"

    # riduzione a 150 MiB
    op_shrink "$d" "$nr" "$(end_for_size "$d" "$nr" 150)" >/dev/null 2>&1
    check_eq "riduzione partizione a 150 MiB" "$(mib 150)" "$(dev_bytes "$p")"
    check_eq "file system ridotto = partizione" "$(mib 150)" "$(ext_bytes "$p")"
    check "e2fsck pulito dopo la riduzione" e2fsck -f -n "$p" >/dev/null 2>&1
    mount "$p" "$WORK/m" && check "dati conservati dopo le modifiche" cmp -s "$WORK/marker" "$WORK/m/marker"
    umount "$WORK/m"

    # seconda partizione nello spazio liberato, poi eliminazione
    before=$(lsblk -lnpo NAME "$d" | wc -l)
    p2=$(create_part "$d" 50 none)
    check "creazione seconda partizione senza file system" test -b "$p2"
    op_delete "$d" "$(part_nr "$p2")" 1 >/dev/null 2>&1
    after=$(lsblk -lnpo NAME "$d" | wc -l)
    check_eq "eliminazione partizione" "$before" "$after"
    load_table "$d"
    check_eq "una sola partizione nella tabella" 1 "${#T_NR[@]}"
}

# --- espansione a caldo (file system montato) ---------------------------------

test_online_grow() {
    echo "== Espansione a caldo di ext4 montato"
    local d p nr
    d=$(new_disk 512M) || { fail "creazione disco"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 100 ext4)
    nr=$(part_nr "$p")
    mount "$p" "$WORK/m" || { fail "montaggio"; return; }
    set_part_end "$d" "$nr" "$(end_for_size "$d" "$nr" 200)" >/dev/null 2>&1
    check_eq "partizione montata espansa" "$(mib 200)" "$(dev_bytes "$p")"
    if grow_contents "$p" >/dev/null 2>&1; then
        check_eq "file system montato espanso" "$(mib 200)" "$(ext_bytes "$p")"
    else
        skip "ridimensionamento online di ext4 non consentito in questo ambiente"
    fi
    check "la partizione è rimasta montata" test "$(mountpoint_of "$p")" = "$WORK/m"
    umount "$WORK/m"
}

# --- riferimenti in /etc/fstab ---------------------------------------------------

test_fstab_refs() {
    echo "== Riferimenti in fstab"
    local d p uuid fake lines
    d=$(new_disk 256M) || { fail "creazione disco"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 64 ext4 REFTEST)
    uuid=$(fs_prop "$p" UUID)
    fake="$WORK/fstab"
    printf '%s\n' "# commento UUID=$uuid / ext4" "UUID=$uuid /dati ext4 defaults 0 2" \
        "LABEL=altro /altro ext4 defaults 0 2" "LABEL=REFTEST /ref ext4 defaults 0 2" \
        "$p /dev-path ext4 defaults 0 2" >"$fake"
    lines=$(config_refs "$p" "$fake" 1 | tr '\n' ' ')
    check_eq "righe che citano la partizione" "2 4 5 " "$lines"
    comment_config_lines "$fake" 2 4 5 >/dev/null 2>&1
    check_eq "righe commentate" 4 "$(grep -c '^#' "$fake")"
    check "riga non correlata intatta" grep -q '^LABEL=altro' "$fake"
    check "copia di sicurezza creata" compgen -G "$fake.partition-wizard-*.bak" >/dev/null
}

# --- GPT dopo l'ingrandimento del disco ---------------------------------------

test_gpt_disk_growth() {
    echo "== GPT dopo l'ingrandimento del disco (es. disco virtuale)"
    local d p nr gap
    d=$(new_disk 256M) || { fail "creazione disco"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    load_table "$d"
    p=$(create_part "$d" 200 ext4)
    nr=$(part_nr "$p")
    truncate -s 512M "$(img_of "$d")"
    losetup -c "$d"
    load_table "$d"
    gap=$(gpt_tail_gap)
    check "rilevato spazio oltre la fine della GPT" test "$gap" -ge "$(mib 200)"
    prepare_disk_growth "$d" >/dev/null 2>&1
    load_table "$d"
    check_eq "GPT estesa fino a fine disco" 0 "$(gpt_tail_gap)"
    set_part_end "$d" "$nr" "$(part_max_end "$nr")" >/dev/null 2>&1 && grow_contents "$p" >/dev/null 2>&1
    check "partizione espansa nel nuovo spazio" test "$(dev_bytes "$p")" -gt "$(mib 500)"
    check "file system espanso nel nuovo spazio" fills "$(dev_bytes "$p")" "$(ext_bytes "$p")"
}

# --- MBR con partizioni logiche ---------------------------------------------

test_mbr_logical() {
    echo "== MBR con partizione estesa e logica"
    local d p5 old
    d=$(new_disk 512M) || { fail "creazione disco"; return; }
    printf 'label: dos\nstart=2048, size=204800, type=83\nstart=206848, size=104448, type=5\nstart=208896, size=102400, type=83\n' |
        sfdisk -q "$d" >/dev/null 2>&1
    reread_table "$d"
    p5=$(part_dev "$d" 5)
    wait_for_dev "$p5"
    mkfs.ext4 -q "$p5"
    load_table "$d"
    old=$(part_max_end 5)
    check "logica estendibile oltre la partizione estesa" test "$old" -eq "$T_LAST"
    set_part_end "$d" 5 "$(end_for_size "$d" 5 150)" >/dev/null 2>&1
    check_eq "partizione logica espansa a 150 MiB" "$(mib 150)" "$(dev_bytes "$p5")"
    load_table "$d"
    check "partizione estesa ingrandita di conseguenza" test $(( T_START[1] + T_SIZE[1] - 1 )) -ge $(( T_START[2] + T_SIZE[2] - 1 ))
    grow_contents "$p5" >/dev/null 2>&1
    check_eq "file system della logica espanso" "$(mib 150)" "$(ext_bytes "$p5")"
    load_table "$d"
    mapfile -t regions < <(free_regions)
    check "spazio libero calcolato fuori dall'estesa" test "${#regions[@]}" -ge 1
}

# --- swap ----------------------------------------------------------------------

test_swap() {
    echo "== swap"
    local d p uuid nr
    d=$(new_disk 256M) || { fail "creazione disco"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 64 swap SWAPTEST)
    check_eq "swap creata" swap "$(fs_type "$p")"
    uuid=$(fs_prop "$p" UUID)
    nr=$(part_nr "$p")
    set_part_end "$d" "$nr" "$(end_for_size "$d" "$nr" 128)" >/dev/null 2>&1 && grow_contents "$p" >/dev/null 2>&1
    check_eq "swap espansa" "$(mib 128)" "$(dev_bytes "$p")"
    check_eq "UUID della swap conservato" "$uuid" "$(fs_prop "$p" UUID)"
    check_eq "etichetta della swap conservata" SWAPTEST "$(fs_prop "$p" LABEL)"
    op_shrink "$d" "$nr" "$(end_for_size "$d" "$nr" 32)" >/dev/null 2>&1
    check_eq "swap ridotta" "$(mib 32)" "$(dev_bytes "$p")"
    check_eq "UUID conservato dopo la riduzione" "$uuid" "$(fs_prop "$p" UUID)"
}

# --- xfs e btrfs (richiedono il montaggio) -------------------------------------

test_xfs() {
    echo "== xfs"
    local d p nr size
    if ! command -v mkfs.xfs >/dev/null; then skip "xfsprogs non installato"; return; fi
    d=$(new_disk 1G) || { fail "creazione disco"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 320 xfs)
    check_eq "xfs creato" xfs "$(fs_type "$p")"
    nr=$(part_nr "$p")
    set_part_end "$d" "$nr" "$(end_for_size "$d" "$nr" 512)" >/dev/null 2>&1
    if ! grow_contents "$p" >/dev/null 2>&1; then
        skip "xfs_growfs non consentito in questo ambiente"
        return
    fi
    mount "$p" "$WORK/m"
    size=$(df -B1 --output=size "$WORK/m" | tail -n1)
    umount "$WORK/m"
    check "xfs espanso (smontato: montaggio temporaneo)" test "$size" -gt "$(mib 400)"
}

test_btrfs() {
    echo "== btrfs"
    local d p nr total
    if ! command -v mkfs.btrfs >/dev/null; then skip "btrfs-progs non installato"; return; fi
    if ! grep -qw btrfs /proc/filesystems && ! modprobe btrfs 2>/dev/null; then
        skip "il kernel non supporta btrfs"
        return
    fi
    d=$(new_disk 1G) || { fail "creazione disco"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 400 btrfs)
    check_eq "btrfs creato" btrfs "$(fs_type "$p")"
    nr=$(part_nr "$p")
    set_part_end "$d" "$nr" "$(end_for_size "$d" "$nr" 600)" >/dev/null 2>&1
    if ! grow_contents "$p" >/dev/null 2>&1; then
        skip "ridimensionamento btrfs non consentito in questo ambiente"
        return
    fi
    mount "$p" "$WORK/m"
    total=$(btrfs filesystem show --raw "$WORK/m" | awk '/devid/ { print $4 }')
    check_eq "btrfs espanso" "$(mib 600)" "$total"
    umount "$WORK/m"
    op_shrink "$d" "$nr" "$(end_for_size "$d" "$nr" 300)" >/dev/null 2>&1
    check_eq "btrfs: partizione ridotta" "$(mib 300)" "$(dev_bytes "$p")"
    mount "$p" "$WORK/m"
    total=$(btrfs filesystem show --raw "$WORK/m" | awk '/devid/ { print $4 }')
    umount "$WORK/m"
    check_eq "btrfs: file system = partizione" "$(mib 300)" "$total"
}

# --- LVM -----------------------------------------------------------------------

test_lvm() {
    echo "== LVM"
    local d p nr lv
    if ! command -v lvm >/dev/null || ! dmsetup version >/dev/null 2>&1; then
        skip "LVM/device-mapper non disponibile"
        return
    fi
    d=$(new_disk 1G) || { fail "creazione disco"; return; }
    run_input "label: gpt" sfdisk -q "$d" >/dev/null 2>&1
    p=$(create_part "$d" 300 lvm)
    check_eq "volume fisico creato" LVM2_member "$(fs_type "$p")"
    vgcreate -q pwtestvg "$p" >/dev/null 2>&1
    lvcreate -q -y -L 200M -n data pwtestvg >/dev/null 2>&1
    lv=/dev/pwtestvg/data
    mkfs.ext4 -q "$lv"
    nr=$(part_nr "$p")
    set_part_end "$d" "$nr" "$(end_for_size "$d" "$nr" 600)" >/dev/null 2>&1
    # grow_contents: pvresize, poi il wizard propone di espandere un LV:
    # scelta 1 (unico LV del gruppo) e "max"
    grow_contents "$p" >/dev/null 2>&1 <<<$'1\nmax'
    check "volume fisico espanso" test "$(pvs --noheadings --units b --nosuffix -o pv_size "$p" | tr -d ' ')" -gt "$(mib 590)"
    check "volume logico espanso" test "$(dev_bytes "$lv")" -gt "$(mib 500)"
    check "file system del volume logico espanso" fills "$(dev_bytes "$lv")" "$(ext_bytes "$lv")"
    vgchange -an pwtestvg >/dev/null 2>&1
}

# --- percorsi completi del wizard (interfaccia testuale) -----------------------

disk_index() {   # numero del disco nel menu di selezione
    local i=1 x
    while read -r x; do
        [[ $x == "$1" ]] && { echo "$i"; return 0; }
        i=$(( i + 1 ))
    done < <(list_disks)
    return 1
}

test_wizard_flows() {
    echo "== Wizard completo (modalità testuale)"
    local d idx p
    d=$(new_disk 512M) || { fail "creazione disco"; return; }
    idx=$(disk_index "$d")
    # Crea: tabella GPT, partizione da 100M ext4 con etichetta, nessun montaggio
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
    check "wizard: tabella GPT creata" test "$(fs_prop "$d" PTTYPE)" = gpt
    check_eq "wizard: partizione creata da 100 MiB" "$(mib 100)" "$(dev_bytes "$p")"
    check_eq "wizard: ext4 con etichetta" "ext4 WIZ" "$(fs_type "$p") $(fs_prop "$p" LABEL)"

    # Espandi: +50M
    main_menu >"$WORK/flow2.log" 2>&1 <<EOF
2
$idx
1
+50M
9
EOF
    check_eq "wizard: partizione espansa di 50 MiB" "$(mib 150)" "$(dev_bytes "$p")"
    check_eq "wizard: file system espanso" "$(mib 150)" "$(ext_bytes "$p")"

    # Riduci: 80M
    main_menu >"$WORK/flow3.log" 2>&1 <<EOF
3
$idx
1
80M
9
EOF
    check_eq "wizard: partizione ridotta a 80 MiB" "$(mib 80)" "$(dev_bytes "$p")"
    check_eq "wizard: file system ridotto" "$(mib 80)" "$(ext_bytes "$p")"

    # Simulazione: nessuna modifica
    PW_DRY_RUN=1
    main_menu >"$WORK/flow4.log" 2>&1 <<EOF
2
$idx
1
max
9
EOF
    PW_DRY_RUN=0
    check_eq "wizard: la simulazione non modifica nulla" "$(mib 80)" "$(dev_bytes "$p")"
    check "wizard: la simulazione mostra i comandi" grep -q 'simulazione.*sfdisk' "$WORK/flow4.log"

    # Elimina una partizione montata (viene smontata dopo la conferma)
    mount "$p" "$WORK/m"
    main_menu >"$WORK/flow5.log" 2>&1 <<EOF
5
$idx
1
9
EOF
    load_table "$d"
    check_eq "wizard: partizione eliminata" 0 "${#T_NR[@]}"
    check "wizard: partizione smontata prima dell'eliminazione" not findmnt -n "$WORK/m"
}

# --- esecuzione ------------------------------------------------------------------

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
test_lvm
test_wizard_flows

echo
printf 'Risultato: %d superati, %d falliti, %d saltati\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))

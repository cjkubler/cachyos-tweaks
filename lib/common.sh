# shellcheck shell=bash
# Shared engine for Tweaks for CachyOS. Sourced by tweaks.sh; not
# executable on its own.
#
# A "tweak" is a unit of change with an id and five functions:
#   <id>_title       echo a one-line name
#   <id>_desc        echo a short multi-line description
#   <id>_applicable  return 0 if this hardware/system can use the tweak
#   <id>_status      echo one of: on | off | drifted | unmanaged
#   <id>_apply       apply it (root)
#   <id>_revert      undo it (root)
#
# State lives under /var/lib/cachyos-tweaks/<id>/. Managed-file helpers below
# save the pre-existing file (or its absence) on apply and restore it exactly
# on revert, refusing by default when live files were edited after apply.

: "${STATE_ROOT:=/var/lib/cachyos-tweaks}"
readonly STATE_ROOT
: "${MANAGED_OWNER_UID:=0}"
: "${MANAGED_OWNER_GID:=0}"
readonly MANAGED_OWNER_UID MANAGED_OWNER_GID

C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
[[ -t 1 ]] || { C_RESET=''; C_BOLD=''; C_DIM=''; C_GREEN=''; C_YELLOW=''; C_RED=''; }

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
msg()  { printf '%s\n' "$*"; }

# Run a mutation with errexit active even when its caller needs to inspect the
# exit status. Bash otherwise suppresses `set -e` throughout functions used in
# `if`, `!`, or `||` conditions, which can let later commands mask a failure.
run_failfast() (
    set -Eeuo pipefail
    "$@"
)

confirm() {
    local prompt=${1:-Proceed?}
    local answer
    printf '%s [y/N] ' "$prompt" >/dev/tty
    IFS= read -r answer </dev/tty || return 1
    [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]]
}

# Wait for a keypress so menu output is readable before redrawing.
pause() {
    local _
    printf '%s' "${C_DIM}Press Enter to continue...${C_RESET}" >/dev/tty
    IFS= read -r _ </dev/tty || true
}

need_root() {
    (( EUID == 0 )) ||
        die "this action needs root; run: sudo ${PROGRAM_COMMAND:-./$PROGRAM}"
}

require_cachyos() {
    [[ -r /etc/os-release ]] || die 'cannot identify the operating system'
    local ID=''
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == cachyos ]] || die 'this suite supports CachyOS only'
}

# ---------------------------------------------------------------------------
# Managed-file state
#
# Layout per tweak: $STATE_ROOT/<id>/
#   manifest             newline list of managed target paths
#   saved/<esc>          original content of a target that existed pre-apply
#   existed/<esc>        marker: target existed before apply; holds its
#                        original "mode owner group" so revert can restore
#                        them exactly instead of assuming 0644 root:root
#   managed/<esc>        readable SHA-256 of installed content (drift detection)
# ---------------------------------------------------------------------------

esc_path() { local p=${1#/}; printf '%s' "${p//\//__}"; }

tweak_dir() { printf '%s/%s' "$STATE_ROOT" "$1"; }

tweak_has_state() { [[ -d $(tweak_dir "$1") ]]; }

managed_validate_target() {
    local target=$1 allow_final_symlink=${2:-} parent canonical
    [[ "$target" == /* && "$target" != *$'\n'* && "$target" != *$'\r'* ]] ||
        die "managed target must be an absolute single-line path: $target"
    [[ "$target" != / ]] || die 'refusing to manage the filesystem root'
    canonical=$(realpath -ms -- "$target") ||
        die "cannot normalize managed target: $target"
    [[ "$target" == "$canonical" ]] ||
        die "managed target must be canonical: $target"
    [[ "$allow_final_symlink" == --allow-final-symlink || ! -L "$target" ]] ||
        die "refusing to replace a symlink: $target"
    parent=${target%/*}
    [[ -n "$parent" ]] || parent=/
    while [[ "$parent" != / ]]; do
        [[ ! -L "$parent" ]] || die "refusing a symlinked parent directory: $parent"
        parent=${parent%/*}
        [[ -n "$parent" ]] || parent=/
    done
}

managed_prepare_parent() {
    local id=$1 target=$2 dir parent probe
    dir=$(tweak_dir "$id")
    parent=${target%/*}
    [[ -n "$parent" ]] || parent=/
    [[ -d "$parent" ]] && return 0

    local -a missing=()
    probe=$parent
    while [[ ! -e "$probe" ]]; do
        missing+=("$probe")
        probe=${probe%/*}
        [[ -n "$probe" ]] || probe=/
    done
    [[ -d "$probe" && ! -L "$probe" ]] ||
        die "managed target parent is not a safe directory: $probe"
    install -d -m 0755 "$parent" || return 1
    install -d -m 0700 "$dir" || return 1
    local created
    for ((created = ${#missing[@]} - 1; created >= 0; created--)); do
        printf '%s\n' "${missing[created]}" >>"$dir/created-dirs" || return 1
    done
    chmod 0600 "$dir/created-dirs" || return 1
}

manifest_add() {
    local id=$1 target=$2 dir tmp
    dir=$(tweak_dir "$id")
    grep -qxF -- "$target" "$dir/manifest" 2>/dev/null && return 0
    tmp=$(mktemp "$dir/.manifest.XXXXXX") || return 1
    if [[ -f "$dir/manifest" ]]; then
        cat "$dir/manifest" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
    if ! printf '%s\n' "$target" >>"$tmp" ||
        ! chmod 0644 "$tmp" ||
        ! mv -fT -- "$tmp" "$dir/manifest"; then
        rm -f -- "$tmp"
        return 1
    fi
}

# Install content (from a source file) as a managed file, saving whatever was
# there first. The owned form is used for the U2F mapping, which must be
# readable only by its enrolled account.
managed_install_owned() {
    local id=$1 target=$2 mode=$3 installed_owner=$4 installed_group=$5 source=$6
    local dir e target_tmp hash_tmp installed_hash installed_metadata
    [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid managed state id: $id"
    [[ "$mode" =~ ^0?[0-7]{3,4}$ ]] || die "invalid managed file mode: $mode"
    [[ "$installed_owner" =~ ^[0-9]+$ && "$installed_group" =~ ^[0-9]+$ ]] ||
        die 'managed file owner and group must be numeric'
    [[ -f "$source" && ! -L "$source" ]] || die "managed source is not a regular file: $source"
    managed_validate_target "$target"
    dir=$(tweak_dir "$id"); e=$(esc_path "$target")
    managed_prepare_parent "$id" "$target" || return 1
    install -d -m 0711 "$dir" "$dir/managed" || return 1
    install -d -m 0700 "$dir/saved" "$dir/existed" "$dir/absent" || return 1
    if [[ ! -e "$dir/existed/$e" && ! -e "$dir/absent/$e" ]]; then
        # First touch of this path: preserve the original exactly, including
        # the mode/owner/group revert should restore it to.
        if [[ -e "$target" ]]; then
            local saved_tmp existed_tmp
            saved_tmp=$(mktemp "$dir/saved/.original.XXXXXX") || return 1
            existed_tmp=$(mktemp "$dir/existed/.metadata.XXXXXX") ||
                { rm -f -- "$saved_tmp"; return 1; }
            if ! install -m 0600 "$target" "$saved_tmp" ||
                ! stat -c '%a %u %g' "$target" >"$existed_tmp" ||
                ! chmod 0600 "$existed_tmp" ||
                ! mv -fT -- "$saved_tmp" "$dir/saved/$e"; then
                rm -f -- "$saved_tmp" "$existed_tmp"
                return 1
            fi
            # The metadata marker commits the backup. A retry after an
            # interruption therefore never mistakes installed content for
            # the original.
            mv -fT -- "$existed_tmp" "$dir/existed/$e" || return 1
        else
            : >"$dir/absent/$e" || return 1
            chmod 0600 "$dir/absent/$e" || return 1
        fi
    fi

    # Put the manifest in place before changing the live file. If execution
    # stops between later commits, revert can still find and restore the
    # recorded original.
    manifest_add "$id" "$target" || return 1

    target_tmp=$(mktemp "${target%/*}/.cachyos-tweaks.XXXXXX") || return 1
    if ! install -o "$installed_owner" -g "$installed_group" -m "$mode" \
        "$source" "$target_tmp" ||
        ! mv -fT -- "$target_tmp" "$target"; then
        rm -f -- "$target_tmp"
        return 1
    fi

    hash_tmp=$(mktemp "$dir/managed/.hash.XXXXXX") || return 1
    installed_hash=$(sha256sum "$target" | awk '{ print $1 }') ||
        { rm -f -- "$hash_tmp"; return 1; }
    installed_metadata=$(stat -c '%a %u %g' "$target") ||
        { rm -f -- "$hash_tmp"; return 1; }
    if ! printf '%s %s\n' "$installed_hash" "$installed_metadata" >"$hash_tmp" ||
        ! chmod 0644 "$hash_tmp" ||
        ! mv -fT -- "$hash_tmp" "$dir/managed/$e"; then
        rm -f -- "$hash_tmp"
        return 1
    fi
}

managed_install() {
    managed_install_owned "$1" "$2" "$3" \
        "$MANAGED_OWNER_UID" "$MANAGED_OWNER_GID" "$4"
}

# managed_write <id> <target> <mode>  — content on stdin
managed_write() {
    local id=$1 target=$2 mode=$3 tmp
    tmp=$(mktemp) || return 1
    if ! cat >"$tmp" || ! managed_install "$id" "$target" "$mode" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    rm -f -- "$tmp"
}

managed_write_owned() {
    local id=$1 target=$2 mode=$3 owner=$4 group=$5 tmp
    tmp=$(mktemp) || return 1
    if ! cat >"$tmp" ||
        ! managed_install_owned "$id" "$target" "$mode" "$owner" "$group" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    rm -f -- "$tmp"
}

# Atomically replace an existing regular file while preserving its current
# owner, group, and mode. This is used only for explicitly confirmed cleanup
# of external configuration that the suite does not adopt as managed state.
atomic_replace_preserving_metadata() {
    local target=$1 source=$2 mode owner group tmp
    managed_validate_target "$target"
    [[ -f "$target" && ! -L "$target" ]] ||
        die "refusing to replace a non-regular file: $target"
    [[ -f "$source" && ! -L "$source" ]] ||
        die "replacement source is not a regular file: $source"
    read -r mode owner group < <(stat -c '%a %u %g' "$target")
    tmp=$(mktemp "${target%/*}/.cachyos-tweaks.XXXXXX") || return 1
    if ! install -o "$owner" -g "$group" -m "$mode" "$source" "$tmp" ||
        ! mv -fT -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
}

# Echo per-file state: on | drifted | off
managed_file_status() {
    local id=$1 target=$2 dir e expected expected_hash expected_mode
    local expected_owner expected_group actual actual_metadata
    dir=$(tweak_dir "$id"); e=$(esc_path "$target")
    [[ -e "$dir/managed/$e" ]] || { printf 'off'; return; }
    [[ ! -L "$target" ]] || { printf 'drifted'; return; }
    # State created before readable hash markers stored the installed file
    # itself as a root-only marker. Its presence still proves that this suite
    # owns the live target; report it as managed until the next privileged
    # operation migrates it to a readable hash in status_metadata_prepare.
    [[ -r "$dir/managed/$e" ]] || { printf 'on'; return; }
    IFS= read -r expected <"$dir/managed/$e" || expected=''
    read -r expected_hash expected_mode expected_owner expected_group <<<"$expected"
    actual=''
    if [[ -r "$target" ]]; then
        actual=$(sha256sum "$target" 2>/dev/null | awk '{ print $1 }') || actual=''
    fi
    [[ "$expected_hash" =~ ^[[:xdigit:]]{64}$ && "$actual" == "$expected_hash" ]] ||
        { printf 'drifted'; return; }
    # A one-field marker predates metadata tracking. Continue to recognize it
    # by content until the next privileged apply records the full contract.
    if [[ -z "$expected_mode" ]]; then
        printf 'on'
        return
    fi
    [[ "$expected_mode" =~ ^[0-7]{3,4}$ &&
        "$expected_owner" =~ ^[0-9]+$ &&
        "$expected_group" =~ ^[0-9]+$ ]] ||
        { printf 'drifted'; return; }
    actual_metadata=$(stat -c '%a %u %g' "$target" 2>/dev/null) ||
        { printf 'drifted'; return; }
    [[ "$actual_metadata" == "$expected_mode $expected_owner $expected_group" ]] &&
        printf 'on' || printf 'drifted'
}

# Restore one managed path to its pre-apply condition. Passing --keep-state
# leaves the backup and ownership records intact so a caller can complete a
# required follow-up operation (for example rebuilding an initramfs) before
# committing the revert.
managed_restore() {
    local id=$1 target=$2 keep_state=${3:-} dir e restore_tmp
    dir=$(tweak_dir "$id"); e=$(esc_path "$target")
    [[ -e "$dir/managed/$e" || -e "$dir/existed/$e" || -e "$dir/absent/$e" ]] ||
        return 0
    # Replacing a drifted final symlink is safe: the atomic rename or unlink
    # operates on the link itself. Parent symlinks remain forbidden.
    managed_validate_target "$target" --allow-final-symlink
    if [[ -e "$dir/existed/$e" ]]; then
        local mode owner group
        read -r mode owner group <"$dir/existed/$e"
        # Older state dirs recorded only an empty marker; fall back to the
        # previous behavior for those instead of failing the restore.
        restore_tmp=$(mktemp "${target%/*}/.cachyos-tweaks.XXXXXX") || return 1
        if ! install -o "${owner:-0}" -g "${group:-0}" -m "${mode:-0644}" \
            "$dir/saved/$e" "$restore_tmp" ||
            ! mv -fT -- "$restore_tmp" "$target"; then
            rm -f -- "$restore_tmp"
            return 1
        fi
    else
        rm -f -- "$target" || return 1
    fi
    if [[ "$keep_state" != --keep-state ]]; then
        rm -f -- "$dir/managed/$e" "$dir/saved/$e" "$dir/existed/$e" "$dir/absent/$e"
        if [[ -f "$dir/manifest" ]]; then
            grep -vxF -- "$target" "$dir/manifest" >"$dir/manifest.new" || true
            mv -- "$dir/manifest.new" "$dir/manifest" || return 1
        fi
    fi
}

# Refuse to revert over external edits unless forced.
# managed_check_drift <id> [--force]
managed_check_drift() {
    local id=$1 force=${2:-} dir target drifted=0
    dir=$(tweak_dir "$id")
    [[ -f "$dir/manifest" ]] || return 0
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        if [[ $(managed_file_status "$id" "$target") == drifted ]]; then
            warn "edited after apply: $target"
            drifted=1
        fi
    done <"$dir/manifest"
    if (( drifted )) && [[ "$force" != --force ]]; then
        die 'refusing to overwrite later edits; inspect them or use force'
    fi
}

# Restore every managed file while retaining the state needed to retry or
# diagnose a failed follow-up operation.
managed_restore_all_keep_state() {
    local id=$1 dir target
    dir=$(tweak_dir "$id")
    if [[ -f "$dir/manifest" ]]; then
        while IFS= read -r target; do
            [[ -n "$target" ]] || continue
            managed_restore "$id" "$target" --keep-state
        done <"$dir/manifest"
    fi
}

# Commit a completed revert by dropping its backups and any empty parent
# directories created by the original apply.
managed_forget_all() {
    local id=$1 dir
    dir=$(tweak_dir "$id")
    if [[ -f "$dir/created-dirs" ]]; then
        local -a created_dirs=()
        mapfile -t created_dirs <"$dir/created-dirs"
        local i
        for ((i = ${#created_dirs[@]} - 1; i >= 0; i--)); do
            rmdir -- "${created_dirs[i]}" 2>/dev/null || true
        done
    fi
    rm -rf -- "$dir"
}

# Revert every managed file of a tweak and drop its state dir.
managed_revert_all() {
    local id=$1
    managed_restore_all_keep_state "$id"
    managed_forget_all "$id"
}

# Aggregate status over a tweak's manifest: on | off | drifted
managed_status_all() {
    local id=$1 dir target any=0 drift=0
    dir=$(tweak_dir "$id")
    [[ -f "$dir/manifest" ]] || { printf 'off'; return; }
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        case $(managed_file_status "$id" "$target") in
            on) any=1 ;;
            drifted) drift=1 ;;
        esac
    done <"$dir/manifest"
    if (( drift )); then printf 'drifted'
    elif (( any )); then printf 'on'
    else printf 'off'
    fi
}

# Aggregate status while also requiring every expected path to have a managed
# marker. This makes a partial multi-file apply visible as drift.
managed_status_paths() {
    local id=$1
    shift
    local status target
    status=$(managed_status_all "$id")
    [[ "$status" != drifted ]] || { printf 'drifted'; return; }
    for target in "$@"; do
        [[ $(managed_file_status "$id" "$target") != off ]] ||
            { printf 'drifted'; return; }
    done
    printf '%s' "$status"
}

# Persist/read small key=value facts for a tweak (e.g. prior service state).
tweak_note()  { local d; d=$(tweak_dir "$1"); install -d -m 0711 "$d"; printf '%s\n' "$3" >"$d/note-$2"; chmod 0600 "$d/note-$2"; }
tweak_read()  {
    local d
    d=$(tweak_dir "$1")
    [[ -r "$d/note-$2" ]] && cat "$d/note-$2" || printf '%s' "${3:-}"
}

# Keep only non-sensitive drift metadata readable by the unprivileged
# frontend. Saved originals, ownership records, and notes remain mode 0600
# below non-listable directories.
status_metadata_prepare() {
    need_root
    install -d -m 0711 "$STATE_ROOT" || return 1
    local dir managed marker current tmp
    for dir in "$STATE_ROOT"/*; do
        [[ -d "$dir" ]] || continue
        chmod 0711 "$dir" || return 1
        if [[ -f "$dir/manifest" ]]; then
            chmod 0644 "$dir/manifest" || return 1
        fi
        managed="$dir/managed"
        [[ -d "$managed" ]] || continue
        chmod 0711 "$managed" || return 1
        for marker in "$managed"/*; do
            [[ -f "$marker" ]] || continue
            current=''
            IFS= read -r current <"$marker" || true
            if [[ "$current" =~ ^[[:xdigit:]]{64}([[:space:]][0-7]{3,4}[[:space:]][0-9]+[[:space:]][0-9]+)?$ ]] &&
                [[ $(wc -l <"$marker") -eq 1 ]]; then
                chmod 0644 "$marker" || return 1
                continue
            fi
            tmp=$(mktemp "$managed/.status.XXXXXX") || return 1
            if ! sha256sum "$marker" | awk '{ print $1 }' >"$tmp" ||
                ! chmod 0644 "$tmp" ||
                ! mv -f -- "$tmp" "$marker"; then
                rm -f -- "$tmp"
                return 1
            fi
        done
    done
}

# ---------------------------------------------------------------------------
# Status rendering
# ---------------------------------------------------------------------------

status_badge() {
    local out
    status_badge_v "$1" out
    printf '%s' "$out"
}

# Fork-free variant for the TUI hot path: status_badge_v STATUS VARNAME
status_badge_v() {
    local -n _badge_out=$2
    case $1 in
        on)        _badge_out="${C_GREEN}[  on  ]${C_RESET}" ;;
        off)       _badge_out="${C_DIM}[ off  ]${C_RESET}" ;;
        drifted)   _badge_out="${C_RED}[drift ]${C_RESET}" ;;
        unmanaged) _badge_out="${C_YELLOW}[extern]${C_RESET}" ;;
        n/a)       _badge_out="${C_DIM}[ n/a  ]${C_RESET}" ;;
        stage-on)  _badge_out="${C_YELLOW}[-> on ]${C_RESET}" ;;
        stage-off) _badge_out="${C_YELLOW}[-> off]${C_RESET}" ;;
        *)         _badge_out="[$1]" ;;
    esac
}

# ---------------------------------------------------------------------------
# Generic tweak-module dispatch
#
# A module with prefix P defines:
#   ${P^^}_TWEAKS         array of tweak ids
#   P_detect              0 when this hardware is present
#   P_model_line          one-line hardware description
#   P_<id//-/_}_{title,desc,applicable,status,apply,revert}
# ---------------------------------------------------------------------------

module_known() {
    local -n _list="${1^^}_TWEAKS"
    local id
    for id in "${_list[@]}"; do
        [[ "$2" == "$id" ]] && return 0
    done
    return 1
}

module_apply() {
    need_root
    local prefix=$1 id=$2 fn=${2//-/_}
    "${prefix}_detect" || die "this machine does not match the $prefix module"
    "${prefix}_${fn}_applicable" || die "not applicable here: $id"
    [[ $("${prefix}_${fn}_status") == off ]] || die "not in an applicable state: $id"
    "${prefix}_${fn}_apply"
    msg "applied: $("${prefix}_${fn}_title")"
}

module_revert() {
    need_root
    local prefix=$1 id=$2 force=${3:-} fn=${2//-/_}
    case $("${prefix}_${fn}_status") in
        off) msg "not applied: $id"; return 0 ;;
        unmanaged) die "$id was configured outside this suite; not touching it" ;;
        drifted) [[ "$force" == --force ]] || die "files for $id were edited after apply; inspect or use force" ;;
    esac
    "${prefix}_${fn}_revert" "$force"
    msg "reverted: $("${prefix}_${fn}_title")"
}

module_print_status() {
    local prefix=$1
    local -n _list="${prefix^^}_TWEAKS"
    local id fn status
    if ! "${prefix}_detect"; then
        printf '%s%s: not available on this system.%s\n' "$C_DIM" "$("${prefix}_model_line")" "$C_RESET"
        return 0
    fi
    printf '%s%s%s\n' "$C_BOLD" "$("${prefix}_model_line")" "$C_RESET"
    for id in "${_list[@]}"; do
        fn=${id//-/_}
        if "${prefix}_${fn}_applicable"; then
            status=$("${prefix}_${fn}_status")
        else
            status='n/a'
        fi
        printf '  %s %-24s %s\n' "$(status_badge "$status")" "$id" \
            "$("${prefix}_${fn}_title")"
    done
}

# Status for simple file-drop tweaks: managed state wins; otherwise an
# existing target we did not create reads as unmanaged.
tweak_file_status() {
    local id=$1; shift
    local target
    if tweak_has_state "$id"; then
        managed_status_paths "$id" "$@"
        return
    fi
    for target in "$@"; do
        [[ -e "$target" ]] && { printf 'unmanaged'; return; }
    done
    printf 'off'
}

# ---------------------------------------------------------------------------
# Snapshots (snapper, best-effort)
# ---------------------------------------------------------------------------

SNAPSHOT_PRE_NUM=''

snapshot_available() {
    command -v snapper >/dev/null 2>&1 && [[ -e /etc/snapper/configs/root ]]
}

# snapshot_manual DESCRIPTION — create a standalone restore point.
snapshot_manual() {
    need_root
    snapshot_available || die 'snapper is not configured for the root filesystem'
    local description=${1:-Tweaks for CachyOS: manual snapshot}
    local number
    [[ "$description" != *$'\n'* && "$description" != *$'\r'* &&
        "$description" != *$'\x1e'* && "$description" != *$'\x1f'* &&
        ${#description} -le 200 ]] ||
        die 'snapshot description must be one line of at most 200 characters'
    number=$(snapper -c root create --type single --cleanup-algorithm number \
        --print-number --description "$description") \
        || die 'could not create the Snapper snapshot'
    [[ "$number" =~ ^[0-9]+$ ]] || die 'snapper returned an invalid snapshot number'
    msg "Created Snapper snapshot #$number."
}

# snapshot_pre DESCRIPTION — take a pre snapshot; remembers the number.
snapshot_pre() {
    SNAPSHOT_PRE_NUM=''
    snapshot_available || return 1
    SNAPSHOT_PRE_NUM=$(snapper -c root create --type pre --cleanup-algorithm number \
        --print-number --description "$1" 2>/dev/null) || { SNAPSHOT_PRE_NUM=''; return 1; }
    [[ "$SNAPSHOT_PRE_NUM" =~ ^[0-9]+$ ]] || { SNAPSHOT_PRE_NUM=''; return 1; }
}

# snapshot_post DESCRIPTION — close the pre/post pair if one is open.
snapshot_post() {
    [[ -n "$SNAPSHOT_PRE_NUM" ]] || return 0
    local pre=$SNAPSHOT_PRE_NUM
    SNAPSHOT_PRE_NUM=''
    if ! snapper -c root create --type post --cleanup-algorithm number \
        --pre-number "$pre" --description "$1" 2>/dev/null; then
        warn "could not close Snapper pre snapshot #$pre with a post snapshot"
        return 1
    fi
}

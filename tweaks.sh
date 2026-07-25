#!/usr/bin/env bash
# Tweaks for CachyOS — single entrypoint.
#
# Interactive TUI by default: the Charm (Bubble Tea) frontend in tui/.
# Toggling an item stages a change; nothing executes until Apply is selected
# and the change summary confirmed.
# Subcommands for scripting:
#   tweaks.sh status
#   tweaks.sh u2f enroll | unenroll
#   tweaks.sh u2f enable|disable SERVICE [--force]
#   tweaks.sh <module> list
#   tweaks.sh <module> apply|revert TWEAK [--force]
#   tweaks.sh build-tui                    build the Charm TUI (needs go)
#   tweaks.sh update                       update a managed portable install
# Frontend protocol (used by tui/):
#   tweaks.sh dump                         unprivileged machine-readable state
#   tweaks.sh batch                        staged ops on stdin (module\tid\ton|off)
#   tweaks.sh extra MODULE ACTION          run a module action
set -Eeuo pipefail

readonly SCRIPT_NAME=${0##*/}
readonly PROGRAM=${CACHYOS_TWEAKS_PROGRAM:-$SCRIPT_NAME}
readonly PROGRAM_COMMAND=${CACHYOS_TWEAKS_COMMAND:-"./$PROGRAM"}
SUITE_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SUITE_DIR
readonly SUITE_REPO=cjkubler/cachyos-tweaks

# shellcheck source=lib/common.sh
. "$SUITE_DIR/lib/common.sh"
# Common tweak implementations, authentication, and the ordered
# module manifest. Contributors add a module in modules/index.sh.
# shellcheck source=modules/index.sh
. "$SUITE_DIR/modules/index.sh"

SUITE_WORK=''

cleanup() {
    local status=$?
    set +e
    [[ -z "$SUITE_WORK" ]] || rm -rf -- "$SUITE_WORK"
    exit "$status"
}
trap cleanup EXIT

usage() {
    cat <<EOF
Usage: $PROGRAM_COMMAND [command]

Without a command, opens the Charm TUI and authorizes administrator actions
inside the app. Use --no-sudo to defer authorization until an action needs it.
Toggling stages a change; staged
changes execute only via Apply after a confirmation summary, wrapped in a
snapper pre/post snapshot pair when snapshots are configured.

Commands:
  status                        Show everything at a glance
  u2f enroll                    Enroll a connected FIDO2/U2F authenticator
  u2f unenroll                  Remove the enrollment (all services must be off)
  u2f enable SERVICE            Enable U2F for one service
  u2f disable SERVICE [--force] Disable U2F for one service
  MODULE list                   List a module's tweaks (${TWEAK_MODULES[*]})
  MODULE apply TWEAK            Apply one tweak
  MODULE revert TWEAK [--force] Revert one tweak
  snapshot create [DESCRIPTION] Create a manual Snapper snapshot
  --no-sudo                     Open the TUI without startup authorization
  build-tui                     Build the Charm TUI frontend (needs go)
  get-tui                       Download the prebuilt TUI from the latest release
  update                        Update a managed portable installation
  -h, --help                    This help

U2F services: ${U2F_SERVICES[*]}
EOF
}

# ---------------------------------------------------------------------------
# Frontend serialization adapters
#
# A module adapter MOD provides:
#   MOD_tg_build            fill TG_IDS TG_LABELS TG_STATUS TG_DESC
#   MOD_tg_toggleable IDX   0/1
#   MOD_tg_extra_build      optional: fill EX_IDS EX_LABELS EX_DESC
#                           (EX_CAPTURE[i]=1 = output-only action;
#                           EX_PRIVILEGED[i]=0 = safe without root)
#   MOD_tg_extra_run EXID   run an immediate action
# ---------------------------------------------------------------------------

declare -a TG_IDS=() TG_LABELS=() TG_STATUS=() TG_DESC=() TG_GROUPS=() TG_CATEGORIES=()
declare -a EX_IDS=() EX_LABELS=() EX_DESC=() EX_DISABLED=() EX_CAPTURE=() EX_PRIVILEGED=() EX_TABBED=()

# ---------------------------------------------------------------------------
# U2F adapter
# ---------------------------------------------------------------------------

U2F_CACHED_ENROLLED=0
U2F_KEY_OK=0
U2F_DEV_DESC=''

u2f_tg_build() {
    local service status desc
    TG_IDS=() TG_LABELS=() TG_STATUS=() TG_DESC=() TG_CATEGORIES=()
    if u2f_enrolled; then U2F_CACHED_ENROLLED=1; else U2F_CACHED_ENROLLED=0; fi
    if u2f_key_present; then
        U2F_KEY_OK=1
        U2F_DEV_DESC="Authenticator: ${U2F_KEY_LINE} — connected."
    else
        U2F_KEY_OK=0
        U2F_DEV_DESC='Authenticator: none detected — connect it for enrollment or tests.'
    fi
    for service in "${U2F_SERVICES[@]}"; do
        status=$(u2f_service_status "$service")
        TG_IDS+=("$service")
        TG_LABELS+=("$(u2f_service_label "$service")")
        TG_STATUS+=("$status")
        TG_CATEGORIES+=('')
        desc="$U2F_DEV_DESC"$'\n\n'
        desc+="PAM service: $service"$'\n'
        desc+="U2F key as an alternative to password/fingerprint for: $(u2f_service_label "$service")."$'\n'
        if u2f_service_is_login "$service"; then
            desc+='A typed password is consumed first (wallet/keyring keeps auto-unlocking);'$'\n'
            desc+='U2F takes over when the password is left empty.'$'\n'
        fi
        if [[ "$status" == unmanaged ]]; then
            desc+='Turning this off strips exactly the known rule block, verifies an'$'\n'
            desc+='auth line remains, and restores vendor files where possible.'$'\n'
        fi
        if (( ! U2F_CACHED_ENROLLED )); then
            desc+='No authenticator is enrolled yet: applying an enable runs'$'\n'
            desc+='enrollment first (two approvals on the key, isolated PAM test).'$'\n'
        fi
        TG_DESC+=("$desc")
    done
}

u2f_tg_toggleable() {
    local index=$1
    if [[ ${TG_STATUS[index]} == unmanaged ]]; then
        u2f_external_rule_removable "${TG_IDS[index]}"
        return
    fi
    return 0
}

u2f_tg_extra_build() {
    local i all_off=1
    for i in "${!TG_STATUS[@]}"; do
        [[ "${TG_STATUS[i]}" == off ]] || all_off=0
    done
    if (( ! U2F_CACHED_ENROLLED )); then
        EX_IDS+=(enroll); EX_LABELS+=('Enroll an authenticator'); EX_CAPTURE+=(0); EX_PRIVILEGED+=(1)
        if (( U2F_KEY_OK )); then EX_DISABLED+=(0); else EX_DISABLED+=(1); fi
        EX_DESC+=("$U2F_DEV_DESC"$'\n\n''Enroll the connected FIDO2/U2F authenticator for your account.'$'\n''You approve twice: once to register the key and once for an'$'\n''isolated PAM test. No live login files are touched by this step.')
    else
        # Output-only from the terminal's perspective: the interaction is a
        # touch on the key, so the Charm TUI can run it captured.
        EX_IDS+=(test); EX_LABELS+=('Test the authenticator now'); EX_CAPTURE+=(1)
        if u2f_test_service_ready; then EX_PRIVILEGED+=(0); else EX_PRIVILEGED+=(1); fi
        if (( U2F_KEY_OK )); then EX_DISABLED+=(0); else EX_DISABLED+=(1); fi
        EX_DESC+=("$U2F_DEV_DESC"$'\n\n''Run the enrolled credential against an isolated, U2F-only PAM'$'\n''stack (the same test enrollment uses). Approve on the key once when'$'\n''prompted. Existing enrollments may need a one-time service setup; after'$'\n''that, tests run without administrator access.')
        EX_IDS+=(unenroll); EX_LABELS+=('Remove enrollment'); EX_CAPTURE+=(0); EX_PRIVILEGED+=(1)
        if (( all_off )); then EX_DISABLED+=(0); else EX_DISABLED+=(1); fi
        if (( all_off )); then
            EX_DESC+=("Remove the U2F key mapping ($U2F_MAPPING)."$'\n\n''Also uninstalls pam-u2f if this suite installed it.')
        else
            EX_DESC+=("Remove the U2F key mapping ($U2F_MAPPING)."$'\n\n'"${C_YELLOW}Disabled: turn U2F off for every service first.${C_RESET}")
        fi
    fi
}

u2f_tg_extra_run() {
    local action=${EX_IDS[$1]}
    if [[ "$action" == test ]]; then
        u2f_test_credential
        return
    fi
    if snapshot_available; then
        if snapshot_pre "Tweaks for CachyOS: before u2f $action"; then
            msg "Snapper pre snapshot #$SNAPSHOT_PRE_NUM created."
        else
            warn 'could not create a snapper snapshot'
            warn 'No changes were applied.'
            return 1
        fi
    fi
    local rc=0 action_rc
    set +e
    if [[ "$action" == enroll ]]; then
        run_failfast u2f_enroll
    else
        run_failfast u2f_remove_enrollment
    fi
    action_rc=$?
    set -e
    (( action_rc == 0 )) || rc=1
    snapshot_post "Tweaks for CachyOS: after u2f $action" || rc=1
    return "$rc"
}

# ---------------------------------------------------------------------------
# Tweak-module adapter (generic over MODULE_CUR prefix)
# ---------------------------------------------------------------------------

MODULE_CUR=''

module_tg_build() {
    local -n _list="${MODULE_CUR^^}_TWEAKS"
    local id fn
    TG_IDS=() TG_LABELS=() TG_STATUS=() TG_DESC=() TG_GROUPS=() TG_CATEGORIES=()
    for id in "${_list[@]}"; do
        fn=${id//-/_}
        TG_IDS+=("$id")
        TG_LABELS+=("$("${MODULE_CUR}_${fn}_title")")
        if "${MODULE_CUR}_${fn}_applicable"; then
            TG_STATUS+=("$("${MODULE_CUR}_${fn}_status")")
        else
            TG_STATUS+=('n/a')
        fi
        TG_DESC+=("$("${MODULE_CUR}_${fn}_desc")")
        if declare -F "${MODULE_CUR}_${fn}_group" >/dev/null; then
            TG_GROUPS+=("$("${MODULE_CUR}_${fn}_group")")
        else
            TG_GROUPS+=('')
        fi
        if declare -F "${MODULE_CUR}_${fn}_category" >/dev/null; then
            TG_CATEGORIES+=("$("${MODULE_CUR}_${fn}_category")")
        else
            TG_CATEGORIES+=('')
        fi
    done
}

module_tg_toggleable() {
    case ${TG_STATUS[$1]} in
        n/a|unmanaged) return 1 ;;
        *) return 0 ;;
    esac
}

module_tg_extra_build() {
    if declare -F "${MODULE_CUR}_extra_build" >/dev/null; then
        "${MODULE_CUR}_extra_build"
    fi
}

module_tg_extra_run() {
    if declare -F "${MODULE_CUR}_extra_run" >/dev/null; then
        "${MODULE_CUR}_extra_run" "$@"
    fi
}

# ---------------------------------------------------------------------------
# Frontend protocol (used by the Charm TUI in tui/)
#
# dump:  records separated by \x1e, fields by \x1f (descriptions may span
#        lines). Types: SUITE, MODULE, DOC, TWEAK, EXTRA.
# batch: staged operations on stdin, one per line: MODULE\tTWEAK\ton|off.
#        Wrapped in a snapper pre/post pair; stops on the first failure.
# extra: run one module action (diagnostics, enrollment, guidance, ...).
# ---------------------------------------------------------------------------

readonly DUMP_US=$'\x1f' DUMP_RS=$'\x1e'

dump_record() {
    local field
    for field in "$@"; do
        [[ "$field" != *"$DUMP_US"* && "$field" != *"$DUMP_RS"* ]] ||
            die 'frontend protocol data contains a reserved delimiter'
    done
    local IFS=$DUMP_US
    printf '%s%s' "$*" "$DUMP_RS"
}

# dump_module NAME ADAPTER TITLE — NAME is the CLI module name, ADAPTER the
# tg_* function prefix (u2f, or module with MODULE_CUR preset).
dump_module() {
    local name=$1 adapter=$2 title=$3 i toggleable
    dump_record MODULE "$name" "$title"
    for i in "${!MODULE_DOC_MODULES[@]}"; do
        [[ "${MODULE_DOC_MODULES[i]}" == "$name" ]] || continue
        dump_record DOC "$name" "${MODULE_DOC_CATEGORIES[i]}" \
            "${MODULE_DOC_TITLES[i]}" "${MODULE_DOC_PATHS[i]}"
    done
    TG_IDS=() TG_LABELS=() TG_STATUS=() TG_DESC=() TG_GROUPS=() TG_CATEGORIES=()
    "${adapter}_tg_build"
    for i in "${!TG_IDS[@]}"; do
        if "${adapter}_tg_toggleable" "$i"; then toggleable=1; else toggleable=0; fi
        dump_record TWEAK "$name" "${TG_IDS[i]}" "${TG_LABELS[i]}" \
            "${TG_STATUS[i]}" "$toggleable" "${TG_DESC[i]}" "${TG_GROUPS[i]:-}" \
            "${TG_CATEGORIES[i]:-}"
    done
    EX_IDS=() EX_LABELS=() EX_DESC=() EX_DISABLED=() EX_CAPTURE=() EX_PRIVILEGED=() EX_TABBED=()
    if declare -F "${adapter}_tg_extra_build" >/dev/null; then
        "${adapter}_tg_extra_build"
    fi
    for i in "${!EX_IDS[@]}"; do
        dump_record EXTRA "$name" "${EX_IDS[i]}" "${EX_LABELS[i]}" \
            "${EX_DISABLED[i]:-0}" "${EX_CAPTURE[i]:-0}" "${EX_DESC[i]}" \
            "${EX_PRIVILEGED[i]:-1}" "${EX_TABBED[i]:-0}"
    done
}

suite_dump() {
    local host='' kernel='' snap=0 m
    [[ -r /proc/sys/kernel/hostname ]] && IFS= read -r host </proc/sys/kernel/hostname
    [[ -r /proc/sys/kernel/osrelease ]] && IFS= read -r kernel </proc/sys/kernel/osrelease
    snapshot_available && snap=1
    dump_record SUITE "$snap" "${host:-CachyOS}" "${kernel:-linux}"
    for m in "${TWEAK_MODULES[@]}"; do
        "${m}_detect" || continue
        MODULE_CUR=$m
        dump_module "$m" module "$("${m}_model_line")"
    done
    dump_module u2f u2f 'U2F / FIDO2 authentication'
}

# Execute one staged change; FROM is re-read so batch sees current reality.
batch_exec_one() {
    local mod=$1 id=$2 to=$3 from fn
    if [[ "$mod" == u2f ]]; then
        from=$(u2f_service_status "$id")
        if [[ "$to" == on ]]; then
            u2f_enable_service "$id"
        elif [[ "$from" == drifted ]]; then
            u2f_disable_service "$id" --force
        else
            u2f_disable_service "$id"
        fi
    else
        fn=${id//-/_}
        from=$("${mod}_${fn}_status")
        if [[ "$to" == on ]]; then
            module_apply "$mod" "$id"
        elif [[ "$from" == drifted ]]; then
            module_revert "$mod" "$id" --force
        else
            module_revert "$mod" "$id"
        fi
    fi
}

batch_execute() {
    need_root
    local -a mods=() ids=() tos=()
    local mod id to i s ok
    local -A seen_ops=() selected_groups=()
    while IFS=$'\t' read -r mod id to; do
        [[ -n "$mod" ]] || continue
        if [[ "$mod" == u2f ]]; then
            ok=0
            for s in "${U2F_SERVICES[@]}"; do [[ "$id" == "$s" ]] && ok=1; done
            (( ok )) || die "unknown u2f service: $id"
        else
            is_tweak_module "$mod" || die "unknown module: $mod"
            module_known "$mod" "$id" || die "unknown tweak: $mod/$id"
        fi
        [[ "$to" == on || "$to" == off ]] || die "bad target state: $to"
        [[ -z ${seen_ops["$mod/$id"]:-} ]] ||
            die "duplicate batch operation: $mod/$id"
        seen_ops["$mod/$id"]=1
        if [[ "$mod" != u2f && "$to" == on ]]; then
            local fn group=''
            fn=${id//-/_}
            if declare -F "${mod}_${fn}_group" >/dev/null; then
                group=$("${mod}_${fn}_group")
            fi
            if [[ -n "$group" ]]; then
                [[ -z ${selected_groups["$mod/$group"]:-} ]] ||
                    die "contradictory grouped choices: $mod/$group"
                selected_groups["$mod/$group"]=$id
            fi
        fi
        mods+=("$mod"); ids+=("$id"); tos+=("$to")
    done
    (( ${#mods[@]} )) || die 'batch: no operations on stdin'

    if snapshot_available; then
        if snapshot_pre 'Tweaks for CachyOS: before applying staged changes'; then
            msg "Snapper pre snapshot #$SNAPSHOT_PRE_NUM created."
        else
            warn 'could not create a snapper snapshot'
            warn 'No changes were applied.'
            return 1
        fi
    fi
    local need_enroll=0
    for i in "${!mods[@]}"; do
        [[ "${mods[i]}" == u2f && "${tos[i]}" == on ]] && need_enroll=1
    done
    if (( need_enroll )) && ! u2f_enrolled; then
        local enroll_rc
        set +e
        run_failfast u2f_enroll
        enroll_rc=$?
        set -e
        if (( enroll_rc != 0 )); then
            snapshot_post 'Tweaks for CachyOS: aborted' || true
            return 1
        fi
    fi
    local failed=0 operation_rc
    for i in "${!mods[@]}"; do
        set +e
        run_failfast batch_exec_one "${mods[i]}" "${ids[i]}" "${tos[i]}"
        operation_rc=$?
        set -e
        if (( operation_rc != 0 )); then
            warn "failed on: ${mods[i]}/${ids[i]} — stopping here"
            failed=1
            break
        fi
    done
    if ! snapshot_post 'Tweaks for CachyOS: after applying staged changes'; then
        failed=1
    fi
    return "$failed"
}

extra_run() {
    local mod=$1 exid=$2 i found=-1
    EX_IDS=() EX_LABELS=() EX_DESC=() EX_DISABLED=() EX_CAPTURE=() EX_PRIVILEGED=() EX_TABBED=()
    if [[ "$mod" == u2f ]]; then
        u2f_tg_build
        u2f_tg_extra_build
    else
        is_tweak_module "$mod" || die "unknown module: $mod"
        MODULE_CUR=$mod
        module_tg_extra_build
    fi
    for i in "${!EX_IDS[@]}"; do
        [[ "${EX_IDS[i]}" == "$exid" ]] && found=$i
    done
    (( found >= 0 )) || die "unknown action: $mod/$exid"
    [[ "${EX_DISABLED[found]:-0}" != 1 ]] || die "action not available right now: $exid"
    [[ "${EX_PRIVILEGED[found]:-1}" == 0 ]] || need_root
    if [[ "$mod" == u2f ]]; then
        u2f_tg_extra_run "$found"
    else
        module_tg_extra_run "$found"
    fi
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

case ${1:-} in
    -h|--help) usage; exit 0 ;;
    ''|menu|--no-sudo)
        if [[ ! -x "$SUITE_DIR/build/tweaks-tui" ]]; then
            if [[ ${CACHYOS_TWEAKS_PACKAGED:-0} == 1 ]]; then
                die 'the packaged TUI is missing; reinstall the package'
            fi
            die "the TUI is not built; run 'make' or $PROGRAM_COMMAND get-tui"
        fi
        if [[ ${1:-} == --no-sudo ]]; then
            CACHYOS_TWEAKS_SH="$SUITE_DIR/tweaks.sh" \
                exec "$SUITE_DIR/build/tweaks-tui" --no-sudo
        fi
        CACHYOS_TWEAKS_SH="$SUITE_DIR/tweaks.sh" exec "$SUITE_DIR/build/tweaks-tui"
        ;;
    build-tui)
        [[ ${CACHYOS_TWEAKS_PACKAGED:-0} != 1 ]] ||
            die 'this installation is managed by pacman; rebuild and reinstall the package to update'
        # Build as the invoking user (before self-elevation) so the Go
        # module/build caches stay user-owned.
        command -v go >/dev/null || die 'go is required to build the TUI (pacman -S go)'
        install -d "$SUITE_DIR/build"
        ( cd "$SUITE_DIR/tui" \
            && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$SUITE_DIR/build/tweaks-tui" . ) \
            || die 'TUI build failed'
        msg "built: $SUITE_DIR/build/tweaks-tui"
        exit 0
        ;;
    get-tui)
        [[ ${CACHYOS_TWEAKS_PACKAGED:-0} != 1 ]] ||
            die 'this installation is managed by pacman; rebuild and reinstall the package to update'
        # Fetch the prebuilt static binary from the latest GitHub release —
        # runs as the invoking user, no go toolchain needed. Verify it against
        # the checksum published by the release workflow before installation.
        command -v curl >/dev/null || die 'curl is required'
        command -v sha256sum >/dev/null || die 'sha256sum is required'
        arch=$(uname -m)
        case $arch in
            x86_64)  arch=amd64 ;;
            aarch64) arch=arm64 ;;
            *) die "no prebuilt TUI for this architecture: $arch (use build-tui)" ;;
        esac
        asset="tweaks-tui-linux-$arch"
        json=$(curl -fsSL "https://api.github.com/repos/$SUITE_REPO/releases/latest") \
            || die 'could not query the latest release (network down, or none published yet)'
        url=$(printf '%s\n' "$json" \
            | grep -oE "https://[^\"[:space:]]+/$asset" | head -n1) || true
        sums_url=$(printf '%s\n' "$json" \
            | grep -oE 'https://[^"[:space:]]+/SHA256SUMS' | head -n1) || true
        [[ -n "$url" ]] || die "the latest release has no asset named $asset"
        [[ -n "$sums_url" ]] || die 'the latest release has no SHA256SUMS asset'
        msg "Downloading $url"
        install -d "$SUITE_DIR/build"
        curl -fL --progress-bar -o "$SUITE_DIR/build/.tweaks-tui.part" "$url" \
            || { rm -f "$SUITE_DIR/build/.tweaks-tui.part"; die 'download failed'; }
        sums=$(curl -fsSL "$sums_url") \
            || { rm -f "$SUITE_DIR/build/.tweaks-tui.part"; die 'checksum download failed'; }
        expected=$(awk -v asset="$asset" '$2 == asset { print $1; exit }' <<<"$sums")
        [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] \
            || { rm -f "$SUITE_DIR/build/.tweaks-tui.part"; die "no valid checksum for $asset"; }
        printf '%s  %s\n' "$expected" "$SUITE_DIR/build/.tweaks-tui.part" \
            | sha256sum -c - >/dev/null \
            || { rm -f "$SUITE_DIR/build/.tweaks-tui.part"; die 'checksum verification failed'; }
        chmod 0755 "$SUITE_DIR/build/.tweaks-tui.part"
        mv -f "$SUITE_DIR/build/.tweaks-tui.part" "$SUITE_DIR/build/tweaks-tui"
        msg "installed: $SUITE_DIR/build/tweaks-tui"
        exit 0
        ;;
    update)
        [[ ${CACHYOS_TWEAKS_PACKAGED:-0} != 1 ]] ||
            die 'this installation is managed by pacman; use pacman to update it'
        [[ -n ${CACHYOS_TWEAKS_PORTABLE_ROOT:-} ]] ||
            die 'this source checkout is not a managed portable installation; use git to update it'
        [[ -x "$SUITE_DIR/install-portable.sh" ]] ||
            die 'the portable installer is missing; reinstall from a complete release'
        exec "$SUITE_DIR/install-portable.sh" --update
        ;;
    dump)
        require_cachyos
        suite_dump
        exit 0
        ;;
esac

require_cachyos
if (( EUID != 0 )) && [[ ${CACHYOS_TWEAKS_UNPRIVILEGED:-0} != 1 ]]; then
    command -v sudo >/dev/null || die 'run as root'
    exec sudo -- "$SUITE_DIR/$SCRIPT_NAME" "$@"
fi
if (( EUID == 0 )); then
    status_metadata_prepare
fi
SUITE_WORK=$(mktemp -d /tmp/cachyos-tweaks.XXXXXX)
# PAM authentication tests execute their helper as the enrolled account.
# Allow traversal to its randomized, world-executable child directory without
# allowing other users to list the suite's temporary files.
chmod 0711 "$SUITE_WORK"

is_tweak_module() {
    local m
    for m in "${TWEAK_MODULES[@]}"; do
        [[ "$1" == "$m" ]] && return 0
    done
    return 1
}

case ${1:-} in
    batch)
        rc=0
        set +e
        run_failfast batch_execute
        rc=$?
        set -e
        [[ ${2:-} != --pause ]] || pause
        exit "$rc"
        ;;
    extra)
        [[ -n "${2:-}" && -n "${3:-}" ]] || die "usage: $PROGRAM extra MODULE ACTION"
        rc=0
        set +e
        run_failfast extra_run "$2" "$3"
        rc=$?
        set -e
        [[ ${4:-} != --pause ]] || pause
        exit "$rc"
        ;;
    status)
        u2f_print_status
        for m in "${TWEAK_MODULES[@]}"; do
            printf '\n'
            module_print_status "$m"
        done
        ;;
    snapshot)
        [[ ${2:-} == create ]] || die "usage: $PROGRAM snapshot create [DESCRIPTION]"
        shift 2
        snapshot_manual "${*:-Tweaks for CachyOS: manual snapshot}"
        ;;
    u2f)
        case ${2:-} in
            enroll)   u2f_enroll ;;
            unenroll) u2f_remove_enrollment ;;
            enable|disable)
                [[ -n "${3:-}" ]] || die "usage: $PROGRAM u2f $2 SERVICE"
                ok=0
                for s in "${U2F_SERVICES[@]}"; do [[ "$3" == "$s" ]] && ok=1; done
                (( ok )) || die "unknown service: $3 (choose from ${U2F_SERVICES[*]})"
                if [[ "$2" == enable ]]; then
                    u2f_enable_service "$3"
                else
                    u2f_disable_service "$3" "${4:-}"
                fi
                ;;
            *) die "usage: $PROGRAM u2f enroll|unenroll|enable|disable ..." ;;
        esac
        ;;
    *)
        is_tweak_module "$1" || die "unknown command: $1 (see --help)"
        case ${2:-} in
            list) module_print_status "$1" ;;
            apply|revert)
                [[ -n "${3:-}" ]] || die "usage: $PROGRAM $1 $2 TWEAK"
                module_known "$1" "$3" || die "unknown tweak: $3"
                if [[ "$2" == apply ]]; then
                    module_apply "$1" "$3"
                else
                    module_revert "$1" "$3" "${4:-}"
                fi
                ;;
            *) die "usage: $PROGRAM $1 list|apply|revert ..." ;;
        esac
        ;;
esac

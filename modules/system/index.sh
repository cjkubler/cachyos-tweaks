# shellcheck shell=bash
# General OS policy module. Keep each policy family in its own category
# directory so adding CPU, storage, networking, or another category does not
# turn this manifest into a monolith.

# shellcheck disable=SC2034 # consumed indirectly by the generic module adapter
declare -ga SYSTEM_TWEAKS=()

# shellcheck source=modules/system/memory/presets.sh
. "$SUITE_DIR/modules/system/memory/presets.sh"
# shellcheck source=modules/system/remote/ssh.sh
. "$SUITE_DIR/modules/system/remote/ssh.sh"
# shellcheck source=modules/system/kernel/sysrq.sh
. "$SUITE_DIR/modules/system/kernel/sysrq.sh"
# shellcheck source=modules/system/storage/trim.sh
. "$SUITE_DIR/modules/system/storage/trim.sh"

system_detect() { return 0; }
system_model_line() { printf 'General OS tweaks'; }

# Categories contribute their immediate actions here; the ids are dispatched
# back to the owning category in system_extra_run.
system_extra_build() {
    system_memory_extra_build
    system_ssh_extra_build
}

system_extra_run() {
    local action=${EX_IDS[$1]}
    case $action in
        memory-report) system_memory_report ;;
        ssh-report) system_ssh_report ;;
        ssh-import-keys) system_ssh_import_keys ;;
        *) die "unknown system action: $action" ;;
    esac
}

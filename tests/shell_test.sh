#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

readonly PROGRAM=shell-test
SUITE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly SUITE_DIR
STATE_ROOT="$TEST_DIR/state"
SYSTEM_MEMORY_SYSCTL="$TEST_DIR/memory.conf"
SYSTEM_MEMORY_UDEV="$TEST_DIR/memory.rules"
SYSTEM_SYSRQ_SYSCTL="$TEST_DIR/sysrq.conf"
SYSTEM_SSH_DROPIN="$TEST_DIR/sshd-hardening.conf"
MANAGED_OWNER_UID=$(id -u)
MANAGED_OWNER_GID=$(id -g)

# shellcheck source=lib/common.sh
. "$SUITE_DIR/lib/common.sh"
# shellcheck source=modules/index.sh
. "$SUITE_DIR/modules/index.sh"

fail() {
    printf 'shell_test: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

assert_eq "$(esc_path /etc/modprobe.d/example.conf)" 'etc__modprobe.d__example.conf'

# A caller may collect a mutation's status without disabling errexit inside
# that mutation and accidentally running commands after its first failure.
failfast_probe() {
    false
    : >"$TEST_DIR/should-not-exist"
}
set +e
run_failfast failfast_probe
failfast_rc=$?
set -e
[[ "$failfast_rc" -ne 0 && ! -e "$TEST_DIR/should-not-exist" ]] ||
    fail 'run_failfast allowed a command after the first mutation failure'

target="$TEST_DIR/live.conf"
dir="$(tweak_dir example)"
escaped=$(esc_path "$target")
mkdir -p "$dir/managed"
printf '%s\n' "$target" >"$dir/manifest"
printf 'managed\n' >"$target"
sha256sum "$target" | awk '{ print $1 }' >"$dir/managed/$escaped"
chmod 0711 "$dir" "$dir/managed"
chmod 0644 "$dir/manifest" "$dir/managed/$escaped"

assert_eq "$(managed_file_status example "$target")" on
assert_eq "$(managed_status_all example)" on
printf 'changed\n' >"$target"
assert_eq "$(managed_file_status example "$target")" drifted
assert_eq "$(managed_status_all example)" drifted

# Managed writes create only the required parent path, commit content
# atomically, preserve an existing file exactly, and remove suite-created
# directories again on revert.
managed_parent="$TEST_DIR/new-parent/nested"
managed_target="$managed_parent/example.conf"
printf 'installed\n' |
    managed_write atomic-example "$managed_target" 0640
assert_eq "$(<"$managed_target")" installed
assert_eq "$(stat -c %a "$managed_target")" 640
assert_eq "$(managed_file_status atomic-example "$managed_target")" on
chmod 0644 "$managed_target"
assert_eq "$(managed_file_status atomic-example "$managed_target")" drifted
managed_revert_all atomic-example
[[ ! -e "$managed_target" && ! -d "$managed_parent" ]] ||
    fail 'revert did not remove an originally absent target and its created directories'

existing_target="$TEST_DIR/existing.conf"
printf 'before\n' >"$existing_target"
chmod 0604 "$existing_target"
printf 'after\n' |
    managed_write restore-example "$existing_target" 0644
printf 'edited\n' >"$existing_target"
assert_eq "$(managed_file_status restore-example "$existing_target")" drifted
managed_restore restore-example "$existing_target"
assert_eq "$(<"$existing_target")" before
assert_eq "$(stat -c %a "$existing_target")" 604

legacy_target="$TEST_DIR/legacy-existed.conf"
printf 'before\n' >"$legacy_target"
printf 'after\n' | managed_write legacy-example "$legacy_target" 0600
: >"$(tweak_dir legacy-example)/existed/$(esc_path "$legacy_target")"
managed_restore legacy-example "$legacy_target"
assert_eq "$(<"$legacy_target")" before
assert_eq "$(stat -c %a "$legacy_target")" 644

# Reverts that require a successful follow-up command retain their original
# backups until that command commits. A failed initramfs/service reload can
# therefore be retried without losing the exact pre-apply state.
transaction_target="$TEST_DIR/transaction.conf"
printf 'original\n' >"$transaction_target"
printf 'installed\n' |
    managed_write transaction-example "$transaction_target" 0644
managed_restore_all_keep_state transaction-example
assert_eq "$(<"$transaction_target")" original
[[ -d $(tweak_dir transaction-example) ]] ||
    fail 'transactional restore dropped retry state before commit'
assert_eq "$(managed_file_status transaction-example "$transaction_target")" drifted
managed_restore_all_keep_state transaction-example
managed_forget_all transaction-example
[[ ! -e $(tweak_dir transaction-example) ]] ||
    fail 'transactional restore retained state after commit'

# A missing marker for any expected member of a multi-file tweak is drift,
# never a false fully-applied status.
partial_one="$TEST_DIR/partial-one"
partial_two="$TEST_DIR/partial-two"
printf 'one\n' | managed_write partial-example "$partial_one" 0644
assert_eq "$(managed_status_paths partial-example "$partial_one" "$partial_two")" drifted
managed_revert_all partial-example

# Neither a final symlink nor a symlinked parent is accepted as a managed
# mutation target.
symlink_real="$TEST_DIR/symlink-real"
symlink_target="$TEST_DIR/symlink-target"
printf 'keep\n' >"$symlink_real"
ln -s "$symlink_real" "$symlink_target"
if (printf 'replace\n' | managed_write symlink-example "$symlink_target" 0644); then
    fail 'managed_write accepted a symlink target'
fi
assert_eq "$(<"$symlink_real")" keep
mkdir -p "$TEST_DIR/real-parent"
ln -s "$TEST_DIR/real-parent" "$TEST_DIR/linked-parent"
if (printf 'replace\n' |
    managed_write symlink-parent-example "$TEST_DIR/linked-parent/file" 0644); then
    fail 'managed_write accepted a symlinked parent'
fi

# A symlink introduced after apply is drift, but revert safely replaces the
# link itself and never writes through it.
drift_link_target="$TEST_DIR/drift-link-target"
drift_link_external="$TEST_DIR/drift-link-external"
printf 'original\n' >"$drift_link_target"
printf 'external\n' >"$drift_link_external"
printf 'installed\n' |
    managed_write drift-link-example "$drift_link_target" 0644
rm "$drift_link_target"
ln -s "$drift_link_external" "$drift_link_target"
assert_eq "$(managed_file_status drift-link-example "$drift_link_target")" drifted
managed_restore drift-link-example "$drift_link_target"
[[ ! -L "$drift_link_target" ]] || fail 'restore retained a drifted symlink'
assert_eq "$(<"$drift_link_target")" original
assert_eq "$(<"$drift_link_external")" external

# A root-only marker from an earlier install is still suite-owned state. An
# unprivileged status read must not mislabel the live tweak as external while
# it waits for the next privileged action to migrate the marker to a hash.
chmod 0000 "$dir/managed/$escaped"
assert_eq "$(managed_file_status example "$target")" on
chmod 0600 "$dir/managed/$escaped"

need_root() { return 0; }
printf 'managed\n' >"$dir/managed/$escaped"
chmod 0700 "$STATE_ROOT" "$dir" "$dir/managed"
chmod 0600 "$dir/manifest" "$dir/managed/$escaped"
status_metadata_prepare
assert_eq "$(stat -c %a "$STATE_ROOT")" 711
assert_eq "$(stat -c %a "$dir")" 711
assert_eq "$(stat -c %a "$dir/manifest")" 644
assert_eq "$(stat -c %a "$dir/managed/$escaped")" 644
[[ $(<"$dir/managed/$escaped") =~ ^[[:xdigit:]]{64}$ ]] ||
    fail 'status metadata was not reduced to a SHA-256'
assert_eq "$(managed_file_status example "$target")" drifted

[[ "${TWEAK_MODULES[*]}" == 'system fw13 fw16 yoga egpu' ]] ||
    fail "unexpected module order: ${TWEAK_MODULES[*]}"
(( ${#MODULE_DOC_MODULES[@]} == ${#MODULE_DOC_CATEGORIES[@]} &&
    ${#MODULE_DOC_MODULES[@]} == ${#MODULE_DOC_TITLES[@]} &&
    ${#MODULE_DOC_MODULES[@]} == ${#MODULE_DOC_PATHS[@]} )) ||
    fail 'module documentation metadata is misaligned'

for module in "${TWEAK_MODULES[@]}"; do
    list_name="${module^^}_TWEAKS"
    declare -n tweaks="$list_name"
    ((${#tweaks[@]} > 0)) || fail "$module has no tweaks"
    declare -A seen=()
    for id in "${tweaks[@]}"; do
        [[ -z ${seen[$id]:-} ]] || fail "$module registers $id twice"
        seen[$id]=1
        function_id=${id//-/_}
        for operation in title desc applicable status apply revert; do
            declare -F "${module}_${function_id}_${operation}" >/dev/null ||
                fail "$module/$id is missing $operation"
        done
        if [[ "$module" == system ]]; then
            declare -F "${module}_${function_id}_category" >/dev/null ||
                fail "$module/$id has no General OS category"
            [[ -n $("${module}_${function_id}_category") ]] ||
                fail "$module/$id has an empty General OS category"
        fi
    done
done

for documented_module in "${TWEAK_MODULES[@]}" u2f; do
    docs=0
    for doc_module in "${MODULE_DOC_MODULES[@]}"; do
        [[ "$doc_module" == "$documented_module" ]] && ((docs += 1))
    done
    ((docs > 0)) || fail "$documented_module has no registered documentation"
done

# The PAM test-service marker is security-sensitive ownership metadata.
u2f_test_content=$(u2f_test_service_content 'pam://test-host')
grep -Fx "$U2F_TEST_MARKER" <<<"$u2f_test_content" >/dev/null ||
    fail 'U2F test service lost its stable ownership marker'

# Memory policies are mutually exclusive views over one managed state. The
# default is active until the suite owns an override; exact content identifies
# the selected profile, while edits surface as drift.
assert_eq "$(system_memory_cachyos_status)" on
memory_dir=$(tweak_dir "$SYSTEM_MEMORY_STATE")
mkdir -p "$memory_dir/managed"
system_memory_sysctl_content applications >"$SYSTEM_MEMORY_SYSCTL"
system_memory_udev_content applications >"$SYSTEM_MEMORY_UDEV"
printf '%s\n%s\n' "$SYSTEM_MEMORY_SYSCTL" "$SYSTEM_MEMORY_UDEV" >"$memory_dir/manifest"
printf 'applications\n' >"$memory_dir/profile"
for memory_target in "$SYSTEM_MEMORY_SYSCTL" "$SYSTEM_MEMORY_UDEV"; do
    memory_escaped=$(esc_path "$memory_target")
    sha256sum "$memory_target" | awk '{ print $1 }' >"$memory_dir/managed/$memory_escaped"
done
original_system_memory_value=$(declare -f system_memory_value)
memory_test_swappiness=60
memory_test_page_cluster=0
system_memory_value() {
    case $1 in
        vm.swappiness) printf '%s' "$memory_test_swappiness" ;;
        vm.page-cluster) printf '%s' "$memory_test_page_cluster" ;;
        *) printf 'unknown' ;;
    esac
}
assert_eq "$(system_memory_applications_status)" on
assert_eq "$(system_memory_capacity_status)" off
assert_eq "$(system_memory_cachyos_status)" off
memory_test_swappiness=61
assert_eq "$(system_memory_applications_status)" drifted
memory_test_swappiness=60
printf '# edited\n' >>"$SYSTEM_MEMORY_SYSCTL"
assert_eq "$(system_memory_applications_status)" drifted
eval "$original_system_memory_value"

# Exercise profile switching and restoration without touching host sysctls.
# The fake writer retains the real manifest/hash behavior but omits root-only
# ownership, which an unprivileged unit test cannot create.
rm -rf -- "$memory_dir"
rm -f -- "$SYSTEM_MEMORY_SYSCTL" "$SYSTEM_MEMORY_UDEV"
(
    fake_swappiness=150
    fake_page_cluster=0
    sysctl() {
        if [[ "$1" == -n ]]; then
            case $2 in
                vm.swappiness) printf '%s\n' "$fake_swappiness" ;;
                vm.page-cluster) printf '%s\n' "$fake_page_cluster" ;;
                *) return 1 ;;
            esac
            return
        fi
        [[ "$1" == -q && "$2" == -w ]] || return 1
        case $3 in
            vm.swappiness=*) fake_swappiness=${3#*=} ;;
            vm.page-cluster=*) fake_page_cluster=${3#*=} ;;
            *) return 1 ;;
        esac
    }
    udevadm() { return 0; }
    managed_write() {
        local id=$1 target=$2 mode=$3 dir e
        dir=$(tweak_dir "$id")
        e=$(esc_path "$target")
        mkdir -p "$dir/managed"
        cat >"$target"
        chmod "$mode" "$target"
        sha256sum "$target" | awk '{ print $1 }' >"$dir/managed/$e"
        manifest_add "$id" "$target"
    }

    real_managed_install=$(declare -f managed_install)
    managed_install() {
        if [[ "$2" == "$SYSTEM_MEMORY_UDEV" ]]; then
            return 1
        fi
        managed_install_owned "$1" "$2" "$3" \
            "$MANAGED_OWNER_UID" "$MANAGED_OWNER_GID" "$4"
    }
    if (system_memory_apply_profile applications); then
        fail 'partial memory preset installation unexpectedly succeeded'
    fi
    [[ ! -e "$SYSTEM_MEMORY_SYSCTL" && ! -e "$SYSTEM_MEMORY_UDEV" &&
        ! -e $(tweak_dir "$SYSTEM_MEMORY_STATE") ]] ||
        fail 'failed memory preset installation did not restore the prior files'
    eval "$real_managed_install"

    system_memory_apply_profile applications
    assert_eq "$fake_swappiness" 60
    assert_eq "$(system_memory_applications_status)" on
    assert_eq "$(tweak_read "$SYSTEM_MEMORY_STATE" prior-swappiness)" 150

    system_memory_apply_profile capacity
    assert_eq "$fake_swappiness" 180
    assert_eq "$(system_memory_capacity_status)" on
    assert_eq "$(system_memory_applications_status)" off
    assert_eq "$(tweak_read "$SYSTEM_MEMORY_STATE" prior-swappiness)" 150

    system_memory_restore_defaults
    assert_eq "$fake_swappiness" 150
    assert_eq "$fake_page_cluster" 0
    [[ ! -e "$SYSTEM_MEMORY_SYSCTL" && ! -e "$SYSTEM_MEMORY_UDEV" ]] ||
        fail 'memory defaults did not remove suite-created overrides'
    [[ ! -e $(tweak_dir "$SYSTEM_MEMORY_STATE") ]] ||
        fail 'memory defaults did not remove managed state'
)

# Magic SysRq presets mirror the memory-policy contract: one managed sysctl
# file, a recorded prior live value, and a default row that restores it.
assert_eq "$(system_sysrq_default_status)" on
(
    fake_sysrq=16
    sysctl() {
        if [[ "$1" == -n ]]; then
            [[ "$2" == kernel.sysrq ]] || return 1
            printf '%s\n' "$fake_sysrq"
            return
        fi
        [[ "$1" == -q && "$2" == -w && "$3" == kernel.sysrq=* ]] || return 1
        fake_sysrq=${3#*=}
    }
    managed_write() {
        local id=$1 target=$2 mode=$3 dir e
        dir=$(tweak_dir "$id")
        e=$(esc_path "$target")
        mkdir -p "$dir/managed"
        cat >"$target"
        chmod "$mode" "$target"
        sha256sum "$target" | awk '{ print $1 }' >"$dir/managed/$e"
        manifest_add "$id" "$target"
    }

    system_sysrq_apply_profile reisub
    assert_eq "$fake_sysrq" 244
    assert_eq "$(system_sysrq_reisub_status)" on
    assert_eq "$(system_sysrq_full_status)" off
    assert_eq "$(system_sysrq_default_status)" off
    assert_eq "$(tweak_read "$SYSTEM_SYSRQ_STATE" prior-sysrq)" 16

    system_sysrq_apply_profile full
    assert_eq "$fake_sysrq" 1
    assert_eq "$(system_sysrq_full_status)" on
    assert_eq "$(system_sysrq_reisub_status)" off
    assert_eq "$(tweak_read "$SYSTEM_SYSRQ_STATE" prior-sysrq)" 16

    printf '# edited\n' >>"$SYSTEM_SYSRQ_SYSCTL"
    assert_eq "$(system_sysrq_full_status)" drifted
    system_sysrq_sysctl_content full >"$SYSTEM_SYSRQ_SYSCTL"

    system_sysrq_restore_default
    assert_eq "$fake_sysrq" 16
    [[ ! -e "$SYSTEM_SYSRQ_SYSCTL" ]] ||
        fail 'SysRq default did not remove the suite-created override'
    [[ ! -e $(tweak_dir "$SYSTEM_SYSRQ_STATE") ]] ||
        fail 'SysRq default did not remove managed state'
)

# The SSH hardening drop-in validates the resulting configuration before a
# running server is reloaded, and removes itself when validation fails.
ssh_stub_bin="$TEST_DIR/ssh-stub-bin"
mkdir -p "$ssh_stub_bin"
printf '#!/bin/sh\nexit 0\n' >"$ssh_stub_bin/ssh-keygen"
chmod 0755 "$ssh_stub_bin/ssh-keygen"
(
    PATH="$ssh_stub_bin:$PATH"
    systemctl() { return 0; }
    sshd() { return 0; }
    managed_write() {
        local id=$1 target=$2 mode=$3 dir e
        dir=$(tweak_dir "$id")
        e=$(esc_path "$target")
        mkdir -p "$dir/managed"
        cat >"$target"
        chmod "$mode" "$target"
        sha256sum "$target" | awk '{ print $1 }' >"$dir/managed/$e"
        manifest_add "$id" "$target"
    }

    # Key-only authentication may not be applied while no login account has a
    # usable authorized key: that would lock every account out.
    ssh_home="$TEST_DIR/ssh-home"
    # shellcheck disable=SC2034 # consumed indirectly by system_ssh_login_accounts
    SYSTEM_SSH_ACCOUNTS="tester:$ssh_home"
    assert_eq "$(system_ssh_hardening_status)" off
    if (system_ssh_hardening_apply) 2>/dev/null; then
        fail 'SSH hardening applied with no authorized key anywhere'
    fi
    [[ ! -e "$SYSTEM_SSH_DROPIN" ]] ||
        fail 'refused SSH hardening still installed its drop-in'
    mkdir -p "$ssh_home/.ssh"
    printf '# comment only\n\n' >"$ssh_home/.ssh/authorized_keys"
    if (system_ssh_hardening_apply) 2>/dev/null; then
        fail 'SSH hardening treated a key-less authorized_keys file as usable'
    fi
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY tester@client\n' \
        >>"$ssh_home/.ssh/authorized_keys"
    system_ssh_any_authorized_key ||
        fail 'a usable authorized key was not detected'
    grep -q 'tester: 1 authorized key' <(system_ssh_key_report) ||
        fail 'the key report did not count the usable key'

    system_ssh_hardening_apply
    assert_eq "$(system_ssh_hardening_status)" on
    grep -qx 'PasswordAuthentication no' "$SYSTEM_SSH_DROPIN" ||
        fail 'SSH hardening drop-in is missing its password policy'
    printf '# edited\n' >>"$SYSTEM_SSH_DROPIN"
    assert_eq "$(system_ssh_hardening_status)" drifted
    system_ssh_hardening_revert
    [[ ! -e "$SYSTEM_SSH_DROPIN" ]] ||
        fail 'SSH hardening revert did not remove the drop-in'
    assert_eq "$(system_ssh_hardening_status)" off

    sshd() { return 1; }
    if (system_ssh_hardening_apply) 2>/dev/null; then
        fail 'SSH hardening applied a configuration sshd rejected'
    fi
    [[ ! -e "$SYSTEM_SSH_DROPIN" && ! -e $(tweak_dir ssh-hardening) ]] ||
        fail 'rejected SSH hardening left its drop-in or state behind'
)

# Key imports resolve provider shorthands, validate every candidate with
# ssh-keygen, deduplicate against the target file, and record the source as a
# comment on comment-less keys.
ssh-keygen -q -t ed25519 -N '' -C 'tester@client' -f "$TEST_DIR/import-key"
ssh-keygen -q -t ed25519 -N '' -C '' -f "$TEST_DIR/import-key-bare"
import_key=$(<"$TEST_DIR/import-key.pub")
import_key_bare=$(<"$TEST_DIR/import-key-bare.pub")
import_home="$TEST_DIR/import-home"
mkdir -p "$import_home"
(
    system_ssh_import_account() { printf 'tester:%s\n' "$import_home"; }
    curl() {
        printf '%s\n' "$*" >"$TEST_DIR/curl-args"
        printf '%s\n' "$import_key" 'this is not a key'
    }
    keys_file="$import_home/.ssh/authorized_keys"

    export CACHYOS_TWEAKS_EXTRA_INPUT='octocat'
    system_ssh_import_keys >/dev/null
    grep -qF 'https://github.com/octocat.keys' "$TEST_DIR/curl-args" ||
        fail 'a bare name was not fetched as a GitHub username'
    [[ $(grep -c '^ssh-ed25519' "$keys_file") -eq 1 ]] ||
        fail 'the fetched key was not imported exactly once'
    if grep -qF 'this is not a key' "$keys_file"; then
        fail 'an invalid line from the source was imported'
    fi
    assert_eq "$(stat -c %a "$keys_file")" 600
    assert_eq "$(stat -c %a "$import_home/.ssh")" 700

    import_output=$(system_ssh_import_keys)
    grep -qF 'already present' <<<"$import_output" ||
        fail 'a repeated import did not report the duplicate'
    [[ $(grep -c '^ssh-ed25519' "$keys_file") -eq 1 ]] ||
        fail 'a repeated import duplicated the key'

    export CACHYOS_TWEAKS_EXTRA_INPUT="$import_key_bare"
    system_ssh_import_keys >/dev/null
    [[ $(grep -c '^ssh-ed25519' "$keys_file") -eq 2 ]] ||
        fail 'a pasted public key was not imported'

    export CACHYOS_TWEAKS_EXTRA_INPUT='github:bad//name'
    if (system_ssh_import_keys) >/dev/null 2>&1; then
        fail 'an invalid provider username was accepted'
    fi
    export CACHYOS_TWEAKS_EXTRA_INPUT='ftp://example.com/keys'
    if (system_ssh_import_keys) >/dev/null 2>&1; then
        fail 'a non-https source was accepted'
    fi
)

# Service-backed tweaks record the prior enablement and activity and restore
# exactly that; an externally enabled unit reads as unmanaged.
(
    fake_enabled=no
    fake_active=no
    systemctl() {
        case $1 in
            is-enabled)
                [[ "$fake_enabled" == yes ]] && { printf 'enabled\n'; return 0; }
                printf 'disabled\n'
                return 1
                ;;
            is-active)
                [[ "$fake_active" == yes ]] && { printf 'active\n'; return 0; }
                printf 'inactive\n'
                return 3
                ;;
            enable)
                [[ "$2" == --now ]] || return 1
                fake_enabled=yes
                fake_active=yes
                ;;
            disable) fake_enabled=no ;;
            stop) fake_active=no ;;
            *) return 1 ;;
        esac
    }

    assert_eq "$(service_tweak_status svc-example example.service)" off
    fake_active=yes
    assert_eq "$(service_tweak_status svc-example example.service)" unmanaged
    fake_active=no

    service_tweak_apply svc-example example.service
    assert_eq "$(service_tweak_status svc-example example.service)" on
    assert_eq "$(tweak_read svc-example prior-enabled)" disabled
    assert_eq "$(tweak_read svc-example prior-active)" inactive

    service_tweak_revert svc-example example.service
    assert_eq "$(service_tweak_status svc-example example.service)" off
    [[ "$fake_enabled" == no && "$fake_active" == no ]] ||
        fail 'service revert did not restore the recorded prior state'
    [[ ! -e $(tweak_dir svc-example) ]] ||
        fail 'service revert retained suite state'
)

# Firmware-backed charge policies distinguish an external active setting from
# suite-owned state and restore the exact value recorded before apply.
YOGA_CONSERVATION_NODE="$TEST_DIR/conservation-mode"
printf '1\n' >"$YOGA_CONSERVATION_NODE"
assert_eq "$(yoga_battery_conservation_status)" unmanaged
printf '0\n' >"$YOGA_CONSERVATION_NODE"
assert_eq "$(yoga_battery_conservation_status)" off
yoga_battery_conservation_apply
assert_eq "$(yoga_battery_conservation_status)" on
yoga_battery_conservation_revert
assert_eq "$(<"$YOGA_CONSERVATION_NODE")" 0
[[ ! -e $(tweak_dir battery-conservation) ]] ||
    fail 'battery conservation revert retained suite state'

COMMON_FRAMEWORK_CHARGE_NODE="$TEST_DIR/framework-charge-limit"
printf '80\n' >"$COMMON_FRAMEWORK_CHARGE_NODE"
assert_eq "$(common_framework_charge_status)" unmanaged
printf '90\n' >"$COMMON_FRAMEWORK_CHARGE_NODE"
assert_eq "$(common_framework_charge_status)" off
common_framework_charge_apply
assert_eq "$(<"$COMMON_FRAMEWORK_CHARGE_NODE")" 80
assert_eq "$(common_framework_charge_status)" on
common_framework_charge_revert
assert_eq "$(<"$COMMON_FRAMEWORK_CHARGE_NODE")" 90
[[ ! -e $(tweak_dir charge-limit-80) ]] ||
    fail 'Framework charge-limit revert retained suite state'

# External PAM cleanup removes only a byte-for-byte known bare rule or full
# generated block. Custom or mixed U2F configuration remains manual.
u2f_service=example
u2f_pam_file="$TEST_DIR/u2f-pam-service"
u2f_known_rule=$(u2f_rule "$(u2f_origin)")
printf '%s\n' "$u2f_known_rule" '  auth include system-auth' \
    >"$u2f_pam_file"
u2f_external_rule_bounds "$u2f_service" "$u2f_pam_file" ||
    fail 'known external U2F rule was not removable'
u2f_stripped="$TEST_DIR/u2f-stripped"
u2f_strip_external_block "$u2f_pam_file" "$u2f_stripped" \
    "$U2F_EXTERNAL_BLOCK_START" "$U2F_EXTERNAL_BLOCK_END"
grep -Eq '^[[:space:]]+auth include system-auth' "$u2f_stripped" ||
    fail 'external U2F cleanup removed the fallback stack'

printf '%s\n' \
    "$U2F_MARKER" \
    "$u2f_known_rule" \
    'auth include system-auth' >"$u2f_pam_file"
u2f_external_rule_bounds "$u2f_service" "$u2f_pam_file" ||
    fail 'complete generated U2F block was not removable'
u2f_strip_external_block "$u2f_pam_file" "$u2f_stripped" \
    "$U2F_EXTERNAL_BLOCK_START" "$U2F_EXTERNAL_BLOCK_END"
if grep -qF 'pam_u2f.so' "$u2f_stripped" || grep -qxF "$U2F_MARKER" "$u2f_stripped"; then
    fail 'external U2F block cleanup left generated lines behind'
fi

printf '%s\n' \
    "$u2f_known_rule" \
    'auth sufficient pam_u2f.so authfile=/custom/mapping cue' \
    'auth include system-auth' >"$u2f_pam_file"
if u2f_external_rule_bounds "$u2f_service" "$u2f_pam_file"; then
    fail 'mixed custom U2F configuration was considered removable'
fi

# Key management edits only the enrolled user's line and refuses to leave a
# user with no credentials.
u2f_mapping="$TEST_DIR/u2f_mappings"
u2f_other_line='bob:bobHandle,bobKey,es256,+presence'
u2f_cred_a='aliceHandle1,aliceKey1,es256,+presence'
u2f_cred_b='aliceHandle2,aliceKey2,es256,+presence+pin'
u2f_cred_new='aliceHandle3,aliceKey3,eddsa,+presence'
printf '%s\n' "$u2f_other_line" "alice:$u2f_cred_a:$u2f_cred_b" >"$u2f_mapping"
assert_eq "$(u2f_credentials "$u2f_mapping" alice)" "$u2f_cred_a"$'\n'"$u2f_cred_b"
assert_eq "$(u2f_credentials "$u2f_mapping" ali)" ''

u2f_id_a=$(u2f_credential_id "$u2f_cred_a")
u2f_id_b=$(u2f_credential_id "$u2f_cred_b")
[[ "$u2f_id_a" =~ ^[0-9a-f]{12}$ ]] || fail "credential id is not 12 hex digits: $u2f_id_a"
assert_eq "$(u2f_credential_id "$u2f_cred_a")" "$u2f_id_a"
[[ "$u2f_id_a" != "$u2f_id_b" ]] || fail 'distinct credentials share an id'

u2f_mapping_append "$u2f_mapping" alice "$u2f_cred_new" >"$TEST_DIR/u2f-appended"
assert_eq "$(<"$TEST_DIR/u2f-appended")" \
    "$u2f_other_line"$'\n'"alice:$u2f_cred_a:$u2f_cred_b:$u2f_cred_new"
if u2f_mapping_append "$u2f_mapping" carol "$u2f_cred_new" >/dev/null; then
    fail 'appending for a user without a mapping line succeeded'
fi

u2f_mapping_remove "$u2f_mapping" alice "$u2f_id_a" >"$TEST_DIR/u2f-reduced"
assert_eq "$(<"$TEST_DIR/u2f-reduced")" "$u2f_other_line"$'\n'"alice:$u2f_cred_b"
if u2f_mapping_remove "$u2f_mapping" alice 000000000000 >/dev/null; then
    fail 'removing an unknown credential id succeeded'
fi
if u2f_mapping_remove "$TEST_DIR/u2f-reduced" alice "$u2f_id_b" >/dev/null; then
    fail 'removing the last credential succeeded'
fi

u2f_labels="$TEST_DIR/key-labels"
u2f_label_store "$u2f_labels" "$u2f_id_b" $'Thetis Key\t(F829), added 2026-11-02'
assert_eq "$(stat -c %a "$u2f_labels")" 644
assert_eq "$(u2f_key_list "$u2f_mapping" alice "$u2f_labels")" \
    "$u2f_id_a"$'\t'"Authenticator $u2f_id_a"$'\n'"$u2f_id_b"$'\t''Thetis Key (F829), added 2026-11-02'
u2f_label_store "$u2f_labels" "$u2f_id_a" 'Spare key'
u2f_label_store "$u2f_labels" "$u2f_id_b"
assert_eq "$(<"$u2f_labels")" "$u2f_id_a"$'\t''Spare key'

fido2-token() {
    printf '%s\n' \
        '/dev/hidraw0: vendor=0x1ea8, product=0xf829 (Thetis Security Key(F829))' \
        'pcsc://slot0: vendor=0x076b, product=0x5422 (HID Global OMNIKEY 5422)' \
        '/dev/hidraw3: vendor=0x0483, product=0x5741 (Flipper Devices Inc. U2F Token)' \
        '/dev/hidraw12: vendor=0x1050, product=0x0407 ( )'
}
u2f_detect_keys
assert_eq "${U2F_DEVICES[*]}" 'hidraw0 hidraw3 hidraw12'
assert_eq "$(printf '%s|' "${U2F_DEVICE_NAMES[@]}")" \
    'Thetis Security Key(F829)|Flipper Devices Inc. U2F Token|FIDO2 device|'
u2f_select_device /dev/hidraw3
assert_eq "$U2F_DEVICE/$U2F_DEVICE_NAME" 'hidraw3/Flipper Devices Inc. U2F Token'
for u2f_bad_device in '' hidraw9 'hidraw3;x' ../hidraw3; do
    if (u2f_select_device "$u2f_bad_device") 2>/dev/null; then
        fail "selected an ambiguous or unconnected authenticator: '$u2f_bad_device'"
    fi
done
fido2-token() { printf '%s\n' '/dev/hidraw5: vendor=0x1, product=0x2 (Solo Key)'; }
u2f_select_device ''
assert_eq "$U2F_DEVICE/$U2F_DEVICE_NAME" 'hidraw5/Solo Key'
unset -f fido2-token

# Silent probes, as observed on real keys: a FIDO2 key holding the
# credential signs, a U2F key holding it reports that presence is required,
# and any other key reports no credentials.
u2f_assert_bin="$TEST_DIR/u2f-assert-bin"
mkdir -p "$u2f_assert_bin"
cat >"$u2f_assert_bin/fido2-assert" <<'EOF'
#!/bin/sh
[ "$3" = up=false ] || { echo "probe asked for presence: $*" >&2; exit 2; }
{ read -r _; read -r _; read -r id; }
case "${4#/dev/}:$id" in
    hidraw0:fido2Cred) echo signed ;;
    hidraw3:u2fCred) echo 'fido2-assert: fido_dev_get_assert: FIDO_ERR_USER_PRESENCE_REQUIRED' >&2; exit 1 ;;
    *) echo 'fido2-assert: fido_dev_get_assert: FIDO_ERR_NO_CREDENTIALS' >&2; exit 1 ;;
esac
EOF
chmod +x "$u2f_assert_bin/fido2-assert"
u2f_saved_path=$PATH
PATH="$u2f_assert_bin:$PATH"
u2f_device_holds hidraw0 pam://host 'fido2Cred,key,es256,+presence' ||
    fail 'a FIDO2 key holding the credential was not recognized'
u2f_device_holds hidraw3 pam://host 'u2fCred,key,es256,+presence' ||
    fail 'a U2F key holding the credential was not recognized'
for u2f_probe in 'hidraw0 u2fCred' 'hidraw3 fido2Cred'; do
    read -r u2f_probe_dev u2f_probe_id <<<"$u2f_probe"
    if u2f_device_holds "$u2f_probe_dev" pam://host "$u2f_probe_id,key,es256,+presence"; then
        fail "$u2f_probe_dev claimed a credential it does not hold"
    fi
done
PATH=$u2f_saved_path

# fido2-cred -V prints the credential id and a PEM key; pam_u2f wants the
# es256 key as raw X||Y, the point openssl prints without its 0x04 tag.
u2f_ec_key="$TEST_DIR/u2f-ec.pem"
u2f_verified="$TEST_DIR/u2f-verified"
u2f_cred_id='q83vEjRWeJA+/w=='
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$u2f_ec_key" 2>/dev/null
{ printf '%s\n' "$u2f_cred_id"; openssl pkey -in "$u2f_ec_key" -pubout; } >"$u2f_verified"
u2f_point=$(openssl ec -in "$u2f_ec_key" -noout -text 2>/dev/null |
    sed -n '/^pub:/,/^ASN1 OID/{/^ /p}' | tr -d ' :\n')
[[ "$u2f_point" =~ ^04[0-9a-f]{128}$ ]] || fail "unexpected openssl point dump: $u2f_point"
u2f_converted=$(u2f_credential_from_verified "$u2f_verified")
IFS=, read -r u2f_conv_id u2f_conv_key u2f_conv_type u2f_conv_attrs <<<"$u2f_converted"
assert_eq "$u2f_conv_id,$u2f_conv_type,$u2f_conv_attrs" "$u2f_cred_id,es256,+presence"
assert_eq "$(base64 -d <<<"$u2f_conv_key" | wc -c)" 64
assert_eq "$(base64 -d <<<"$u2f_conv_key" | od -An -v -tx1 | tr -d ' \n')" "${u2f_point#04}"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$u2f_ec_key" 2>/dev/null
{ printf '%s\n' "$u2f_cred_id"; openssl pkey -in "$u2f_ec_key" -pubout; } >"$u2f_verified"
if u2f_credential_from_verified "$u2f_verified" >/dev/null; then
    fail 'converted a non-P-256 key to an es256 credential'
fi
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$u2f_ec_key" 2>/dev/null
{ printf '%s\n' 'q83v:EjRW'; openssl pkey -in "$u2f_ec_key" -pubout; } >"$u2f_verified"
if u2f_credential_from_verified "$u2f_verified" >/dev/null; then
    fail 'accepted a credential id that would split the mapping line'
fi

snapshot_available() { return 0; }
snapper() {
    printf '%s\n' "$@" >"$TEST_DIR/snapper-args"
    printf '42\n'
}
snapshot_output=$(snapshot_manual 'Release readiness checkpoint')
assert_eq "$snapshot_output" 'Created Snapper snapshot #42.'
grep -Fx -- '--type' "$TEST_DIR/snapper-args" >/dev/null ||
    fail 'manual snapshot did not pass --type'
grep -Fx -- 'single' "$TEST_DIR/snapper-args" >/dev/null ||
    fail 'manual snapshot was not standalone'
grep -Fx -- 'Release readiness checkpoint' "$TEST_DIR/snapper-args" >/dev/null ||
    fail 'manual snapshot description was not preserved'

# shellcheck disable=SC2034 # populated indirectly by egpu_extra_build
EX_IDS=() EX_LABELS=() EX_DESC=() EX_DISABLED=() EX_CAPTURE=() EX_PRIVILEGED=() EX_TABBED=()
egpu_extra_build
assert_eq "${EX_PRIVILEGED[0]}" 0
assert_eq "${EX_TABBED[0]}" 1

# A live U2F block without a managed-state record is always external. A
# root-only legacy marker is recognized by managed_file_status itself.
managed_file_status() { printf 'off'; }
u2f_live_has_rule() { return 0; }
assert_eq "$(u2f_service_status example)" unmanaged
managed_file_status() { printf 'on'; }
assert_eq "$(u2f_service_status example)" on

printf 'shell tests passed\n'

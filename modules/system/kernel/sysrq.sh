# shellcheck shell=bash
# Magic SysRq policy category for CachyOS.
#
# The kernel's Magic SysRq keys act below userspace, so they still work when
# the desktop or even most of the kernel is wedged. systemd ships
# kernel.sysrq = 16 (sync only); CachyOS keeps that default. These presets
# widen it either to the emergency subset needed for the classic REISUB
# reboot sequence, or to every function.

register_module_doc system 'General OS' 'Magic SysRq keys' \
    modules/system/kernel/README.md

SYSTEM_TWEAKS+=(
    sysrq-default
    sysrq-reisub
    sysrq-full
)

system_sysrq_category() { printf 'Kernel'; }

: "${SYSTEM_SYSRQ_STATE:=sysrq-policy}"
: "${SYSTEM_SYSRQ_SYSCTL:=/etc/sysctl.d/99-cachyos-tweaks-sysrq.conf}"
: "${SYSTEM_SYSRQ_PROC:=/proc/sys/kernel/sysrq}"
readonly SYSTEM_SYSRQ_STATE SYSTEM_SYSRQ_SYSCTL SYSTEM_SYSRQ_PROC

system_sysrq_available() { [[ -r "$SYSTEM_SYSRQ_PROC" ]]; }

system_sysrq_value() {
    local value
    value=$(sysctl -n kernel.sysrq 2>/dev/null) || value=unknown
    printf '%s' "$value"
}

system_sysrq_profile_value() {
    case $1 in
        reisub) printf '244' ;;
        full) printf '1' ;;
        *) return 1 ;;
    esac
}

system_sysrq_sysctl_content() {
    local profile=$1 value
    value=$(system_sysrq_profile_value "$profile") || return 1
    cat <<EOF
# Managed by Tweaks for CachyOS. Choose another Magic SysRq preset or the
# system default in the application instead of editing this file.
# Profile: $profile
kernel.sysrq = $value
EOF
}

system_sysrq_live_profile() {
    local profile
    [[ -r "$SYSTEM_SYSRQ_SYSCTL" ]] || return 1
    for profile in reisub full; do
        if [[ $(<"$SYSTEM_SYSRQ_SYSCTL") == "$(system_sysrq_sysctl_content "$profile")" ]]; then
            printf '%s' "$profile"
            return 0
        fi
    done
    return 1
}

system_sysrq_recorded_profile() {
    local marker
    marker="$(tweak_dir "$SYSTEM_SYSRQ_STATE")/profile"
    [[ -r "$marker" ]] || return 1
    IFS= read -r REPLY <"$marker"
    [[ "$REPLY" == reisub || "$REPLY" == full ]]
}

system_sysrq_profile_status() {
    local profile=$1 current='' recorded='' managed
    if tweak_has_state "$SYSTEM_SYSRQ_STATE"; then
        current=$(system_sysrq_live_profile 2>/dev/null || true)
        system_sysrq_recorded_profile && recorded=$REPLY
        managed=$(managed_status_paths "$SYSTEM_SYSRQ_STATE" "$SYSTEM_SYSRQ_SYSCTL")
        if [[ "$profile" == "$current" ]]; then
            if [[ "$managed" == on &&
                $(system_sysrq_value) == "$(system_sysrq_profile_value "$profile")" ]]; then
                printf 'on'
            else
                printf 'drifted'
            fi
        elif [[ "$managed" == drifted && "$profile" == "$recorded" ]]; then
            printf 'drifted'
        else
            printf 'off'
        fi
        return
    fi

    if [[ -e "$SYSTEM_SYSRQ_SYSCTL" ]]; then
        current=$(system_sysrq_live_profile 2>/dev/null || true)
        if [[ "$profile" == "$current" ]] ||
            [[ -z "$current" && "$profile" == reisub ]]; then
            printf 'unmanaged'
        else
            printf 'off'
        fi
    else
        printf 'off'
    fi
}

system_sysrq_save_runtime() {
    local value
    tweak_has_state "$SYSTEM_SYSRQ_STATE" && return 0
    value=$(sysctl -n kernel.sysrq 2>/dev/null) ||
        die 'cannot read the current kernel.sysrq value'
    [[ "$value" =~ ^[0-9]+$ && "$value" -le 511 ]] ||
        die "invalid current kernel.sysrq value: $value"
    tweak_note "$SYSTEM_SYSRQ_STATE" prior-sysrq "$value"
}

system_sysrq_rollback_profile_file() {
    local had_state=$1 prior_profile=$2 dir
    if (( had_state )); then
        system_sysrq_sysctl_content "$prior_profile" |
            managed_write "$SYSTEM_SYSRQ_STATE" "$SYSTEM_SYSRQ_SYSCTL" 0644 || return 1
        dir=$(tweak_dir "$SYSTEM_SYSRQ_STATE")
        printf '%s\n' "$prior_profile" >"$dir/profile" || return 1
        chmod 0644 "$dir/profile" || return 1
    else
        managed_revert_all "$SYSTEM_SYSRQ_STATE"
    fi
}

system_sysrq_apply_profile() {
    local profile=$1 value dir prior_profile='' had_state=0
    local runtime_value profile_tmp
    value=$(system_sysrq_profile_value "$profile") || die "unknown SysRq profile: $profile"
    if tweak_has_state "$SYSTEM_SYSRQ_STATE"; then
        [[ $(managed_status_paths "$SYSTEM_SYSRQ_STATE" "$SYSTEM_SYSRQ_SYSCTL") == on ]] ||
            die 'the current SysRq preset is incomplete or edited; restore the default before switching'
        managed_check_drift "$SYSTEM_SYSRQ_STATE"
        prior_profile=$(system_sysrq_live_profile) ||
            die 'the current managed SysRq preset cannot be identified'
        had_state=1
    fi
    system_sysrq_save_runtime
    runtime_value=$(sysctl -n kernel.sysrq 2>/dev/null) ||
        die 'cannot read kernel.sysrq before applying the SysRq preset'
    [[ "$runtime_value" =~ ^[0-9]+$ && "$runtime_value" -le 511 ]] ||
        die "invalid current kernel.sysrq value: $runtime_value"
    if ! system_sysrq_sysctl_content "$profile" |
        managed_write "$SYSTEM_SYSRQ_STATE" "$SYSTEM_SYSRQ_SYSCTL" 0644; then
        system_sysrq_rollback_profile_file "$had_state" "$prior_profile" ||
            die 'SysRq preset installation failed and its file rollback was incomplete'
        die 'could not install the SysRq preset; the prior state was restored'
    fi
    dir=$(tweak_dir "$SYSTEM_SYSRQ_STATE")
    profile_tmp=$(mktemp "$dir/.profile.XXXXXX") ||
        {
            system_sysrq_rollback_profile_file "$had_state" "$prior_profile" || true
            die 'could not record the selected SysRq preset; the prior file was restored'
        }
    if ! printf '%s\n' "$profile" >"$profile_tmp" ||
        ! chmod 0644 "$profile_tmp" ||
        ! mv -fT -- "$profile_tmp" "$dir/profile"; then
        rm -f -- "$profile_tmp"
        system_sysrq_rollback_profile_file "$had_state" "$prior_profile" ||
            die 'recording the SysRq preset failed and its file rollback was incomplete'
        die 'could not record the selected SysRq preset; the prior file was restored'
    fi

    if ! sysctl -q -w "kernel.sysrq=$value"; then
        sysctl -q -w "kernel.sysrq=$runtime_value" || true
        system_sysrq_rollback_profile_file "$had_state" "$prior_profile" ||
            die 'applying the SysRq preset failed and its file rollback was incomplete'
        die 'could not activate the SysRq preset; the prior state was restored'
    fi
}

system_sysrq_restore_default() {
    local force=${1:-} value
    tweak_has_state "$SYSTEM_SYSRQ_STATE" || return 0
    managed_check_drift "$SYSTEM_SYSRQ_STATE" "$force"
    value=$(tweak_read "$SYSTEM_SYSRQ_STATE" prior-sysrq '')
    [[ "$value" =~ ^[0-9]+$ && "$value" -le 511 ]] ||
        die 'the recorded prior kernel.sysrq value is missing or invalid'
    managed_restore_all_keep_state "$SYSTEM_SYSRQ_STATE"
    sysctl -q -w "kernel.sysrq=$value"
    managed_forget_all "$SYSTEM_SYSRQ_STATE"
}

system_sysrq_summary() {
    printf 'Current values:\n- kernel.sysrq: %s' "$(system_sysrq_value)"
}

# The default row is a radio-style choice: selecting it while a preset is
# active restores the exact pre-suite file state and live value.
system_sysrq_default_title() { printf 'System default (sync only)'; }
system_sysrq_default_category() { system_sysrq_category; }
system_sysrq_default_desc() {
    cat <<EOF
Leaves Magic SysRq policy to the installed system settings. systemd ships
kernel.sysrq = 16, which permits only the emergency sync function; CachyOS
keeps that default.

Selecting this after another preset removes the suite's sysctl file and
restores the exact live value recorded before this suite changed it.

$(system_sysrq_summary)
EOF
}
system_sysrq_default_group() { printf 'sysrq-policy'; }
system_sysrq_default_applicable() { system_sysrq_available; }
system_sysrq_default_status() {
    if tweak_has_state "$SYSTEM_SYSRQ_STATE"; then
        printf 'off'
    elif [[ -e "$SYSTEM_SYSRQ_SYSCTL" ]]; then
        printf 'unmanaged'
    else
        printf 'on'
    fi
}
system_sysrq_default_apply() { system_sysrq_restore_default; }
system_sysrq_default_revert() { return 0; }

system_sysrq_reisub_title() { printf 'Emergency keys (REISUB)'; }
system_sysrq_reisub_category() { system_sysrq_category; }
system_sysrq_reisub_desc() {
    cat <<EOF
Sets kernel.sysrq to 244: keyboard control, sync, read-only remount,
process termination, and reboot/poweroff. This is exactly the subset the
classic Alt+SysRq R-E-I-S-U-B sequence needs to recover a frozen machine
without losing filesystem consistency.

Debug dumps, console log-level changes, and the other diagnostic
functions stay disabled. Anyone with physical keyboard access can trigger
the enabled functions — on a shared or kiosk machine, prefer the default.

$(system_sysrq_summary)
EOF
}
system_sysrq_reisub_group() { printf 'sysrq-policy'; }
system_sysrq_reisub_applicable() { system_sysrq_available; }
system_sysrq_reisub_status() { system_sysrq_profile_status reisub; }
system_sysrq_reisub_apply() { system_sysrq_apply_profile reisub; }
system_sysrq_reisub_revert() { system_sysrq_restore_default "${1:-}"; }

system_sysrq_full_title() { printf 'All SysRq functions'; }
system_sysrq_full_category() { system_sysrq_category; }
system_sysrq_full_desc() {
    cat <<EOF
Sets kernel.sysrq to 1, enabling every Magic SysRq function: the REISUB
emergency subset plus debug dumps, console log-level control, OOM-killer
invocation, and the rest.

Useful when debugging kernel or driver problems. The extra functions can
dump kernel state to the console and are available to anyone with
physical keyboard access, so prefer the REISUB preset for everyday use.

$(system_sysrq_summary)
EOF
}
system_sysrq_full_group() { printf 'sysrq-policy'; }
system_sysrq_full_applicable() { system_sysrq_available; }
system_sysrq_full_status() { system_sysrq_profile_status full; }
system_sysrq_full_apply() { system_sysrq_apply_profile full; }
system_sysrq_full_revert() { system_sysrq_restore_default "${1:-}"; }

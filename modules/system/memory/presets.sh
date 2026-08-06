# shellcheck shell=bash
# Memory and swap policy category for CachyOS.
#
# These are deliberately policy presets, not claims of universal performance.
# The kernel documents swappiness as an I/O-cost tradeoff and explicitly says
# the optimal value is workload-dependent. CachyOS also raises swappiness to
# 150 when zram initializes, so a persistent alternative must override both
# the normal sysctl pass and that later udev event.

register_module_doc system 'General OS' 'Memory & swap' \
    modules/system/memory/README.md

SYSTEM_TWEAKS+=(
    memory-cachyos
    memory-applications
    memory-capacity
)

system_memory_category() { printf 'Memory & swap'; }

: "${SYSTEM_MEMORY_STATE:=memory-policy}"
: "${SYSTEM_MEMORY_SYSCTL:=/etc/sysctl.d/99-cachyos-tweaks-memory.conf}"
: "${SYSTEM_MEMORY_UDEV:=/etc/udev/rules.d/99-cachyos-tweaks-memory.rules}"
readonly SYSTEM_MEMORY_STATE SYSTEM_MEMORY_SYSCTL SYSTEM_MEMORY_UDEV

system_memory_swap_active() {
    awk 'NR > 1 { found=1 } END { exit !found }' /proc/swaps 2>/dev/null
}

system_memory_zram_active() {
    awk 'NR > 1 && $1 ~ /^\/dev\/zram[0-9]+$/ { found=1 }
         END { exit !found }' /proc/swaps 2>/dev/null
}

system_memory_value() {
    local name=$1 fallback=${2:-unknown} value
    value=$(sysctl -n "$name" 2>/dev/null) || value=$fallback
    printf '%s' "$value"
}

system_memory_profile_value() {
    case $1 in
        applications) printf '60' ;;
        capacity) printf '180' ;;
        *) return 1 ;;
    esac
}

system_memory_sysctl_content() {
    local profile=$1 swappiness
    swappiness=$(system_memory_profile_value "$profile") || return 1
    cat <<EOF
# Managed by Tweaks for CachyOS. Choose another memory preset or CachyOS defaults
# in the application instead of editing this file.
# Profile: $profile
vm.swappiness = $swappiness
vm.page-cluster = 0
EOF
}

system_memory_udev_content() {
    local profile=$1 swappiness
    swappiness=$(system_memory_profile_value "$profile") || return 1
    cat <<EOF
# Managed by Tweaks for CachyOS. Keep the selected policy after CachyOS initializes zram.
# Profile: $profile
ACTION=="change", KERNEL=="zram[0-9]*", ATTR{initstate}=="1", SYSCTL{vm.swappiness}="$swappiness"
EOF
}

system_memory_live_profile() {
    local profile
    [[ -r "$SYSTEM_MEMORY_SYSCTL" && -r "$SYSTEM_MEMORY_UDEV" ]] || return 1
    for profile in applications capacity; do
        if [[ $(<"$SYSTEM_MEMORY_SYSCTL") == "$(system_memory_sysctl_content "$profile")" ]] &&
            [[ $(<"$SYSTEM_MEMORY_UDEV") == "$(system_memory_udev_content "$profile")" ]]; then
            printf '%s' "$profile"
            return 0
        fi
    done
    return 1
}

system_memory_recorded_profile() {
    local marker
    marker="$(tweak_dir "$SYSTEM_MEMORY_STATE")/profile"
    [[ -r "$marker" ]] || return 1
    IFS= read -r REPLY <"$marker"
    [[ "$REPLY" == applications || "$REPLY" == capacity ]]
}

system_memory_profile_status() {
    local profile=$1 current='' recorded='' managed expected
    if tweak_has_state "$SYSTEM_MEMORY_STATE"; then
        current=$(system_memory_live_profile 2>/dev/null || true)
        system_memory_recorded_profile && recorded=$REPLY
        managed=$(managed_status_paths "$SYSTEM_MEMORY_STATE" \
            "$SYSTEM_MEMORY_SYSCTL" "$SYSTEM_MEMORY_UDEV")
        if [[ "$profile" == "$current" ]]; then
            expected=$(system_memory_profile_value "$profile")
            if [[ "$managed" == on &&
                $(system_memory_value vm.swappiness) == "$expected" &&
                $(system_memory_value vm.page-cluster) == 0 ]]; then
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

    if [[ -e "$SYSTEM_MEMORY_SYSCTL" || -e "$SYSTEM_MEMORY_UDEV" ]]; then
        current=$(system_memory_live_profile 2>/dev/null || true)
        if [[ "$profile" == "$current" ]] ||
            [[ -z "$current" && "$profile" == applications ]]; then
            printf 'unmanaged'
        else
            printf 'off'
        fi
    else
        printf 'off'
    fi
}

system_memory_save_runtime() {
    local swappiness page_cluster
    tweak_has_state "$SYSTEM_MEMORY_STATE" && return 0
    swappiness=$(sysctl -n vm.swappiness 2>/dev/null) ||
        die 'cannot read the current vm.swappiness value'
    page_cluster=$(sysctl -n vm.page-cluster 2>/dev/null) ||
        die 'cannot read the current vm.page-cluster value'
    [[ "$swappiness" =~ ^[0-9]+$ && "$swappiness" -le 200 ]] ||
        die "invalid current vm.swappiness value: $swappiness"
    [[ "$page_cluster" =~ ^[0-9]+$ && "$page_cluster" -le 3 ]] ||
        die "invalid current vm.page-cluster value: $page_cluster"
    tweak_note "$SYSTEM_MEMORY_STATE" prior-swappiness "$swappiness"
    tweak_note "$SYSTEM_MEMORY_STATE" prior-page-cluster "$page_cluster"
}

system_memory_rollback_profile_files() {
    local had_state=$1 prior_profile=$2 dir
    if (( had_state )); then
        system_memory_sysctl_content "$prior_profile" |
            managed_write "$SYSTEM_MEMORY_STATE" "$SYSTEM_MEMORY_SYSCTL" 0644 || return 1
        system_memory_udev_content "$prior_profile" |
            managed_write "$SYSTEM_MEMORY_STATE" "$SYSTEM_MEMORY_UDEV" 0644 || return 1
        dir=$(tweak_dir "$SYSTEM_MEMORY_STATE")
        printf '%s\n' "$prior_profile" >"$dir/profile" || return 1
        chmod 0644 "$dir/profile" || return 1
    else
        managed_revert_all "$SYSTEM_MEMORY_STATE"
    fi
}

system_memory_apply_profile() {
    local profile=$1 swappiness dir prior_profile='' had_state=0
    local sysctl_source udev_source profile_tmp runtime_swappiness runtime_page_cluster
    swappiness=$(system_memory_profile_value "$profile") || die "unknown memory profile: $profile"
    if tweak_has_state "$SYSTEM_MEMORY_STATE"; then
        [[ $(managed_status_paths "$SYSTEM_MEMORY_STATE" \
            "$SYSTEM_MEMORY_SYSCTL" "$SYSTEM_MEMORY_UDEV") == on ]] ||
            die 'the current memory preset is incomplete or edited; restore defaults before switching'
        managed_check_drift "$SYSTEM_MEMORY_STATE"
        prior_profile=$(system_memory_live_profile) ||
            die 'the current managed memory preset cannot be identified'
        had_state=1
    fi
    system_memory_save_runtime
    runtime_swappiness=$(sysctl -n vm.swappiness 2>/dev/null) ||
        die 'cannot read vm.swappiness before applying the memory preset'
    runtime_page_cluster=$(sysctl -n vm.page-cluster 2>/dev/null) ||
        die 'cannot read vm.page-cluster before applying the memory preset'
    [[ "$runtime_swappiness" =~ ^[0-9]+$ && "$runtime_swappiness" -le 200 ]] ||
        die "invalid current vm.swappiness value: $runtime_swappiness"
    [[ "$runtime_page_cluster" =~ ^[0-9]+$ && "$runtime_page_cluster" -le 3 ]] ||
        die "invalid current vm.page-cluster value: $runtime_page_cluster"
    sysctl_source=$(mktemp) || die 'could not create memory-policy staging file'
    udev_source=$(mktemp) || { rm -f -- "$sysctl_source"; die 'could not create memory-policy staging file'; }
    system_memory_sysctl_content "$profile" >"$sysctl_source"
    system_memory_udev_content "$profile" >"$udev_source"
    if ! managed_install "$SYSTEM_MEMORY_STATE" "$SYSTEM_MEMORY_SYSCTL" 0644 "$sysctl_source" ||
        ! managed_install "$SYSTEM_MEMORY_STATE" "$SYSTEM_MEMORY_UDEV" 0644 "$udev_source"; then
        rm -f -- "$sysctl_source" "$udev_source"
        system_memory_rollback_profile_files "$had_state" "$prior_profile" ||
            die 'memory preset installation failed and its file rollback was incomplete'
        die 'could not install the complete memory preset; the prior state was restored'
    fi
    rm -f -- "$sysctl_source" "$udev_source"
    dir=$(tweak_dir "$SYSTEM_MEMORY_STATE")
    profile_tmp=$(mktemp "$dir/.profile.XXXXXX") ||
        {
            system_memory_rollback_profile_files "$had_state" "$prior_profile" || true
            die 'could not record the selected memory preset; the prior files were restored'
        }
    if ! printf '%s\n' "$profile" >"$profile_tmp" ||
        ! chmod 0644 "$profile_tmp" ||
        ! mv -fT -- "$profile_tmp" "$dir/profile"; then
        rm -f -- "$profile_tmp"
        system_memory_rollback_profile_files "$had_state" "$prior_profile" ||
            die 'recording the memory preset failed and its file rollback was incomplete'
        die 'could not record the selected memory preset; the prior files were restored'
    fi

    if ! sysctl -q -w "vm.swappiness=$swappiness" ||
        ! sysctl -q -w 'vm.page-cluster=0' ||
        ! udevadm control --reload; then
        sysctl -q -w "vm.swappiness=$runtime_swappiness" || true
        sysctl -q -w "vm.page-cluster=$runtime_page_cluster" || true
        system_memory_rollback_profile_files "$had_state" "$prior_profile" ||
            die 'applying the memory preset failed and its file rollback was incomplete'
        die 'could not activate the complete memory preset; the prior state was restored'
    fi
}

system_memory_restore_defaults() {
    local force=${1:-} swappiness page_cluster
    tweak_has_state "$SYSTEM_MEMORY_STATE" || return 0
    managed_check_drift "$SYSTEM_MEMORY_STATE" "$force"
    swappiness=$(tweak_read "$SYSTEM_MEMORY_STATE" prior-swappiness '')
    page_cluster=$(tweak_read "$SYSTEM_MEMORY_STATE" prior-page-cluster '')
    [[ "$swappiness" =~ ^[0-9]+$ && "$swappiness" -le 200 ]] ||
        die 'the recorded prior vm.swappiness value is missing or invalid'
    [[ "$page_cluster" =~ ^[0-9]+$ && "$page_cluster" -le 3 ]] ||
        die 'the recorded prior vm.page-cluster value is missing or invalid'
    managed_restore_all_keep_state "$SYSTEM_MEMORY_STATE"
    sysctl -q -w "vm.swappiness=$swappiness"
    sysctl -q -w "vm.page-cluster=$page_cluster"
    udevadm control --reload
    managed_forget_all "$SYSTEM_MEMORY_STATE"
}

system_memory_summary() {
    local swaps='none'
    if system_memory_swap_active; then
        swaps=$(awk 'NR > 1 {
            name=$1; sub("^/dev/", "", name)
            list = list (list ? ", " : "") name " (priority " $5 ")"
        } END { print list }' /proc/swaps)
    fi
    printf 'Current values:\n- Swappiness: %s\n- Page cluster: %s\n- Active swap: %s' \
        "$(system_memory_value vm.swappiness)" \
        "$(system_memory_value vm.page-cluster)" "$swaps"
}

# The default row is a radio-style choice: selecting it while an override is
# active restores the exact pre-suite files and live values.
system_memory_cachyos_title() { printf 'CachyOS defaults'; }
system_memory_cachyos_category() { system_memory_category; }
system_memory_cachyos_desc() {
    cat <<EOF
Leaves memory policy to the installed CachyOS settings. CachyOS configures
swappiness 100 during the normal sysctl pass and raises it to 150 when zram
initializes, with page-cluster 0 for compressed swap.

This is the safest baseline and the recommended place to start. Selecting it
after another preset restores the exact files and live values that existed
before this suite changed them.

$(system_memory_summary)
EOF
}
system_memory_cachyos_group() { printf 'memory-policy'; }
system_memory_cachyos_applicable() { return 0; }
system_memory_cachyos_status() {
    if tweak_has_state "$SYSTEM_MEMORY_STATE"; then
        printf 'off'
    elif [[ -e "$SYSTEM_MEMORY_SYSCTL" || -e "$SYSTEM_MEMORY_UDEV" ]]; then
        printf 'unmanaged'
    else
        printf 'on'
    fi
}
system_memory_cachyos_apply() { system_memory_restore_defaults; }
system_memory_cachyos_revert() { return 0; }

system_memory_applications_title() { printf 'Keep application memory resident'; }
system_memory_applications_category() { system_memory_category; }
system_memory_applications_desc() {
    cat <<EOF
Sets swappiness to 60 and page-cluster to 0. Anonymous application memory is
swapped less eagerly, while the kernel may reclaim more file cache instead.

This can suit machines with ample RAM and latency-sensitive applications.
Under real memory pressure it can reduce useful page cache, delay reclaim,
and make stalls sharper; it does not create more memory. This is a workload
preference, not a universal speed-up.

$(system_memory_summary)
EOF
}
system_memory_applications_group() { printf 'memory-policy'; }
system_memory_applications_applicable() { system_memory_swap_active; }
system_memory_applications_status() { system_memory_profile_status applications; }
system_memory_applications_apply() { system_memory_apply_profile applications; }
system_memory_applications_revert() { system_memory_restore_defaults "${1:-}"; }

system_memory_capacity_title() { printf 'Favor compressed-swap capacity'; }
system_memory_capacity_category() { system_memory_category; }
system_memory_capacity_desc() {
    cat <<EOF
Sets swappiness to 180 and page-cluster to 0. The kernel will move anonymous
pages into zram more readily to preserve file cache and stretch effective
memory capacity.

Only offered while zram swap is active. It can help memory-heavy multitasking,
but costs compression CPU time and may increase swap-in churn. If lower-
priority disk swap is also configured, sustained pressure can eventually
spill there. Avoid this preset for latency-critical workloads.

$(system_memory_summary)
EOF
}
system_memory_capacity_group() { printf 'memory-policy'; }
system_memory_capacity_applicable() { system_memory_zram_active; }
system_memory_capacity_status() { system_memory_profile_status capacity; }
system_memory_capacity_apply() { system_memory_apply_profile capacity; }
system_memory_capacity_revert() { system_memory_restore_defaults "${1:-}"; }

system_memory_extra_build() {
    EX_IDS+=(memory-report)
    EX_LABELS+=('Inspect memory and swap')
    EX_DISABLED+=(0)
    EX_CAPTURE+=(1)
    EX_PRIVILEGED+=(0)
    EX_DESC+=('Show current RAM availability, active swap devices and priorities,'$'\n''zram compression statistics, and the VM values controlled by these presets.'$'\n''This is read-only and is the best first step before choosing a policy.')
}

system_memory_report() {
    printf 'Memory\n'
    free -h
    printf '\nActive swap\n'
    if command -v swapon >/dev/null 2>&1; then
        swapon --show=NAME,TYPE,SIZE,USED,PRIO
    else
        cat /proc/swaps
    fi
    if command -v zramctl >/dev/null 2>&1 && system_memory_zram_active; then
        printf '\nZRAM\n'
        while IFS= read -r zram_device; do
            zramctl "$zram_device"
        done < <(awk 'NR > 1 && $1 ~ /^\/dev\/zram[0-9]+$/ { print $1 }' /proc/swaps)
    fi
    printf '\nVirtual-memory policy\n'
    printf 'vm.swappiness = %s\n' "$(system_memory_value vm.swappiness)"
    printf 'vm.page-cluster = %s\n' "$(system_memory_value vm.page-cluster)"
    printf 'vm.vfs_cache_pressure = %s (informational; presets do not change it)\n' \
        "$(system_memory_value vm.vfs_cache_pressure)"
    printf '\nPersistent override\n'
    if tweak_has_state "$SYSTEM_MEMORY_STATE"; then
        local profile='unknown'
        system_memory_recorded_profile && profile=$REPLY
        printf 'Managed profile: %s\n' "$profile"
        printf '%s\n%s\n' "$SYSTEM_MEMORY_SYSCTL" "$SYSTEM_MEMORY_UDEV"
    else
        printf 'None — CachyOS owns the active policy.\n'
    fi
}

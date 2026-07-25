# shellcheck shell=bash
# Shared power-service and Framework charge-limit implementations.

common_power_profiles_applicable() {
    pacman -Q power-profiles-daemon >/dev/null 2>&1
}

common_power_profiles_status() {
    local id=power-profiles-daemon
    if tweak_has_state "$id"; then
        if systemctl is-enabled power-profiles-daemon.service >/dev/null 2>&1 \
            && systemctl is-active power-profiles-daemon.service >/dev/null 2>&1; then
            printf 'on'
        else
            printf 'drifted'
        fi
    elif systemctl is-enabled power-profiles-daemon.service >/dev/null 2>&1 ||
        systemctl is-active power-profiles-daemon.service >/dev/null 2>&1; then
        printf 'unmanaged'
    else
        printf 'off'
    fi
}

common_power_profiles_apply() {
    local id=power-profiles-daemon prior_enabled prior_active
    prior_enabled=$(systemctl is-enabled power-profiles-daemon.service 2>/dev/null || true)
    prior_active=$(systemctl is-active power-profiles-daemon.service 2>/dev/null || true)
    tweak_note "$id" prior-enabled "${prior_enabled:-disabled}"
    tweak_note "$id" prior-active "${prior_active:-inactive}"
    systemctl enable --now power-profiles-daemon.service
}

common_power_profiles_revert() {
    local id=power-profiles-daemon
    if [[ $(tweak_read "$id" prior-enabled disabled) != enabled ]]; then
        systemctl disable power-profiles-daemon.service
    fi
    if [[ $(tweak_read "$id" prior-active inactive) != active ]]; then
        systemctl stop power-profiles-daemon.service
    fi
    rm -rf -- "$(tweak_dir "$id")"
}

common_framework_charge_tool() {
    command -v framework_tool >/dev/null 2>&1 || return 1
    printf 'framework_tool'
}

common_framework_charge_node() {
    local node
    if [[ -n ${COMMON_FRAMEWORK_CHARGE_NODE:-} ]]; then
        [[ -r "$COMMON_FRAMEWORK_CHARGE_NODE" && -w "$COMMON_FRAMEWORK_CHARGE_NODE" ]] ||
            return 1
        printf '%s' "$COMMON_FRAMEWORK_CHARGE_NODE"
        return 0
    fi
    for node in /sys/class/power_supply/BAT*/charge_control_end_threshold; do
        [[ -r "$node" && -w "$node" ]] || continue
        printf '%s' "$node"
        return 0
    done
    return 1
}

common_framework_charge_get() {
    local node output limit
    if node=$(common_framework_charge_node); then
        IFS= read -r limit <"$node"
    elif common_framework_charge_tool >/dev/null; then
        output=$(framework_tool --charge-limit 2>/dev/null) || return 1
        limit=$(sed -nE 's/.*Maximum ([0-9]+)%.*/\1/p' <<<"$output" | tail -n1)
    else
        return 1
    fi
    [[ "$limit" =~ ^[0-9]+$ && "$limit" -ge 25 && "$limit" -le 100 ]] ||
        return 1
    printf '%s' "$limit"
}

common_framework_charge_set() {
    local limit=$1 node
    [[ "$limit" =~ ^[0-9]+$ && "$limit" -ge 25 && "$limit" -le 100 ]] ||
        die "invalid Framework charge limit: $limit"
    if node=$(common_framework_charge_node); then
        printf '%s\n' "$limit" >"$node"
    elif common_framework_charge_tool >/dev/null; then
        framework_tool --charge-limit "$limit"
    else
        die 'a writable charge threshold or framework_tool is required'
    fi
}

common_framework_charge_status() {
    local current
    current=$(common_framework_charge_get) || { printf 'off'; return; }
    if tweak_has_state charge-limit-80; then
        [[ "$current" == 80 ]] && printf 'on' || printf 'drifted'
    elif [[ "$current" == 80 ]]; then
        printf 'unmanaged'
    else
        printf 'off'
    fi
}

common_framework_charge_apply() {
    local prior
    prior=$(common_framework_charge_get) ||
        die 'could not read the current Framework charge limit'
    tweak_note charge-limit-80 prior-limit "$prior"
    common_framework_charge_set 80
}

common_framework_charge_revert() {
    local prior
    prior=$(tweak_read charge-limit-80 prior-limit '')
    [[ "$prior" =~ ^[0-9]+$ && "$prior" -ge 25 && "$prior" -le 100 ]] ||
        die 'the recorded prior Framework charge limit is missing or invalid'
    common_framework_charge_set "$prior"
    rm -rf -- "$(tweak_dir charge-limit-80)"
}

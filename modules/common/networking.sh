# shellcheck shell=bash
# Shared networking mutation and revert implementations.

readonly COMMON_REGDOM_CONF=/etc/conf.d/wireless-regdom
readonly COMMON_NM_POWERSAVE_CONF=/etc/NetworkManager/conf.d/cachyos-tweaks-wifi-powersave.conf

common_networkmanager_restart_if_active() {
    if systemctl is-active --quiet NetworkManager.service 2>/dev/null; then
        systemctl restart NetworkManager.service
    fi
}

common_wifi_regdom_status() {
    if tweak_has_state wifi-regdom; then
        managed_status_all wifi-regdom
    elif grep -Eq '^WIRELESS_REGDOM=' "$COMMON_REGDOM_CONF" 2>/dev/null; then
        printf 'unmanaged'
    else
        printf 'off'
    fi
}

common_wifi_regdom_apply() {
    local current cc
    current=$(iw reg get 2>/dev/null | awk '/^country/ {print substr($2,1,2); exit}')
    if [[ -n ${CACHYOS_TWEAKS_REGDOM:-} ]]; then
        cc=$CACHYOS_TWEAKS_REGDOM
    elif [[ ${CACHYOS_TWEAKS_NONINTERACTIVE:-0} == 1 ]]; then
        die 'wireless country code was not supplied by the frontend'
    else
        printf 'Two-letter country code [%s]: ' "${current:-US}" >/dev/tty
        IFS= read -r cc </dev/tty || cc=''
        cc=${cc:-${current:-US}}
    fi
    cc=${cc^^}
    [[ "$cc" =~ ^[A-Z]{2}$ ]] || die "not a two-letter country code: $cc"
    managed_write wifi-regdom "$COMMON_REGDOM_CONF" 0644 <<EOF
# Set by Tweaks for CachyOS: persistent Wi-Fi regulatory domain.
WIRELESS_REGDOM="$cc"
EOF
    msg 'Regulatory domain will take effect through the normal boot configuration.'
}

common_wifi_regdom_revert() {
    managed_revert_all wifi-regdom
}

common_mt7922_present() {
    lspci -d 14c3: 2>/dev/null | grep -q . || [[ -d /sys/module/mt7921e ]]
}

common_mt7922_powersave_status() {
    tweak_file_status mt7922-powersave "$COMMON_NM_POWERSAVE_CONF"
}

common_mt7922_powersave_apply() {
    managed_write mt7922-powersave "$COMMON_NM_POWERSAVE_CONF" 0644 <<'EOF'
# Tweaks for CachyOS: disable Wi-Fi powersave (MT7922 firmware disconnect bug).
[connection]
wifi.powersave = 2
EOF
    common_networkmanager_restart_if_active
}

common_mt7922_powersave_revert() {
    managed_restore_all_keep_state mt7922-powersave
    common_networkmanager_restart_if_active
    managed_forget_all mt7922-powersave
}

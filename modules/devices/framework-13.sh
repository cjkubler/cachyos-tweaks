# shellcheck shell=bash
# Framework 13 (AMD Ryzen 7040 / 7840U) fixes for Tweaks for CachyOS.
# Sourced by tweaks.sh.
#
# Each tweak <id> (dashes allowed) defines, with dashes mapped to underscores:
#   fw13_<id>_title / _desc / _applicable / _status / _apply / _revert
# and registers itself in FW13_TWEAKS. Generic drift checking and state
# handling come from lib/common.sh managed-file helpers.

declare -ga FW13_TWEAKS=()
register_module_doc fw13 Hardware 'Framework 13' \
    modules/devices/framework-13.md

fw13_dmi_vendor()  { cat /sys/class/dmi/id/sys_vendor 2>/dev/null; }
fw13_dmi_product() { cat /sys/class/dmi/id/product_name 2>/dev/null; }

fw13_is_fw13_7840u() {
    [[ $(fw13_dmi_vendor) == Framework ]] &&
        [[ $(fw13_dmi_product) == 'Laptop 13 (AMD Ryzen 7040Series)' ]] &&
        grep -q '7840U' /proc/cpuinfo
}

fw13_model_line() {
    if fw13_is_fw13_7840u; then
        printf 'Framework 13, Ryzen 7 7840U, BIOS %s' \
            "$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo '?')"
    else
        printf '%s %s' "$(fw13_dmi_vendor)" "$(fw13_dmi_product)"
    fi
}

fw13_detect() { fw13_is_fw13_7840u; }

# ---------------------------------------------------------------------------
# Tweak: power-profiles-daemon
# PPD is the platform-recommended daemon for Phoenix (AMD and Framework
# discourage TLP). Since kernel 6.14 amd_pstate defaults Ryzen EPP to
# balance_performance, so the old "EPP stuck at performance" rationale is
# gone — PPD still adds AC/battery profile switching, platform_profile
# control and the ABM hooks.
# ---------------------------------------------------------------------------
FW13_TWEAKS+=(power-profiles-daemon)

fw13_power_profiles_daemon_title() { printf 'Enable power-profiles-daemon (battery/EPP management)'; }
fw13_power_profiles_daemon_desc() {
    cat <<'EOF'
power-profiles-daemon is the recommended power daemon for this platform
(AMD and Framework discourage TLP here: it fights the kernel's
platform-profile/EPP path). It switches EPP and the ACPI platform profile
between AC and battery and integrates panel power savings. Apply enables
and starts the service; revert restores its previous enable/active state
exactly.
EOF
}
fw13_power_profiles_daemon_applicable() { common_power_profiles_applicable; }
fw13_power_profiles_daemon_status() { common_power_profiles_status; }
fw13_power_profiles_daemon_apply() { common_power_profiles_apply; }
fw13_power_profiles_daemon_revert() { common_power_profiles_revert; }

# ---------------------------------------------------------------------------
# Tweak: abm-color-fix
# PPD enables amdgpu Adaptive Backlight Management in balanced/power-saver on
# battery, which visibly desaturates colors. Block that action via a PPD
# service drop-in. By-design behavior, so this stays a user choice.
# ---------------------------------------------------------------------------
FW13_TWEAKS+=(abm-color-fix)
readonly FW13_ABM_DROPIN=/etc/systemd/system/power-profiles-daemon.service.d/cachyos-tweaks-abm.conf

fw13_abm_color_fix_title() { printf 'Keep colors accurate on battery (block ABM dimming)'; }
fw13_abm_color_fix_desc() {
    cat <<'EOF'
power-profiles-daemon enables amdgpu Adaptive Backlight Management on battery
in the balanced and power-saver profiles, which washes out colors to save a
little power. This drop-in starts PPD with
--block-action=amdgpu_panel_power so panel colors stay accurate. Slightly
higher battery drain on battery power. Blocking freezes the CURRENT ABM
level, so switch to the performance profile once right after applying if
the panel was already dimmed.
EOF
}
fw13_abm_color_fix_applicable() { pacman -Q power-profiles-daemon >/dev/null 2>&1; }
fw13_abm_color_fix_status() { tweak_file_status abm-color-fix "$FW13_ABM_DROPIN"; }
fw13_abm_color_fix_apply() {
    managed_write abm-color-fix "$FW13_ABM_DROPIN" 0644 <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/power-profiles-daemon --block-action=amdgpu_panel_power
EOF
    systemctl daemon-reload
    systemctl try-restart power-profiles-daemon.service
}
fw13_abm_color_fix_revert() {
    managed_restore_all_keep_state abm-color-fix
    systemctl daemon-reload
    systemctl try-restart power-profiles-daemon.service
    managed_forget_all abm-color-fix
}

# ---------------------------------------------------------------------------
# Tweak: amdgpu-no-psr
# Panel Self Refresh handshake bugs on Phoenix cause flicker and freezes on
# wake (DMUB errors in the journal; drm/amd#3647, still open 2026). Kernel
# 6.12 additionally enabled Panel Replay on Phoenix eDP and regressed
# flicker, so the mask is 0x410 (PSR + Panel Replay), not just 0x10.
# Regressions recur on brand-new kernels that CachyOS ships immediately
# (e.g. 7.0.0/7.0.1 froze 7840U machines; fixed in 7.0.2).
# ---------------------------------------------------------------------------
FW13_TWEAKS+=(amdgpu-no-psr)
fw13_amdgpu_no_psr_title() { printf 'Disable amdgpu Panel Replay + PSR (flicker / freeze fix)'; }
fw13_amdgpu_no_psr_desc() {
    cat <<'EOF'
Sets amdgpu dcdebugmask=0x410, disabling Panel Self Refresh and Panel
Replay. Apply this if you see flicker, stutter, or full freezes shortly
after waking from suspend (journal shows DMUB / flip_done timed out
errors) — a recurring regression on brand-new kernels; on 6.12+ flicker
is usually Panel Replay (the 0x400 bit). Costs some battery. Rebuilds the
initramfs; takes effect after reboot. If a freeze already happened, a
live GPU reset also works:
  cat /sys/kernel/debug/dri/1/amdgpu_gpu_recover
EOF
}
fw13_amdgpu_no_psr_applicable() { [[ -d /sys/module/amdgpu ]] || lsmod | grep -q '^amdgpu'; }
fw13_amdgpu_no_psr_status() { common_amdgpu_no_psr_status; }
fw13_amdgpu_no_psr_apply() { common_amdgpu_no_psr_apply; }
fw13_amdgpu_no_psr_revert() { common_amdgpu_no_psr_revert; }

# ---------------------------------------------------------------------------
# Tweak: headphone-pops-fix
# HDA codec runtime power-save cycling causes pops/clicks on the 3.5mm jack
# when audio starts/stops. Deliberate power/noise trade-off.
# ---------------------------------------------------------------------------
FW13_TWEAKS+=(headphone-pops-fix)
readonly FW13_HDA_CONF=/etc/modprobe.d/cachyos-tweaks-hda-powersave.conf

fw13_headphone_pops_fix_title() { printf 'Stop 3.5mm jack pops (disable HDA power save)'; }
fw13_headphone_pops_fix_desc() {
    cat <<'EOF'
The HDA codec powers down when idle and its wake/sleep cycling produces
audible pops or buzz on the headphone jack. Sets snd_hda_intel power_save=0
to keep the codec awake. Costs a little battery. Takes effect after reboot
(or reloading the audio modules).
EOF
}
fw13_headphone_pops_fix_applicable() { [[ -d /sys/module/snd_hda_intel ]]; }
fw13_headphone_pops_fix_status() { tweak_file_status headphone-pops-fix "$FW13_HDA_CONF"; }
fw13_headphone_pops_fix_apply() {
    if [[ -r /sys/module/snd_hda_intel/parameters/power_save ]]; then
        local prior
        IFS= read -r prior </sys/module/snd_hda_intel/parameters/power_save
        [[ "$prior" =~ ^[0-9]+$ ]] &&
            tweak_note headphone-pops-fix prior-power-save "$prior"
    fi
    managed_write headphone-pops-fix "$FW13_HDA_CONF" 0644 <<'EOF'
# Keep the HDA codec awake: stops pop/click on the 3.5mm jack.
options snd_hda_intel power_save=0
EOF
    # Apply immediately where possible; persistent via the file either way.
    if [[ -w /sys/module/snd_hda_intel/parameters/power_save ]]; then
        printf '0\n' >/sys/module/snd_hda_intel/parameters/power_save
    fi
}
fw13_headphone_pops_fix_revert() {
    local prior
    prior=$(tweak_read headphone-pops-fix prior-power-save '')
    if [[ -w /sys/module/snd_hda_intel/parameters/power_save ]]; then
        [[ "$prior" =~ ^[0-9]+$ ]] ||
            die 'the recorded prior HDA power-save value is missing or invalid'
        printf '%s\n' "$prior" >/sys/module/snd_hda_intel/parameters/power_save
    fi
    managed_revert_all headphone-pops-fix
}

# ---------------------------------------------------------------------------
# Tweak: rfkill-before-sleep
# Workaround for the "reboots instead of resuming" failure attributed to the
# Wi-Fi module: block radios before suspend, unblock after. Only needed if
# that symptom actually occurs.
# ---------------------------------------------------------------------------
FW13_TWEAKS+=(rfkill-before-sleep)
readonly FW13_RFKILL_UNIT=/etc/systemd/system/rfkill-before-sleep.service

fw13_rfkill_before_sleep_title() { printf 'Block radios during suspend (reboot-on-resume fix)'; }
fw13_rfkill_before_sleep_desc() {
    cat <<'EOF'
Some Framework 13 AMD machines occasionally reboot instead of resuming, a
failure attributed to the RZ616/MT7922 Wi-Fi module. This unit
rfkill-blocks all radios before sleep and unblocks them on resume. Only
apply if you actually see reboot-instead-of-resume; it briefly delays
Wi-Fi reconnect after waking. Check first that no HDMI/DP expansion card
sits in the front-left slot — that placement causes the same symptom.
EOF
}
fw13_rfkill_before_sleep_applicable() { command -v rfkill >/dev/null; }
fw13_rfkill_before_sleep_status() {
    local status
    status=$(tweak_file_status rfkill-before-sleep "$FW13_RFKILL_UNIT")
    if [[ "$status" == on ]] &&
        ! systemctl is-enabled --quiet rfkill-before-sleep.service 2>/dev/null; then
        printf 'drifted'
    else
        printf '%s' "$status"
    fi
}
fw13_rfkill_before_sleep_apply() {
    tweak_note rfkill-before-sleep was-enabled \
        "$(systemctl is-enabled --quiet rfkill-before-sleep.service 2>/dev/null && printf 1 || printf 0)"
    tweak_note rfkill-before-sleep was-active \
        "$(systemctl is-active --quiet rfkill-before-sleep.service 2>/dev/null && printf 1 || printf 0)"
    managed_write rfkill-before-sleep "$FW13_RFKILL_UNIT" 0644 <<'EOF'
[Unit]
Description=Disable wifi and bluetooth before suspend
DefaultDependencies=no
StopWhenUnneeded=yes
Before=sleep.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/rfkill block all
ExecStop=/usr/bin/rfkill unblock all

[Install]
WantedBy=sleep.target
EOF
    systemctl daemon-reload
    systemctl enable rfkill-before-sleep.service
}
fw13_rfkill_before_sleep_revert() {
    local was_enabled was_active
    was_enabled=$(tweak_read rfkill-before-sleep was-enabled 0)
    was_active=$(tweak_read rfkill-before-sleep was-active 0)
    managed_restore_all_keep_state rfkill-before-sleep
    systemctl daemon-reload
    if [[ "$was_enabled" == 1 ]]; then
        systemctl enable rfkill-before-sleep.service
    else
        systemctl disable rfkill-before-sleep.service 2>/dev/null || true
    fi
    if [[ "$was_active" == 1 ]]; then
        if ! systemctl is-active --quiet rfkill-before-sleep.service; then
            systemctl start rfkill-before-sleep.service
        fi
    else
        systemctl stop rfkill-before-sleep.service 2>/dev/null || true
    fi
    managed_forget_all rfkill-before-sleep
}

# ---------------------------------------------------------------------------
# Tweak: kbd-backlight-restore
# The EC forgets the keyboard backlight level across suspend. Save it before
# sleep and restore it on resume via a system-sleep hook. Long-standing
# cosmetic issue with no official fix.
# ---------------------------------------------------------------------------
FW13_TWEAKS+=(kbd-backlight-restore)
readonly FW13_KBD_HOOK=/usr/lib/systemd/system-sleep/cachyos-tweaks-kbd-backlight
readonly FW13_KBD_LED='/sys/class/leds/chromeos::kbd_backlight/brightness'

fw13_kbd_backlight_restore_title() { printf 'Restore keyboard backlight after suspend'; }
fw13_kbd_backlight_restore_desc() {
    cat <<'EOF'
The embedded controller resets the keyboard backlight across suspend, so it
comes back off/default after waking. This sleep hook saves the level before
suspend and restores it on resume. Purely cosmetic; harmless.
EOF
}
fw13_kbd_backlight_restore_applicable() { [[ -w "$FW13_KBD_LED" || -e "$FW13_KBD_LED" ]]; }
fw13_kbd_backlight_restore_status() { tweak_file_status kbd-backlight-restore "$FW13_KBD_HOOK"; }
fw13_kbd_backlight_restore_apply() {
    managed_write kbd-backlight-restore "$FW13_KBD_HOOK" 0755 <<'EOF'
#!/bin/bash
# cachyos-tweaks: keep the keyboard backlight level across suspend.
LED='/sys/class/leds/chromeos::kbd_backlight/brightness'
STATE=/var/lib/cachyos-tweaks/kbd-backlight-restore/saved-level
case $1 in
    pre)
        [[ -r "$LED" ]] && cat "$LED" >"$STATE" 2>/dev/null
        ;;
    post)
        [[ -r "$STATE" && -w "$LED" ]] && cat "$STATE" >"$LED" 2>/dev/null
        ;;
esac
exit 0
EOF
}
fw13_kbd_backlight_restore_revert() {
    managed_revert_all kbd-backlight-restore
}

# ---------------------------------------------------------------------------
# Tweak: wifi-regdom
# The WCN785x (and MT7922) leave 6 GHz disabled until a regulatory domain is
# set. Desktop stacks usually set it at runtime; this makes it persistent and
# deterministic from early boot.
# ---------------------------------------------------------------------------
FW13_TWEAKS+=(wifi-regdom)
fw13_wifi_regdom_title() { printf 'Persist Wi-Fi regulatory domain (6 GHz)'; }
fw13_wifi_regdom_desc() {
    cat <<'EOF'
6 GHz channels stay disabled while the regulatory domain is unset. On this
system it is usually set at runtime by the network stack, but pinning it in
/etc/conf.d/wireless-regdom makes 6 GHz deterministic from early boot.
Prompts for your two-letter country code (default: the currently active one).
EOF
}
fw13_wifi_regdom_applicable() {
    pacman -Q wireless-regdb >/dev/null 2>&1 && [[ -d /sys/class/net ]] \
        && ls /sys/class/net/*/wireless >/dev/null 2>&1
}
fw13_wifi_regdom_status() { common_wifi_regdom_status; }
fw13_wifi_regdom_apply() { common_wifi_regdom_apply; }
fw13_wifi_regdom_revert() { common_wifi_regdom_revert; }

# ---------------------------------------------------------------------------
# Tweak: mt7922-powersave
# The RZ616 (MT7922) firmware has an open bug (mt76 issue #987): with Wi-Fi
# powersave on, the connection drops every 10-20 minutes. Same card and same
# mitigation as on the Yoga 7 MediaTek SKU and the FW16.
# ---------------------------------------------------------------------------
FW13_TWEAKS+=(mt7922-powersave)
fw13_mt7922_present() { common_mt7922_present; }

fw13_mt7922_powersave_title() { printf 'MediaTek Wi-Fi: disable powersave (disconnect fix)'; }
fw13_mt7922_powersave_desc() {
    cat <<'EOF'
The RZ616/MT7922 firmware has an open bug (mt76 issue #987): with Wi-Fi
powersave on, the connection drops every 10-20 minutes. Disabling
powersave in NetworkManager stabilizes it completely, for a small
idle-battery cost. Still unfixed as of mid-2026, so worth applying
preemptively if you see periodic drops.
EOF
}
fw13_mt7922_powersave_applicable() { fw13_mt7922_present && [[ -d /etc/NetworkManager ]]; }
fw13_mt7922_powersave_status() { common_mt7922_powersave_status; }
fw13_mt7922_powersave_apply() { common_mt7922_powersave_apply; }
fw13_mt7922_powersave_revert() { common_mt7922_powersave_revert; }

# ---------------------------------------------------------------------------
# Tweak: charge-limit-80 — EC battery charge cap (persists in the EC)
# ---------------------------------------------------------------------------
FW13_TWEAKS+=(charge-limit-80)

fw13_charge_tool() { common_framework_charge_tool; }
fw13_charge_limit_80_title() { printf 'Limit battery charge to 80%% (longevity)'; }
fw13_charge_limit_80_desc() {
    cat <<'EOF'
Caps charging at 80% through the kernel's charge-threshold interface or
framework_tool (from the framework-system package). The setting persists
in the EC until a full power-off with AC unplugged. Apply records the
current threshold; revert restores that exact value.
EOF
}
fw13_charge_limit_80_applicable() { common_framework_charge_get >/dev/null; }
fw13_charge_limit_80_status() { common_framework_charge_status; }
fw13_charge_limit_80_apply() { common_framework_charge_apply; }
fw13_charge_limit_80_revert() { common_framework_charge_revert; }

# ---------------------------------------------------------------------------
# Tweak: storage-card-uas-quirk
# The 250 GB Storage Expansion Card (13fe:6500) can crash the USB controller
# under UAS; the ArchWiki fix forces the usb-storage fallback driver.
# ---------------------------------------------------------------------------
FW13_TWEAKS+=(storage-card-uas-quirk)
readonly FW13_UAS_CONF=/etc/modprobe.d/cachyos-tweaks-storage-card.conf

fw13_storage_card_uas_quirk_title() { printf 'Storage Expansion Card stability (disable UAS)'; }
fw13_storage_card_uas_quirk_desc() {
    cat <<'EOF'
The 250 GB Storage Expansion Card (13fe:6500) can hang or crash the USB
controller when driven over UAS. This forces it onto the plain
usb-storage path (slightly slower, stable). Only useful if you use that
card and see USB resets/hangs in the journal. Takes effect on next
card plug (or reboot).
EOF
}
fw13_storage_card_uas_quirk_applicable() { return 0; }
fw13_storage_card_uas_quirk_status() { tweak_file_status storage-card-uas-quirk "$FW13_UAS_CONF"; }
fw13_storage_card_uas_quirk_apply() {
    managed_write storage-card-uas-quirk "$FW13_UAS_CONF" 0644 <<'EOF'
# cachyos-tweaks: Storage Expansion Card (13fe:6500) — force usb-storage.
options usb-storage quirks=13fe:6500:u
EOF
}
fw13_storage_card_uas_quirk_revert() { managed_revert_all storage-card-uas-quirk; }

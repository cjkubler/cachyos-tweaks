# shellcheck shell=bash
# Lenovo Yoga 7 14AHP9 (Ryzen 7 8840HS) fixes for Tweaks for CachyOS.
# Sourced by tweaks.sh; see lib/common.sh for the tweak contract.

declare -ga YOGA_TWEAKS=()
register_module_doc yoga Hardware 'Lenovo Yoga 7 14AHP9' \
    modules/devices/lenovo-yoga-7-14ahp9.md

yoga_detect() {
    [[ $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) == LENOVO ]] || return 1
    local version family
    version=$(cat /sys/class/dmi/id/product_version 2>/dev/null)
    family=$(cat /sys/class/dmi/id/product_family 2>/dev/null)
    [[ "$version" == *'Yoga 7'*'14AHP9'* || "$family" == *'Yoga 7'*'14AHP9'* ]]
}

yoga_model_line() { printf 'Lenovo Yoga 7 14AHP9 — Ryzen 7 8840HS'; }

# ---------------------------------------------------------------------------
# Tweak: lid-touchpad-inhibit
# The Yoga 7 keeps its touchpad live with the lid closed (also true on
# Windows), which can produce ghost clicks. Inhibit touchpad input devices on
# lid close and restore them on open — only ever re-enabling devices this
# hook inhibited itself, so the user's own touchpad setting is respected.
# ---------------------------------------------------------------------------
YOGA_TWEAKS+=(lid-touchpad-inhibit)
readonly YOGA_LID_EVENT=/etc/acpi/events/cachyos-tweaks-lid
readonly YOGA_LID_HANDLER=/etc/acpi/cachyos-tweaks-lid.sh

yoga_lid_touchpad_inhibit_title() { printf 'Disable touchpad while the lid is closed (ghost clicks)'; }
yoga_lid_touchpad_inhibit_desc() {
    cat <<'EOF'
The touchpad stays live with the lid closed, which can cause ghost clicks
(seen on Windows too). This installs an acpid lid hook that inhibits
touchpad input devices at the kernel level on lid close and restores them
on open. It only re-enables devices it inhibited itself, so a touchpad you
disabled in system settings stays disabled. Installs/enables acpid.
EOF
}
yoga_lid_touchpad_inhibit_applicable() {
    [[ -d /proc/acpi/button/lid ]] || return 1
    local device
    for device in /sys/class/input/input*/name; do
        [[ -r "$device" ]] || continue
        local name
        IFS= read -r name <"$device"
        [[ ${name,,} == *touchpad* ]] && return 0
    done
    return 1
}
yoga_lid_touchpad_inhibit_status() {
    local status
    status=$(tweak_file_status lid-touchpad-inhibit "$YOGA_LID_EVENT" "$YOGA_LID_HANDLER")
    if [[ "$status" == on ]] && ! systemctl is-enabled acpid.service >/dev/null 2>&1; then
        printf 'drifted'
    else
        printf '%s' "$status"
    fi
}
yoga_lid_touchpad_inhibit_apply() {
    local id=lid-touchpad-inhibit
    if ! pacman -Q acpid >/dev/null 2>&1; then
        msg 'Installing acpid...'
        pacman -S --needed --noconfirm acpid
        tweak_note "$id" acpid-installed-by-suite 1
    fi
    if systemctl is-enabled acpid.service >/dev/null 2>&1; then
        tweak_note "$id" acpid-was-enabled 1
    else
        tweak_note "$id" acpid-was-enabled 0
    fi
    if systemctl is-active acpid.service >/dev/null 2>&1; then
        tweak_note "$id" acpid-was-active 1
    else
        tweak_note "$id" acpid-was-active 0
    fi
    managed_write "$id" "$YOGA_LID_HANDLER" 0755 <<'EOF'
#!/bin/bash
# cachyos-tweaks: inhibit touchpads while the lid is closed. Only devices
# inhibited here are restored, so user-level touchpad settings are honored.
STATE_DIR=/var/lib/cachyos-tweaks/lid-touchpad-inhibit
STATE=$STATE_DIR/inhibited-by-us
case $3 in
    close)
        mkdir -p "$STATE_DIR"
        : >"$STATE.tmp"
        for dev in /sys/class/input/input*; do
            [[ -r "$dev/name" && -w "$dev/inhibited" ]] || continue
            IFS= read -r name <"$dev/name"
            [[ ${name,,} == *touchpad* ]] || continue
            IFS= read -r cur <"$dev/inhibited"
            if [[ "$cur" == 0 ]]; then
                printf '%s\n' "$dev" >>"$STATE.tmp"
                printf '1\n' >"$dev/inhibited"
            fi
        done
        mv -f "$STATE.tmp" "$STATE"
        ;;
    open)
        [[ -r "$STATE" ]] || exit 0
        while IFS= read -r dev; do
            [[ -w "$dev/inhibited" ]] && printf '0\n' >"$dev/inhibited"
        done <"$STATE"
        rm -f "$STATE"
        ;;
esac
exit 0
EOF
    managed_write "$id" "$YOGA_LID_EVENT" 0644 <<EOF
# cachyos-tweaks: forward lid open/close to the touchpad inhibit handler.
event=button/lid.*
action=$YOGA_LID_HANDLER %e
EOF
    systemctl enable --now acpid.service
    systemctl try-restart acpid.service
}
yoga_lid_touchpad_inhibit_revert() {
    local id=lid-touchpad-inhibit
    # Un-inhibit anything the hook left inhibited before removing state.
    local state
    state=$(tweak_dir "$id")/inhibited-by-us
    if [[ -r "$state" ]]; then
        local dev
        while IFS= read -r dev; do
            [[ -w "$dev/inhibited" ]] && printf '0\n' >"$dev/inhibited"
        done <"$state"
    fi
    local was_enabled was_active remove_pkg
    was_enabled=$(tweak_read "$id" acpid-was-enabled 0)
    was_active=$(tweak_read "$id" acpid-was-active 0)
    remove_pkg=$(tweak_read "$id" acpid-installed-by-suite 0)
    managed_restore_all_keep_state "$id"
    if [[ "$was_enabled" == 1 ]]; then
        systemctl enable acpid.service 2>/dev/null || true
    else
        systemctl disable acpid.service 2>/dev/null || true
    fi
    if [[ "$was_active" == 1 ]]; then
        systemctl restart acpid.service
    else
        systemctl stop acpid.service 2>/dev/null || true
    fi
    if [[ "$remove_pkg" == 1 ]] && pacman -Q acpid >/dev/null 2>&1; then
        pacman -R --noconfirm acpid
    fi
    managed_forget_all "$id"
}

# ---------------------------------------------------------------------------
# Tweak: battery-conservation
# ideapad firmware supports a fixed 80%-stop/75%-start cap only; the value
# persists in the EC.
# ---------------------------------------------------------------------------
YOGA_TWEAKS+=(battery-conservation)

yoga_conservation_node() {
    local n
    if [[ -n ${YOGA_CONSERVATION_NODE:-} ]]; then
        [[ -w "$YOGA_CONSERVATION_NODE" || -r "$YOGA_CONSERVATION_NODE" ]] ||
            return 1
        printf '%s' "$YOGA_CONSERVATION_NODE"
        return 0
    fi
    for n in /sys/bus/platform/drivers/ideapad_acpi/VPC*/conservation_mode; do
        [[ -w "$n" || -r "$n" ]] && { printf '%s' "$n"; return 0; }
    done
    return 1
}
yoga_battery_conservation_title() { printf 'Battery conservation mode (cap charge at 80%%)'; }
yoga_battery_conservation_desc() {
    cat <<'EOF'
Lenovo's conservation mode caps charging at 80% (resume at 75%) to slow
battery wear — the firmware only supports this fixed threshold, not
arbitrary values. Set via the ideapad_acpi driver; persists in the
embedded controller until turned off.
EOF
}
yoga_battery_conservation_applicable() { yoga_conservation_node >/dev/null; }
yoga_battery_conservation_status() {
    local node val
    node=$(yoga_conservation_node) || { printf 'off'; return; }
    IFS= read -r val <"$node" 2>/dev/null || val=0
    if tweak_has_state battery-conservation; then
        [[ "$val" == 1 ]] && printf 'on' || printf 'drifted'
    elif [[ "$val" == 1 ]]; then
        printf 'unmanaged'
    else
        printf 'off'
    fi
}
yoga_battery_conservation_apply() {
    local node prior
    node=$(yoga_conservation_node) || die 'conservation_mode node not found'
    IFS= read -r prior <"$node"
    [[ "$prior" == 0 || "$prior" == 1 ]] ||
        die "invalid conservation_mode value: $prior"
    tweak_note battery-conservation prior-value "$prior"
    printf '1\n' >"$node"
}
yoga_battery_conservation_revert() {
    local node prior
    node=$(yoga_conservation_node) || die 'conservation_mode node not found'
    prior=$(tweak_read battery-conservation prior-value '')
    [[ "$prior" == 0 || "$prior" == 1 ]] ||
        die 'the recorded prior conservation mode is missing or invalid'
    printf '%s\n' "$prior" >"$node"
    rm -rf -- "$(tweak_dir battery-conservation)"
}

# ---------------------------------------------------------------------------
# Tweak: amd-sfh-sensor-fix — auto-rotate accelerometer not detected
# ---------------------------------------------------------------------------
YOGA_TWEAKS+=(amd-sfh-sensor-fix)
readonly YOGA_SFH_CONF=/etc/modprobe.d/cachyos-tweaks-amd-sfh.conf

yoga_amd_sfh_sensor_fix_title() { printf 'Force accelerometer on (auto-rotate fix)'; }
yoga_amd_sfh_sensor_fix_desc() {
    cat <<'EOF'
If screen auto-rotation does not work and the journal shows amd_sfh
"No sensors marked active!", this forces the accelerometer on with
amd_sfh sensor_mask=1. Only needed on units whose firmware misreports
the sensor list; requires iio-sensor-proxy (KDE reads it on Wayland).
Takes effect after reboot.
EOF
}
yoga_amd_sfh_sensor_fix_applicable() { [[ -d /sys/module/amd_sfh ]] || modinfo amd_sfh >/dev/null 2>&1; }
yoga_amd_sfh_sensor_fix_status() { tweak_file_status amd-sfh-sensor-fix "$YOGA_SFH_CONF"; }
yoga_amd_sfh_sensor_fix_apply() {
    managed_write amd-sfh-sensor-fix "$YOGA_SFH_CONF" 0644 <<'EOF'
# cachyos-tweaks: force the accelerometer active (auto-rotate fix).
options amd_sfh sensor_mask=1
EOF
    pacman -Q iio-sensor-proxy >/dev/null 2>&1 || warn 'install iio-sensor-proxy for auto-rotate'
}
yoga_amd_sfh_sensor_fix_revert() { managed_revert_all amd-sfh-sensor-fix; }

# ---------------------------------------------------------------------------
# Tweak: amdgpu-no-psr — panel flicker/stutter mitigation (opt-in)
# ---------------------------------------------------------------------------
YOGA_TWEAKS+=(amdgpu-no-psr)
yoga_amdgpu_no_psr_title() { printf 'Disable amdgpu Panel Replay + PSR (flicker fix)'; }
yoga_amdgpu_no_psr_desc() {
    cat <<'EOF'
Sets amdgpu dcdebugmask=0x410, disabling Panel Replay and PSR — the
mitigation for eDP flicker or "frozen until the mouse moves" stutter.
Upstream already keeps PSR-SU off on eDP (kernels >= 6.14); flicker on
modern kernels is usually Panel Replay (the 0x400 bit). The OLED SKU
reports no PSR support at all, so this mostly matters on the IPS panel.
Apply on symptom only; costs some battery. Rebuilds the initramfs;
reboot to take effect.
EOF
}
yoga_amdgpu_no_psr_applicable() { [[ -d /sys/module/amdgpu ]]; }
yoga_amdgpu_no_psr_status() { common_amdgpu_no_psr_status; }
yoga_amdgpu_no_psr_apply() { common_amdgpu_no_psr_apply; }
yoga_amdgpu_no_psr_revert() { common_amdgpu_no_psr_revert; }

# ---------------------------------------------------------------------------
# Tweak: rtw89-stability — Wi-Fi disconnect mitigation (opt-in)
# ---------------------------------------------------------------------------
YOGA_TWEAKS+=(rtw89-stability)
readonly YOGA_RTW_CONF=/etc/modprobe.d/cachyos-tweaks-rtw89.conf
readonly YOGA_NM_CONF=/etc/NetworkManager/conf.d/cachyos-tweaks-wifi-powersave.conf

yoga_rtw89_stability_title() { printf 'Realtek Wi-Fi stability (no ASPM, no powersave)'; }
yoga_rtw89_stability_desc() {
    cat <<'EOF'
For random disconnects or firmware crashes on the RTL8852CE (rtw89):
disables PCIe ASPM L1 for the card and Wi-Fi powersave in
NetworkManager. Costs idle battery — only apply if the connection
actually drops. Most firmware crash bugs are fixed by keeping
linux-firmware current and kernel >= 6.13. Reboot (or reload the module
and restart NetworkManager) to take effect. Only the Realtek SKU of
this laptop; MediaTek MT7922 units have their own tweaks below.
EOF
}
yoga_rtw89_stability_applicable() { lspci -d 10ec: 2>/dev/null | grep -qi 'c852\|8852' || [[ -d /sys/module/rtw89_8852ce ]]; }
yoga_rtw89_stability_status() { tweak_file_status rtw89-stability "$YOGA_RTW_CONF" "$YOGA_NM_CONF"; }
yoga_rtw89_stability_apply() {
    managed_write rtw89-stability "$YOGA_RTW_CONF" 0644 <<'EOF'
# cachyos-tweaks: RTL8852CE disconnect mitigation; costs idle power.
options rtw89_pci disable_aspm_l1=1
EOF
    managed_write rtw89-stability "$YOGA_NM_CONF" 0644 <<'EOF'
# cachyos-tweaks: disable Wi-Fi powersave (rtw89 stability).
[connection]
wifi.powersave = 2
EOF
    common_networkmanager_restart_if_active
}
yoga_rtw89_stability_revert() {
    managed_restore_all_keep_state rtw89-stability
    common_networkmanager_restart_if_active
    managed_forget_all rtw89-stability
}

# ---------------------------------------------------------------------------
# Tweaks: mt7922-* — MediaTek Wi-Fi SKU (mt7921e driver)
# ---------------------------------------------------------------------------
yoga_mt7922_present() { common_mt7922_present; }

YOGA_TWEAKS+=(mt7922-powersave)

yoga_mt7922_powersave_title() { printf 'MediaTek Wi-Fi: disable powersave (disconnect fix)'; }
yoga_mt7922_powersave_desc() {
    cat <<'EOF'
MT7922 firmware since late 2024 has an open bug (mt76 issue #987):
with Wi-Fi powersave on, the connection drops every 10-20 minutes.
Disabling powersave in NetworkManager stabilizes it completely, for a
small idle-battery cost. Still unfixed as of mid-2026, so this one is
worth applying preemptively on the MediaTek SKU.
EOF
}
yoga_mt7922_powersave_applicable() { yoga_mt7922_present; }
yoga_mt7922_powersave_status() { common_mt7922_powersave_status; }
yoga_mt7922_powersave_apply() { common_mt7922_powersave_apply; }
yoga_mt7922_powersave_revert() { common_mt7922_powersave_revert; }

YOGA_TWEAKS+=(mt7922-no-aspm)
readonly YOGA_MT_CONF=/etc/modprobe.d/cachyos-tweaks-mt7921e.conf

yoga_mt7922_no_aspm_title() { printf 'MediaTek Wi-Fi: disable ASPM (timeout/crash fix)'; }
yoga_mt7922_no_aspm_desc() {
    cat <<'EOF'
For mt7921e "Message ... timeout" firmware crashes, Wi-Fi dead after
suspend, or full stalls on the MT7922: disables PCIe ASPM for the card,
skipping the MCU wake path that trips the timeout. Costs idle battery —
apply on symptom only (the powersave tweak above covers the common
periodic-disconnect case). Reboot or module reload to take effect.
EOF
}
yoga_mt7922_no_aspm_applicable() { yoga_mt7922_present; }
yoga_mt7922_no_aspm_status() { tweak_file_status mt7922-no-aspm "$YOGA_MT_CONF"; }
yoga_mt7922_no_aspm_apply() {
    managed_write mt7922-no-aspm "$YOGA_MT_CONF" 0644 <<'EOF'
# cachyos-tweaks: MT7922 "Message timeout" mitigation; costs idle power.
options mt7921e disable_aspm=1
EOF
}
yoga_mt7922_no_aspm_revert() { managed_revert_all mt7922-no-aspm; }

# ---------------------------------------------------------------------------
# Tweak: bt-no-autosuspend — Bluetooth dead at boot / after resume (opt-in)
# ---------------------------------------------------------------------------
YOGA_TWEAKS+=(bt-no-autosuspend)
readonly YOGA_BT_CONF=/etc/modprobe.d/cachyos-tweaks-btusb.conf

yoga_bt_no_autosuspend_title() { printf 'Bluetooth: disable USB autosuspend (dead-BT fix)'; }
yoga_bt_no_autosuspend_desc() {
    cat <<'EOF'
If Bluetooth is off or unresponsive at boot or after resume, USB
autosuspend on btusb is the usual culprit. Sets btusb
enable_autosuspend=n; costs a little idle power. Kernels >= 6.10 also
self-recover the MT7922 controller after firmware crashes. Unrelated:
BT audio stutter while on 2.4 GHz Wi-Fi is a firmware coex limitation
with no fix — use a 5/6 GHz AP. Reboot to take effect.
EOF
}
yoga_bt_no_autosuspend_applicable() { [[ -d /sys/module/btusb ]] || modinfo btusb >/dev/null 2>&1; }
yoga_bt_no_autosuspend_status() { tweak_file_status bt-no-autosuspend "$YOGA_BT_CONF"; }
yoga_bt_no_autosuspend_apply() {
    managed_write bt-no-autosuspend "$YOGA_BT_CONF" 0644 <<'EOF'
# cachyos-tweaks: keep the BT controller out of USB autosuspend.
options btusb enable_autosuspend=n
EOF
}
yoga_bt_no_autosuspend_revert() { managed_revert_all bt-no-autosuspend; }

# ---------------------------------------------------------------------------
# Tweak: wmi-quiet — silence harmless lenovo WMI module load errors
# ---------------------------------------------------------------------------
YOGA_TWEAKS+=(wmi-quiet)
readonly YOGA_WMI_CONF=/etc/modprobe.d/cachyos-tweaks-lenovo-wmi.conf

yoga_wmi_quiet_title() { printf 'Silence lenovo WMI boot errors (cosmetic)'; }
yoga_wmi_quiet_desc() {
    cat <<'EOF'
lenovo_wmi_hotkey_utilities and lenovo_wmi_gamezone provide nothing on
this model — at best a "platform_profile probe failed" line at boot
(power profiles come from amd-pmf and keep working). The Arch Wiki
lists both as safe to blacklist on the 14AHP9. Purely cosmetic.
EOF
}
yoga_wmi_quiet_applicable() { yoga_detect; }
yoga_wmi_quiet_status() { tweak_file_status wmi-quiet "$YOGA_WMI_CONF"; }
yoga_wmi_quiet_apply() {
    managed_write wmi-quiet "$YOGA_WMI_CONF" 0644 <<'EOF'
# cachyos-tweaks: these fail to load on the Yoga 7 14AHP9; silence them.
blacklist lenovo_wmi_hotkey_utilities
blacklist lenovo_wmi_gamezone
EOF
}
yoga_wmi_quiet_revert() { managed_revert_all wmi-quiet; }

# ---------------------------------------------------------------------------
# Extra actions (read-only): fingerprint setup guidance, BIOS guidance
# ---------------------------------------------------------------------------

yoga_extra_build() {
    EX_IDS+=(fprint)
    EX_LABELS+=('Fingerprint reader: show setup guidance')
    EX_DISABLED+=(0)
    EX_CAPTURE+=(1)
    EX_PRIVILEGED+=(0)
    EX_DESC+=('This laptop ships with one of two readers: Goodix 27c6:650a (works
out of the box, libfprint >= 1.94.8) or EgisTec 1c7a:0583 (needs an
out-of-tree SDCP build — prints never persist with the stock driver).
Detects which is present and prints the matching path. Read-only.')
    EX_IDS+=(bios)
    EX_LABELS+=('BIOS: show version and update path')
    EX_DISABLED+=(0)
    EX_CAPTURE+=(1)
    EX_PRIVILEGED+=(0)
    EX_DESC+=('This model is not on LVFS, so fwupd cannot update its BIOS. Shows
the installed version and the manual update path. Read-only.')
}

yoga_fprint_guidance() {
    msg "${C_BOLD}Fingerprint on the Yoga 7 14AHP9${C_RESET}"
    msg ''
    if lsusb 2>/dev/null | grep -qi '27c6:650a'; then
        msg 'Reader detected: Goodix MOC (27c6:650a) — supported by mainline'
        msg 'libfprint since 1.94.8 (match-on-chip; no SDCP involved).'
        msg ''
        if pacman -Q fprintd >/dev/null 2>&1; then
            msg "Installed: $(pacman -Q fprintd) / $(pacman -Q libfprint)"
        else
            msg 'Install first:  pacman -S fprintd'
        fi
        cat <<'EOF'

  1. Enroll:  fprintd-enroll     (or System Settings > Users in KDE)
  2. Verify:  fprintd-verify

Prints are stored on the sensor itself. If enrollment fails, make sure
libfprint is >= 1.94.8 — older releases predate this device ID.
EOF
    elif lsusb 2>/dev/null | grep -qi '1c7a:0583'; then
        msg 'Reader detected: EgisTec/LighTuning ETU905A88-E (1c7a:0583).'
        cat <<'EOF'

The sensor firmware enforces Microsoft SDCP; mainline libfprint's
egismoc driver does not speak it, so enrollment silently fails
("Print was not found on the device's storage"). As of mid-2026 the fix
is a community fork, not yet merged upstream:

  1. Install from the AUR:  libfprint-egismoc-sdcp-git
     (replaces libfprint; e.g.  paru -S libfprint-egismoc-sdcp-git)
  2. Enroll:                fprintd-enroll
  3. Verify:                fprintd-verify

Upstream tracking: gitlab.freedesktop.org/libfprint/libfprint issue 632.
The Arch Wiki page for this model also documents a patched-script
enrollment path if the fork lags. If a future libfprint release merges
SDCP, drop the fork and return to the repo package.
EOF
    else
        warn 'No known fingerprint reader (27c6:650a or 1c7a:0583) on USB right now.'
    fi
}

yoga_bios_guidance() {
    msg "${C_BOLD}BIOS on the Yoga 7 14AHP9${C_RESET}"
    msg ''
    msg "Installed: $(cat /sys/class/dmi/id/bios_version 2>/dev/null) ($(cat /sys/class/dmi/id/bios_date 2>/dev/null))"
    cat <<'EOF'

This model is not on LVFS — fwupd only delivers UEFI CA/dbx updates,
never the system BIOS. Lenovo ships BIOS updates as a Windows .exe
(support.lenovo.com, downloads page DS567236, shared with the 16AHP9).
From Linux the tested path is: extract the capsule with innoextract,
then flash with fwupdtool — see the Arch Wiki, "Flashing BIOS from
Linux # Lenovo", and follow it with care (AC power, no early reboot).
Note: the firmware keeps a ~6 MB self-healing backup image on the ESP;
leave it alone when signing the ESP for Secure Boot.
EOF
}

yoga_extra_run() {
    case ${EX_IDS[$1]} in
        fprint) yoga_fprint_guidance ;;
        bios)   yoga_bios_guidance ;;
    esac
}

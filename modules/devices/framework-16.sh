# shellcheck shell=bash
# Framework Laptop 16 (Ryzen 7040HS, optional RX 7700S) fixes for the
# Tweaks for CachyOS. Sourced by tweaks.sh; see lib/common.sh.
# Research basis (July 2026): ArchWiki FW16, Framework issue tracker and
# community, CachyOS forum. Highest-value action is BIOS >= 4.05 via fwupd
# (stable on LVFS since 2026-07-20; fixes the 35 W BOCO power-limit bug).
# The SMU-mismatch runtime-resume bug (issue #190) remains open on all
# BIOS/kernel combinations as of this writing.

declare -ga FW16_TWEAKS=()
register_module_doc fw16 Hardware 'Framework 16' \
    modules/devices/framework-16.md

fw16_detect() {
    [[ $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) == Framework ]] &&
        [[ $(cat /sys/class/dmi/id/product_name 2>/dev/null) == 'Laptop 16'* ]]
}

fw16_model_line() {
    printf 'Framework 16 — Ryzen 7040HS, BIOS %s' \
        "$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo '?')"
}

fw16_has_dgpu() { lspci -d 1002: 2>/dev/null | grep -qi '7700S\|Navi 33' ; }

# ---------------------------------------------------------------------------
# power-profiles-daemon (same rationale as FW13: PPD, never TLP, on Phoenix)
# ---------------------------------------------------------------------------
FW16_TWEAKS+=(power-profiles-daemon)

fw16_power_profiles_daemon_title() { printf 'Enable power-profiles-daemon (battery/EPP management)'; }
fw16_power_profiles_daemon_desc() {
    cat <<'EOF'
power-profiles-daemon is the platform-recommended power daemon (AMD and
Framework explicitly discourage TLP here: it fights the kernel's
platform-profile/EPP path). Apply enables and starts it; revert restores
the previous state exactly.
EOF
}
fw16_power_profiles_daemon_applicable() { common_power_profiles_applicable; }
fw16_power_profiles_daemon_status() { common_power_profiles_status; }
fw16_power_profiles_daemon_apply() { common_power_profiles_apply; }
fw16_power_profiles_daemon_revert() { common_power_profiles_revert; }

# ---------------------------------------------------------------------------
# gsk-renderer-ngl: stop GTK4 waking the dGPU
# ---------------------------------------------------------------------------
FW16_TWEAKS+=(gsk-renderer-ngl)
readonly FW16_GSK_CONF=/etc/environment.d/60-cachyos-tweaks-gsk.conf

fw16_gsk_renderer_ngl_title() { printf 'Stop GTK4 apps waking the dGPU (GSK_RENDERER=ngl)'; }
fw16_gsk_renderer_ngl_desc() {
    cat <<'EOF'
GTK4 defaults to its Vulkan renderer since 4.16, which enumerates GPUs
and wakes the RX 7700S out of d3cold — app-launch stutter and real
battery drain (drm/amd issue #2295, still open). GSK_RENDERER=ngl keeps
GTK on OpenGL. Only covers GTK apps: Qt/KWin Vulkan enumeration can
still wake the card. Harmless without the dGPU module too. Takes effect
at next login. Diagnose the dGPU sleep state with:
  watch cat /sys/class/drm/card*/device/power/runtime_status
Also check for leftover NVIDIA driver packages — they block d3cold.
EOF
}
fw16_gsk_renderer_ngl_applicable() { fw16_detect; }
fw16_gsk_renderer_ngl_status() { tweak_file_status gsk-renderer-ngl "$FW16_GSK_CONF"; }
fw16_gsk_renderer_ngl_apply() {
    managed_write gsk-renderer-ngl "$FW16_GSK_CONF" 0644 <<'EOF'
# cachyos-tweaks: keep GTK4 off the Vulkan renderer so the dGPU can sleep.
GSK_RENDERER=ngl
EOF
}
fw16_gsk_renderer_ngl_revert() { managed_revert_all gsk-renderer-ngl; }

# ---------------------------------------------------------------------------
# input-module-udev: QMK keyboard / LED matrix hidraw access
# ---------------------------------------------------------------------------
FW16_TWEAKS+=(input-module-udev)
readonly FW16_QMK_RULE=/etc/udev/rules.d/50-cachyos-tweaks-fw16-input.rules

fw16_input_module_udev_title() { printf 'Input-module udev rules (QMK keyboard, LED matrix)'; }
fw16_input_module_udev_desc() {
    cat <<'EOF'
Grants your user hidraw access to the Framework 16 input modules so
keyboard.frame.work / VIA and the LED-matrix tools work without root.
Access is limited to the known keyboard, macropad, numpad, LED-matrix,
and development-module product IDs. Reconnect a module after applying
or reverting so udev refreshes its access state.
EOF
}
fw16_input_module_udev_applicable() { fw16_detect; }
fw16_input_module_udev_status() { tweak_file_status input-module-udev "$FW16_QMK_RULE"; }
fw16_input_module_udev_apply() {
    managed_write input-module-udev "$FW16_QMK_RULE" 0644 <<'EOF'
# cachyos-tweaks: Framework 16 input modules (QMK keyboards, LED matrix).
# QMK keyboard (ANSI/ISO), macropad, and numpad hidraw devices.
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0012", TAG+="uaccess"
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0013", TAG+="uaccess"
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0014", TAG+="uaccess"
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0018", TAG+="uaccess"
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0019", TAG+="uaccess"

# Framework inputmodule-rs devices: LED Matrix and development modules.
SUBSYSTEMS=="usb", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0020", MODE="0660", TAG+="uaccess"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0021", MODE="0660", TAG+="uaccess"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0022", MODE="0660", TAG+="uaccess"
EOF
    udevadm control --reload
}
fw16_input_module_udev_revert() {
    managed_restore_all_keep_state input-module-udev
    udevadm control --reload
    managed_forget_all input-module-udev
}

# ---------------------------------------------------------------------------
# mt7921e-no-aspm: Wi-Fi latency fix (opt-in)
# ---------------------------------------------------------------------------
FW16_TWEAKS+=(mt7921e-no-aspm)
readonly FW16_WIFI_CONF=/etc/modprobe.d/cachyos-tweaks-mt7921e.conf

fw16_mt7921e_no_aspm_title() { printf 'MediaTek Wi-Fi latency fix (disable ASPM)'; }
fw16_mt7921e_no_aspm_desc() {
    cat <<'EOF'
The stock RZ616/MT7922 card can suffer latency spikes and throughput
collapse with PCIe ASPM enabled. Sets mt7921e disable_aspm=1. Only apply
if you actually see Wi-Fi stalls — it costs idle battery. Keep
linux-firmware current; most MT7922 crash bugs are firmware-fixed.
Takes effect after reboot (or module reload).
EOF
}
fw16_mt7921e_no_aspm_applicable() { fw16_detect && [[ -d /sys/module/mt7921e || -n $(lspci -d 14c3: 2>/dev/null) ]]; }
fw16_mt7921e_no_aspm_status() { tweak_file_status mt7921e-no-aspm "$FW16_WIFI_CONF"; }
fw16_mt7921e_no_aspm_apply() {
    managed_write mt7921e-no-aspm "$FW16_WIFI_CONF" 0644 <<'EOF'
# cachyos-tweaks: MT7922 latency/throughput fix; costs idle power.
options mt7921e disable_aspm=1
EOF
}
fw16_mt7921e_no_aspm_revert() { managed_revert_all mt7921e-no-aspm; }

# ---------------------------------------------------------------------------
# wifi-regdom (6 GHz needs a set regulatory domain)
# ---------------------------------------------------------------------------
FW16_TWEAKS+=(wifi-regdom)
fw16_wifi_regdom_title() { printf 'Persist Wi-Fi regulatory domain (5/6 GHz)'; }
fw16_wifi_regdom_desc() {
    cat <<'EOF'
Without a regulatory domain the RZ616 may be limited to 2.4 GHz/802.11n
(and 6 GHz stays off). Pins WIRELESS_REGDOM in /etc/conf.d/
wireless-regdom. Prompts for your two-letter country code (defaults to
the currently active one).
EOF
}
fw16_wifi_regdom_applicable() {
    fw16_detect && pacman -Q wireless-regdb >/dev/null 2>&1
}
fw16_wifi_regdom_status() { common_wifi_regdom_status; }
fw16_wifi_regdom_apply() { common_wifi_regdom_apply; }
fw16_wifi_regdom_revert() { common_wifi_regdom_revert; }

# ---------------------------------------------------------------------------
# amdgpu-no-psr: display flicker/freeze mitigation (opt-in)
# ---------------------------------------------------------------------------
FW16_TWEAKS+=(amdgpu-no-psr)
fw16_amdgpu_no_psr_title() { printf 'Disable amdgpu Panel Replay + PSR (flicker fix)'; }
fw16_amdgpu_no_psr_desc() {
    cat <<'EOF'
Sets amdgpu dcdebugmask=0x410, disabling Panel Replay and Panel Self
Refresh — the mitigation when the internal panel flickers, shows
artifacts, or the machine freezes after waking (DMUB / flip_done errors
in the journal). On this panel the culprit since kernel 6.12 is usually
Panel Replay (the 0x400 bit); reports continue on current kernels.
Apply on symptom, especially right after a kernel update. Costs some
battery. Rebuilds the initramfs; reboot to take effect.
EOF
}
fw16_amdgpu_no_psr_applicable() { fw16_detect && [[ -d /sys/module/amdgpu ]]; }
fw16_amdgpu_no_psr_status() { common_amdgpu_no_psr_status; }
fw16_amdgpu_no_psr_apply() { common_amdgpu_no_psr_apply; }
fw16_amdgpu_no_psr_revert() { common_amdgpu_no_psr_revert; }

# ---------------------------------------------------------------------------
# amdgpu-runpm-off: escape hatch for the open SMU-mismatch bug (opt-in)
# ---------------------------------------------------------------------------
FW16_TWEAKS+=(amdgpu-runpm-off)
readonly FW16_RUNPM_CONF=/etc/modprobe.d/cachyos-tweaks-amdgpu-runpm.conf

fw16_amdgpu_runpm_off_title() { printf 'dGPU runtime-PM escape hatch (runpm=0 — battery cost!)'; }
fw16_amdgpu_runpm_off_desc() {
    cat <<'EOF'
Escape hatch for the open FW16 bug where dGPU runtime-resume causes USB
disconnects and flicker ("SMU driver if version not matched" in the
journal; Framework issue #190 — still open as of July 2026, seen on
both 7040HS and Ryzen AI 300 boards, not fixed by BIOS 4.05 or kernel
7.0). Disables amdgpu runtime PM entirely — the RX 7700S then NEVER
sleeps, a large battery cost — and even then rare MES hangs remain.
Only apply if you hit that bug. Do NOT use amdgpu.dpm=0 instead (boot
failure). Rebuilds the initramfs; reboot to take effect.
EOF
}
fw16_amdgpu_runpm_off_applicable() { fw16_detect && fw16_has_dgpu; }
fw16_amdgpu_runpm_off_status() { tweak_file_status amdgpu-runpm-off "$FW16_RUNPM_CONF"; }
fw16_amdgpu_runpm_off_apply() {
    managed_write amdgpu-runpm-off "$FW16_RUNPM_CONF" 0644 <<'EOF'
# cachyos-tweaks: disable dGPU runtime PM (SMU-mismatch bug escape hatch).
options amdgpu runpm=0
EOF
    msg 'Rebuilding the initramfs...'
    mkinitcpio -P
    warn 'Reboot for this to take effect. Large battery cost while applied.'
}
fw16_amdgpu_runpm_off_revert() {
    managed_restore_all_keep_state amdgpu-runpm-off
    msg 'Rebuilding the initramfs...'
    mkinitcpio -P
    managed_forget_all amdgpu-runpm-off
    warn 'Reboot for this to take effect.'
}

# ---------------------------------------------------------------------------
# charge-limit-80: EC battery charge cap via framework_tool/ectool
# ---------------------------------------------------------------------------
FW16_TWEAKS+=(charge-limit-80)

fw16_charge_tool() { common_framework_charge_tool; }
fw16_charge_limit_80_title() { printf 'Limit battery charge to 80%% (longevity)'; }
fw16_charge_limit_80_desc() {
    cat <<'EOF'
Caps charging at 80% through the kernel's charge-threshold interface or
framework_tool (from the framework-system package). The setting persists
in the EC. Apply records the current threshold; revert restores that exact
value. The same setting is also available in BIOS setup.
EOF
}
fw16_charge_limit_80_applicable() { fw16_detect && common_framework_charge_get >/dev/null; }
fw16_charge_limit_80_status() { common_framework_charge_status; }
fw16_charge_limit_80_apply() { common_framework_charge_apply; }
fw16_charge_limit_80_revert() { common_framework_charge_revert; }

# ---------------------------------------------------------------------------
# mt7922-powersave: RZ616 firmware disconnect bug (mt76 issue #987)
# ---------------------------------------------------------------------------
FW16_TWEAKS+=(mt7922-powersave)
fw16_mt7922_powersave_title() { printf 'MediaTek Wi-Fi: disable powersave (disconnect fix)'; }
fw16_mt7922_powersave_desc() {
    cat <<'EOF'
The RZ616/MT7922 firmware has an open bug (mt76 issue #987): with Wi-Fi
powersave on, the connection drops every 10-20 minutes. Disabling
powersave in NetworkManager stabilizes it completely, for a small
idle-battery cost. Still unfixed as of mid-2026 — apply if you see
periodic drops that reconnect instantly. Complementary to the ASPM
tweak above (that one is for latency spikes/full stalls).
EOF
}
fw16_mt7922_powersave_applicable() {
    fw16_detect && [[ -d /etc/NetworkManager ]] \
        && { [[ -d /sys/module/mt7921e ]] || lspci -d 14c3: 2>/dev/null | grep -q .; }
}
fw16_mt7922_powersave_status() { common_mt7922_powersave_status; }
fw16_mt7922_powersave_apply() { common_mt7922_powersave_apply; }
fw16_mt7922_powersave_revert() { common_mt7922_powersave_revert; }

# ---------------------------------------------------------------------------
# input-power-quirks: stop backpack wake, settle input-module power states
# (based on ublue-os 50-framework16.rules; firmware also fixed the wake
# source on current keyboard fw + BIOS, so this is belt-and-braces)
# ---------------------------------------------------------------------------
FW16_TWEAKS+=(input-power-quirks)
readonly FW16_INPUT_PM_RULE=/etc/udev/rules.d/50-cachyos-tweaks-fw16-input-pm.rules

fw16_input_power_quirks_title() { printf 'Stop keyboard waking the laptop in a bag (udev)'; }
fw16_input_power_quirks_desc() {
    cat <<'EOF'
The lid can press the keyboard in a backpack and wake the machine. This
rule set (from uBlue's Framework 16 config) disables USB wakeup for the
keyboard and numpad modules and keeps them out of autosuspend (avoids
missed keystrokes), and lets the Audio Expansion Card autosuspend
quickly. NOTE: after this, a key press no longer wakes from suspend —
use the power button or lid. Current keyboard firmware + BIOS also fix
the wake source, so treat this as belt-and-braces.
Reconnect affected expansion modules after applying or reverting.
EOF
}
fw16_input_power_quirks_applicable() { fw16_detect; }
fw16_input_power_quirks_status() { tweak_file_status input-power-quirks "$FW16_INPUT_PM_RULE"; }
fw16_input_power_quirks_apply() {
    managed_write input-power-quirks "$FW16_INPUT_PM_RULE" 0644 <<'EOF'
# cachyos-tweaks: FW16 input-module power rules (after ublue-os config).
# Keyboard (ANSI 0012, ISO 0018) and numpad (0014): stay awake, never wake.
SUBSYSTEM=="usb", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0012", ATTR{power/autosuspend}="-1", ATTR{power/control}="on", ATTR{power/wakeup}="disabled"
SUBSYSTEM=="usb", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0018", ATTR{power/autosuspend}="-1", ATTR{power/control}="on", ATTR{power/wakeup}="disabled"
SUBSYSTEM=="usb", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0014", ATTR{power/autosuspend}="-1", ATTR{power/control}="on", ATTR{power/wakeup}="disabled"
# Audio Expansion Card (0010): autosuspend quickly.
SUBSYSTEM=="usb", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0010", ATTR{power/autosuspend}="10", ATTR{power/control}="auto"
EOF
    udevadm control --reload
}
fw16_input_power_quirks_revert() {
    managed_restore_all_keep_state input-power-quirks
    udevadm control --reload
    managed_forget_all input-power-quirks
}

# ---------------------------------------------------------------------------
# kbd-backlight-restore: the QMK keyboard forgets its backlight level across
# suspend/hibernate. The FW13 LED-class hook does not apply (no
# chromeos::kbd_backlight here); go through framework_tool's EC path.
# ---------------------------------------------------------------------------
FW16_TWEAKS+=(kbd-backlight-restore)
readonly FW16_KBD_HOOK=/usr/lib/systemd/system-sleep/cachyos-tweaks-kbd-backlight

fw16_kbd_backlight_restore_title() { printf 'Restore keyboard backlight after suspend'; }
fw16_kbd_backlight_restore_desc() {
    cat <<'EOF'
The keyboard/numpad backlight resets across suspend (and especially
hibernation). This sleep hook saves the level via framework_tool before
sleeping and restores it on resume. Needs the framework-system package.
Purely cosmetic; harmless.
EOF
}
fw16_kbd_backlight_restore_applicable() {
    fw16_detect && command -v framework_tool >/dev/null 2>&1
}
fw16_kbd_backlight_restore_status() { tweak_file_status kbd-backlight-restore "$FW16_KBD_HOOK"; }
fw16_kbd_backlight_restore_apply() {
    managed_write kbd-backlight-restore "$FW16_KBD_HOOK" 0755 <<'EOF'
#!/bin/bash
# cachyos-tweaks: keep the FW16 keyboard backlight level across suspend.
STATE=/var/lib/cachyos-tweaks/kbd-backlight-restore/saved-level
case $1 in
    pre)
        mkdir -p "${STATE%/*}"
        level=$(framework_tool --kblight 2>/dev/null | grep -o '[0-9]\+' | head -n1)
        [[ -n "$level" ]] && printf '%s\n' "$level" >"$STATE"
        ;;
    post)
        [[ -r "$STATE" ]] && framework_tool --kblight "$(cat "$STATE")" >/dev/null 2>&1
        ;;
esac
exit 0
EOF
}
fw16_kbd_backlight_restore_revert() {
    managed_revert_all kbd-backlight-restore
}

# shellcheck shell=bash
# eGPU / USB4 / Thunderbolt tools for Tweaks for CachyOS.
# Sourced by tweaks.sh; see lib/common.sh for the tweak contract.
# Research basis (July 2026): kernel USB4 admin guide + module parameters
# verified against a current kernel, ArchWiki External GPU/Thunderbolt,
# all-ways-egpu, egpu.io, Framework community threads. Tweaks are
# symptom-driven; the diagnostics action tells you which ones you need.

declare -ga EGPU_TWEAKS=()
register_module_doc egpu Hardware 'eGPU / USB4' \
    modules/hardware/egpu.md

egpu_detect() {
    [[ -d /sys/bus/thunderbolt/devices ]] &&
        compgen -G '/sys/bus/thunderbolt/devices/domain*' >/dev/null
}

egpu_model_line() { printf 'eGPU / USB4 tools'; }

# ---------------------------------------------------------------------------
# Tweak: auto-authorize
# ---------------------------------------------------------------------------
EGPU_TWEAKS+=(auto-authorize)
readonly EGPU_AUTH_RULE=/etc/udev/rules.d/99-cachyos-tweaks-egpu-authorize.rules

egpu_iommu_protected() {
    [[ $(cat /sys/bus/thunderbolt/devices/domain0/iommu_dma_protection 2>/dev/null) == 1 ]]
}
egpu_auto_authorize_title() { printf 'Auto-authorize USB4/Thunderbolt devices'; }
egpu_auto_authorize_desc() {
    local prot
    prot=$(cat /sys/bus/thunderbolt/devices/domain0/iommu_dma_protection 2>/dev/null || echo '?')
    cat <<EOF
Authorizes every hotplugged USB4/Thunderbolt device automatically via a
udev rule, so PCIe tunnels come up without boltctl enrollment.

Security note: this bypasses Thunderbolt device approval. IOMMU DMA
protection on this machine reports: $prot. When 1 (protected), the
installed rule is gated on that attribute — the kernel-documented safe
variant. When 0, an ungated rule is installed and a malicious device
could attempt DMA attacks — your call. Usually only needed when bolt is
absent or misbehaving (bolt's default policy auto-enrolls anyway).
EOF
}
egpu_auto_authorize_applicable() { egpu_detect; }
egpu_auto_authorize_status() { tweak_file_status auto-authorize "$EGPU_AUTH_RULE"; }
egpu_auto_authorize_apply() {
    if egpu_iommu_protected; then
        managed_write auto-authorize "$EGPU_AUTH_RULE" 0644 <<'EOF'
# cachyos-tweaks: authorize USB4/Thunderbolt tunnels automatically.
# Gated on IOMMU DMA protection (the kernel admin guide's safe variant).
ACTION=="add", SUBSYSTEM=="thunderbolt", ATTRS{iommu_dma_protection}=="1", ATTR{authorized}=="0", ATTR{authorized}="1"
EOF
    else
        managed_write auto-authorize "$EGPU_AUTH_RULE" 0644 <<'EOF'
# cachyos-tweaks: authorize USB4/Thunderbolt tunnels automatically.
# NOTE: this host reports no IOMMU DMA protection; the rule is ungated.
ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
EOF
    fi
    udevadm control --reload
}
egpu_auto_authorize_revert() {
    managed_restore_all_keep_state auto-authorize
    udevadm control --reload
    managed_forget_all auto-authorize
}

# ---------------------------------------------------------------------------
# Tweak: link-quirks (thunderbolt.clx=0 host_reset=0 as module options)
# ---------------------------------------------------------------------------
EGPU_TWEAKS+=(link-quirks)
readonly EGPU_LINK_CONF=/etc/modprobe.d/cachyos-tweaks-egpu-link.conf

egpu_link_quirks_title() { printf 'USB4 link quirks (no low-power link states, no host reset)'; }
egpu_link_quirks_desc() {
    cat <<'EOF'
Two thunderbolt module options that fix the most common eGPU failures:
clx=0 disables USB4 low-power link states that drop marginal links
(random disconnects, "Link Down", AER floods); host_reset=0 skips the
boot-time host router reset, fixing boot-attached enclosures/docks that
never appear in lspci — and when the firmware tunnels the eGPU pre-boot
it can preserve firmware-assigned resources (incl. large BARs).
host_reset only affects boot; it does nothing for hotplug-after-boot.
Small battery cost from clx=0. Rebuilds the initramfs; reboot to take
effect.
EOF
}
egpu_link_quirks_applicable() { egpu_detect && [[ -d /sys/module/thunderbolt ]]; }
egpu_link_quirks_status() { tweak_file_status link-quirks "$EGPU_LINK_CONF"; }
egpu_link_quirks_apply() {
    managed_write link-quirks "$EGPU_LINK_CONF" 0644 <<'EOF'
# cachyos-tweaks: eGPU link stability (see suite description).
options thunderbolt clx=0 host_reset=0
EOF
    msg 'Rebuilding the initramfs...'
    mkinitcpio -P
    warn 'Reboot for this to take effect.'
}
egpu_link_quirks_revert() {
    managed_restore_all_keep_state link-quirks
    msg 'Rebuilding the initramfs...'
    mkinitcpio -P
    managed_forget_all link-quirks
    warn 'Reboot for this to take effect.'
}

# ---------------------------------------------------------------------------
# Tweak: chain-runtime-pm
# ---------------------------------------------------------------------------
EGPU_TWEAKS+=(chain-runtime-pm)
readonly EGPU_PM_RULE=/etc/udev/rules.d/50-cachyos-tweaks-egpu-pm.rules

egpu_chain_runtime_pm_title() { printf 'Keep the eGPU chain out of runtime suspend'; }
egpu_chain_runtime_pm_desc() {
    cat <<'EOF'
The USB4 router autosuspends quickly and the PCIe tunnel goes D3cold; on
flaky firmware the resume fails ("not ready after resume", "Unable to
change power state from D3cold to D0", "pciehp: Link Down"). This udev
rule keeps USB4/Thunderbolt routers and the USB4 host controller awake.
Costs some idle power while an enclosure is attached; the targeted
alternative to the old pcie_port_pm=off hammer. Reconnect the enclosure
after applying so udev processes the chain with this rule.
EOF
}
egpu_chain_runtime_pm_applicable() { egpu_detect; }
egpu_chain_runtime_pm_status() { tweak_file_status chain-runtime-pm "$EGPU_PM_RULE"; }
egpu_chain_runtime_pm_apply() {
    managed_write chain-runtime-pm "$EGPU_PM_RULE" 0644 <<'EOF'
# cachyos-tweaks: keep the eGPU/USB4 chain out of runtime suspend.
ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{power/control}="on"
# The USB4 host interface: match by bound driver — robust for AMD and
# Intel NHIs (older Intel parts enumerate as class 0x088000, not
# 0x0c0340, until powered up).
ACTION=="add", SUBSYSTEM=="pci", DRIVERS=="thunderbolt", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="pci", ATTR{class}=="0x0c0340", ATTR{power/control}="on"
EOF
    udevadm control --reload
}
egpu_chain_runtime_pm_revert() {
    managed_restore_all_keep_state chain-runtime-pm
    udevadm control --reload
    managed_forget_all chain-runtime-pm
}

# ---------------------------------------------------------------------------
# Tweak: amdgpu-egpu-quirks
# ---------------------------------------------------------------------------
EGPU_TWEAKS+=(amdgpu-egpu-quirks)
readonly EGPU_AMDGPU_CONF=/etc/modprobe.d/cachyos-tweaks-egpu-amdgpu.conf

egpu_amdgpu_egpu_quirks_title() { printf 'AMD eGPU stability quirks (global amdgpu options!)'; }
egpu_amdgpu_egpu_quirks_desc() {
    cat <<'EOF'
For AMD cards in the enclosure: pcie_gen_cap=0x40000 caps/forces Gen3
(older kernels locked tunneled cards to Gen1; on 6.8+ the tunneled root
port advertising 2.5GT/s is cosmetic and this is only needed if real
throughput is capped), reset_method=4 uses BACO reset (confirmed helper
on RX 6000), runpm=0 stops the card dropping into d3cold mid-session
(disconnect-on-idle failures). Does NOT help RDNA4 large-BAR allocation
failures ("can't assign; no space") — those need hotplug window kernel
parameters; see diagnostics.

WARNING: amdgpu options are global — runpm=0 also stops the INTERNAL GPU
runtime-suspending, which costs battery on the go. Apply while using the
eGPU at a desk; revert before traveling. Rebuilds the initramfs; reboot
to take effect.
EOF
}
egpu_amdgpu_egpu_quirks_applicable() { egpu_detect && [[ -d /sys/module/amdgpu ]]; }
egpu_amdgpu_egpu_quirks_status() { tweak_file_status amdgpu-egpu-quirks "$EGPU_AMDGPU_CONF"; }
egpu_amdgpu_egpu_quirks_apply() {
    managed_write amdgpu-egpu-quirks "$EGPU_AMDGPU_CONF" 0644 <<'EOF'
# cachyos-tweaks: AMD eGPU over USB4 — Gen3 link, BACO reset, no runtime PM.
# Global options: revert this tweak when not using the eGPU on battery.
options amdgpu pcie_gen_cap=0x40000 reset_method=4 runpm=0
EOF
    msg 'Rebuilding the initramfs...'
    mkinitcpio -P
    warn 'Reboot for this to take effect. Revert before mobile use (battery).'
}
egpu_amdgpu_egpu_quirks_revert() {
    managed_restore_all_keep_state amdgpu-egpu-quirks
    msg 'Rebuilding the initramfs...'
    mkinitcpio -P
    managed_forget_all amdgpu-egpu-quirks
    warn 'Reboot for this to take effect.'
}

# ---------------------------------------------------------------------------
# Tweak: nvidia-gsp-fix
# ---------------------------------------------------------------------------
EGPU_TWEAKS+=(nvidia-gsp-fix)
readonly EGPU_NVIDIA_CONF=/etc/modprobe.d/cachyos-tweaks-egpu-nvidia.conf

egpu_nvidia_proprietary() {
    # Open kernel modules (Dual MIT/GPL) require GSP; the parameter only
    # works on the proprietary-license modules.
    modinfo -F license nvidia 2>/dev/null | grep -qx 'NVIDIA'
}
egpu_nvidia_gsp_fix_title() { printf 'NVIDIA eGPU GSP firmware workaround (proprietary driver)'; }
egpu_nvidia_gsp_fix_desc() {
    local flavor='open (GSP required — this tweak will refuse to apply)'
    egpu_nvidia_proprietary && flavor='proprietary (parameter works)'
    cat <<EOF
For NVIDIA cards that fail with "unexpected WPR2 already up" or
"BAR0 is 0M @ 0x0" in dmesg (GSP firmware racing BAR assignment over the
tunnel): disables GSP firmware via NVreg_EnableGpuFirmware=0. Only apply
when those exact errors appear.

Only works with the PROPRIETARY kernel modules. Arch/CachyOS nvidia
packages ship the OPEN modules since driver 590, which require GSP (the
parameter is ignored; Blackwell cards can never disable it). Installed
module flavor: $flavor.
EOF
}
egpu_nvidia_gsp_fix_applicable() {
    egpu_detect && modinfo nvidia >/dev/null 2>&1 \
        && { egpu_nvidia_proprietary || tweak_has_state nvidia-gsp-fix; }
}
egpu_nvidia_gsp_fix_status() { tweak_file_status nvidia-gsp-fix "$EGPU_NVIDIA_CONF"; }
egpu_nvidia_gsp_fix_apply() {
    egpu_nvidia_proprietary || die 'the installed nvidia driver uses the open kernel modules, which require GSP — this workaround only works on the proprietary modules'
    managed_write nvidia-gsp-fix "$EGPU_NVIDIA_CONF" 0644 <<'EOF'
# cachyos-tweaks: NVIDIA eGPU GSP/BAR init race workaround.
options nvidia NVreg_EnableGpuFirmware=0
EOF
}
egpu_nvidia_gsp_fix_revert() {
    managed_revert_all nvidia-gsp-fix
}

# ---------------------------------------------------------------------------
# Tweak: pci-rescan-on-authorize
# ---------------------------------------------------------------------------
EGPU_TWEAKS+=(pci-rescan-on-authorize)
readonly EGPU_RESCAN_RULE=/etc/udev/rules.d/99-cachyos-tweaks-egpu-rescan.rules
readonly EGPU_RESCAN_SCRIPT=/usr/local/lib/cachyos-tweaks/tb-rescan.sh

egpu_pci_rescan_on_authorize_title() { printf 'Rescan PCI when a tunnel authorizes (hotplug fix)'; }
egpu_pci_rescan_on_authorize_desc() {
    cat <<'EOF'
Some hotplugged enclosures authorize fine but their PCIe devices never
get enumerated (nothing new in lspci, no driver bind). This udev rule
triggers a PCI bus rescan whenever a USB4/Thunderbolt device becomes
authorized — the ArchWiki-documented companion to auto-authorization.
Harmless when not needed; pairs well with auto-authorize.
EOF
}
egpu_pci_rescan_on_authorize_applicable() { egpu_detect; }
egpu_pci_rescan_on_authorize_status() {
    tweak_file_status pci-rescan-on-authorize "$EGPU_RESCAN_RULE" "$EGPU_RESCAN_SCRIPT"
}
egpu_pci_rescan_on_authorize_apply() {
    managed_write pci-rescan-on-authorize "$EGPU_RESCAN_SCRIPT" 0755 <<'EOF'
#!/bin/bash
# cachyos-tweaks: rescan the PCI bus after a Thunderbolt tunnel authorizes.
echo 1 >/sys/bus/pci/rescan
exit 0
EOF
    managed_write pci-rescan-on-authorize "$EGPU_RESCAN_RULE" 0644 <<EOF
# cachyos-tweaks: enumerate PCIe devices behind freshly authorized tunnels.
ACTION=="add|change", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="1", RUN+="$EGPU_RESCAN_SCRIPT"
EOF
    udevadm control --reload
}
egpu_pci_rescan_on_authorize_revert() {
    managed_restore_all_keep_state pci-rescan-on-authorize
    udevadm control --reload
    managed_forget_all pci-rescan-on-authorize
}

# ---------------------------------------------------------------------------
# Tweak: boot-egpu-order — driver ordering for boot-attached AMD eGPUs
# ---------------------------------------------------------------------------
EGPU_TWEAKS+=(boot-egpu-order)
readonly EGPU_ORDER_CONF=/etc/modprobe.d/cachyos-tweaks-egpu-order.conf
readonly EGPU_ORDER_MKINIT=/etc/mkinitcpio.conf.d/cachyos-tweaks-egpu.conf

egpu_boot_egpu_order_title() { printf 'Load thunderbolt before amdgpu (boot-attached eGPU)'; }
egpu_boot_egpu_order_desc() {
    cat <<'EOF'
When booting with an AMD eGPU attached, amdgpu can probe before the USB4
tunnel is up and miss the card. This adds "softdep amdgpu pre:
thunderbolt" and pulls thunderbolt into the initramfs, so tunnels exist
by the time the GPU driver binds. Only matters for boot-attached
enclosures (required for eGPU-as-primary setups). Rebuilds the
initramfs; reboot to take effect.
EOF
}
egpu_boot_egpu_order_applicable() { egpu_detect && modinfo amdgpu >/dev/null 2>&1; }
egpu_boot_egpu_order_status() {
    tweak_file_status boot-egpu-order "$EGPU_ORDER_CONF" "$EGPU_ORDER_MKINIT"
}
egpu_boot_egpu_order_apply() {
    managed_write boot-egpu-order "$EGPU_ORDER_CONF" 0644 <<'EOF'
# cachyos-tweaks: bring USB4 tunnels up before the GPU driver probes.
softdep amdgpu pre: thunderbolt
EOF
    managed_write boot-egpu-order "$EGPU_ORDER_MKINIT" 0644 <<'EOF'
# cachyos-tweaks: thunderbolt in the initramfs for boot-attached eGPUs.
MODULES+=(thunderbolt)
EOF
    msg 'Rebuilding the initramfs...'
    mkinitcpio -P
    warn 'Reboot for this to take effect.'
}
egpu_boot_egpu_order_revert() {
    managed_restore_all_keep_state boot-egpu-order
    msg 'Rebuilding the initramfs...'
    mkinitcpio -P
    managed_forget_all boot-egpu-order
    warn 'Reboot for this to take effect.'
}

# ---------------------------------------------------------------------------
# Extra action: diagnostics
# ---------------------------------------------------------------------------

egpu_extra_build() {
    EX_IDS+=(diag)
    EX_LABELS+=('Run eGPU diagnostics')
    EX_DISABLED+=(0)
    EX_CAPTURE+=(1)
    EX_PRIVILEGED+=(0)
    EX_TABBED+=(1)
    EX_DESC+=('Read-only health check of the USB4/eGPU chain: authorization
state, DMA protection, tunnel link speed, external GPU presence and
driver binding, PCIe link status, runtime-PM state, and known failure
signatures in the kernel log. Tells you which tweaks this module offers
are actually needed. Changes nothing.')
}

egpu_extra_run() {
    egpu_diagnostics
}

egpu_diag_line() { printf '  %-8s %s\n' "$1" "$2"; }

egpu_diagnostics() {
    local d out kernel_log found_ext=0 kernel_log_ok=0

    msg "${C_BOLD}== USB4 ==${C_RESET}"
    for d in /sys/bus/thunderbolt/devices/domain*; do
        [[ -d "$d" ]] || continue
        egpu_diag_line "${d##*/}" "security=$(cat "$d/security" 2>/dev/null) iommu_dma_protection=$(cat "$d/iommu_dma_protection" 2>/dev/null)"
    done

    msg ''
    msg "${C_BOLD}== Devices ==${C_RESET}"
    local any=0
    for d in /sys/bus/thunderbolt/devices/*-*/; do
        [[ -e "$d/authorized" ]] || continue
        local name auth speed lanes
        name=$(cat "$d/device_name" 2>/dev/null) || continue   # skip host routers without a name
        any=1
        auth=$(cat "$d/authorized" 2>/dev/null)
        speed=$(cat "$d/tx_speed" 2>/dev/null || echo '?')
        lanes=$(cat "$d/tx_lanes" 2>/dev/null || echo '?')
        if [[ "$auth" == 0 ]]; then
            egpu_diag_line 'BLOCKED' "${d##*/devices/} $name — authorized=0: PCIe tunnel not created (enroll with boltctl or apply auto-authorize)"
        else
            egpu_diag_line 'ok' "${d##*/devices/} $name — authorized=$auth, link ${speed} x${lanes}"
            [[ "$speed" == 10* || "$lanes" == 1 ]] && \
                egpu_diag_line 'WARN' 'link below 20G x2 — try a shorter certified TB4/TB5 cable or the other rear port'
        fi
    done
    (( any )) || egpu_diag_line 'note' 'no USB4/Thunderbolt devices connected right now'
    command -v boltctl >/dev/null 2>&1 && { msg ''; boltctl list 2>/dev/null | sed 's/^/  /'; }

    msg ''
    msg "${C_BOLD}== GPUs ==${C_RESET}"
    local card dev cls boot pci drv
    for card in /sys/class/drm/card[0-9]*; do
        [[ ${card##*/} =~ ^card[0-9]+$ ]] || continue   # skip connector nodes
        [[ -d "$card/device" ]] || continue
        pci=$(basename "$(readlink -f "$card/device")")
        drv=$(basename "$(readlink -f "$card/device/driver")" 2>/dev/null || echo 'NO DRIVER')
        boot=$(cat "$card/device/boot_vga" 2>/dev/null || echo '?')
        egpu_diag_line "${card##*/}" "$pci driver=$drv boot_vga=$boot runtime=$(cat "$card/device/power/runtime_status" 2>/dev/null || echo '?')"
        [[ "$boot" == 0 ]] && found_ext=1
    done
    for dev in /sys/bus/pci/devices/*; do
        cls=$(cat "$dev/class" 2>/dev/null)
        [[ "$cls" == 0x0300* || "$cls" == 0x0302* ]] || continue
        if [[ ! -e "$dev/driver" ]]; then
            egpu_diag_line 'WARN' "display device ${dev##*/} has NO driver bound (module blocked, GSP/BAR race, or firmware issue)"
        fi
    done
    if (( found_ext )); then
        msg ''
        msg "  PCIe link of non-boot GPUs:"
        lspci -vv -d ::0300 2>/dev/null | grep -E '^[0-9a-f]|LnkSta:' | sed 's/^/  /' | head -12
        egpu_diag_line 'hint' '2.5GT/s at the TUNNELED ROOT PORT is cosmetic (USB4 spec); judge by real throughput'
        egpu_diag_line 'hint' 'endpoint link slow AND throughput capped -> amdgpu-egpu-quirks (older kernels/firmware limits)'
    else
        egpu_diag_line 'note' 'no external (non-boot) GPU detected'
    fi

    msg ''
    msg "${C_BOLD}== Kernel log ==${C_RESET}"
    if ! kernel_log=$(dmesg 2>&1); then
        egpu_diag_line 'note' 'kernel log is restricted for this account; run journalctl -k after authorizing if deeper log analysis is needed'
    else
        kernel_log_ok=1
        out=$(printf '%s\n' "$kernel_log" | grep -Ei 'thunderbolt.*(fail|TB_PORT_UP)|pcieport.*not ready|pciehp.*Link Down|device lost from bus|BAR.*(no space|resize)|can.t assign|WPR2 already up|BAR0 is 0M|ring .* timeout|PSP load sos failed|GPU reset end|Unable to change power state from D3cold|BadDLLP|ucsi.*(error|failed)|AER:.*PCIe Bus Error' | tail -14)
    fi
    if [[ -n "${out:-}" ]]; then
        printf '%s\n' "$out" | sed 's/^/  /'
        msg ''
        egpu_diag_line 'hint' 'not ready after resume / D3cold to D0 / Link Down -> chain-runtime-pm and link-quirks'
        egpu_diag_line 'hint' 'BAR no space / cannot assign  -> kernel params pci=realloc,hpmmiosize=128M,hpmmioprefsize=16G'
        egpu_diag_line 'hint' '                                 and/or boot with eGPU attached + link-quirks (host_reset=0)'
        egpu_diag_line 'hint' 'AER floods / BadDLLP          -> link-quirks (clx=0), shorter certified cable, other port'
        egpu_diag_line 'hint' 'ring timeout / PSP load fail  -> amdgpu-egpu-quirks (runpm=0); RDNA4 cases partly unresolved upstream'
        egpu_diag_line 'hint' 'WPR2 / BAR0 is 0M (NVIDIA)    -> nvidia-gsp-fix (proprietary driver only)'
    elif (( kernel_log_ok )); then
        egpu_diag_line 'ok' 'no known failure signatures found'
    fi

    msg ''
    msg "${C_BOLD}== Firmware ==${C_RESET}"
    if command -v fwupdmgr >/dev/null 2>&1; then
        egpu_diag_line 'note' 'USB4 retimer/BIOS fixes ship via LVFS on some hosts: run  fwupdmgr get-updates'
    fi
    if [[ $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) == Framework ]]; then
        egpu_diag_line 'note' 'Framework: only the REAR ports are USB4; a wedged port is cleared by'
        egpu_diag_line ''     '"Battery disconnect" in the UEFI setup menu'
    fi

    msg ''
    msg "${C_BOLD}== Render offload ==${C_RESET}"
    egpu_diag_line 'note' "verify from your desktop session with: DRI_PRIME=1 glxinfo -B | grep renderer"
    egpu_diag_line 'note' "and: vulkaninfo --summary   (both GPUs should be listed)"
    msg ''
    msg 'Plug/unplug hygiene: rear USB4 ports only (Framework), enclosure powered'
    msg 'before connecting, close eGPU apps and disconnect eGPU displays before'
    msg 'unplugging. eGPU-as-primary-compositor needs it present at login; for'
    msg 'that setup use all-ways-egpu (AUR) — its boot_vga method works on'
    msg 'KWin/mutter/wlroots — plus the boot-egpu-order tweak here.'
}

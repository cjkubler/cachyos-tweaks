# shellcheck shell=bash
# Shared graphics-related mutation and revert implementations.

readonly COMMON_AMDGPU_PSR_CONF=/etc/modprobe.d/cachyos-tweaks-amdgpu-psr.conf

common_amdgpu_no_psr_status() {
    tweak_file_status amdgpu-no-psr "$COMMON_AMDGPU_PSR_CONF"
}

common_amdgpu_no_psr_apply() {
    managed_write amdgpu-no-psr "$COMMON_AMDGPU_PSR_CONF" 0644 <<'EOF'
# Tweaks for CachyOS: disable Panel Replay + PSR (flicker/freeze mitigation).
options amdgpu dcdebugmask=0x410
EOF
    msg 'Rebuilding the initramfs...'
    mkinitcpio -P
    warn 'Reboot for this to take effect.'
}

common_amdgpu_no_psr_revert() {
    managed_restore_all_keep_state amdgpu-no-psr
    msg 'Rebuilding the initramfs...'
    mkinitcpio -P
    managed_forget_all amdgpu-no-psr
    warn 'Reboot for this to take effect.'
}

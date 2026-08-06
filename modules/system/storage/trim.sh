# shellcheck shell=bash
# Storage maintenance category for CachyOS.

register_module_doc system 'General OS' 'Storage maintenance' \
    modules/system/storage/README.md

SYSTEM_TWEAKS+=(
    trim-timer
)

system_storage_category() { printf 'Storage'; }

: "${SYSTEM_TRIM_UNIT:=fstrim.timer}"
: "${SYSTEM_TRIM_UNIT_FILE:=/usr/lib/systemd/system/fstrim.timer}"
readonly SYSTEM_TRIM_UNIT SYSTEM_TRIM_UNIT_FILE

system_trim_timer_title() { printf 'Periodic TRIM (fstrim.timer)'; }
system_trim_timer_category() { system_storage_category; }
system_trim_timer_desc() {
    cat <<EOF
Enables the weekly fstrim timer, which tells SSDs and other thinly
provisioned storage which blocks are unused so the firmware can manage
wear and performance.

CachyOS installations normally ship with this timer already enabled — in
that case it is reported here as external and needs nothing from you.
This toggle exists for setups where it was disabled or removed.

Turning it off restores the exact prior timer state.
EOF
}
system_trim_timer_applicable() { [[ -e "$SYSTEM_TRIM_UNIT_FILE" ]]; }
system_trim_timer_status() { service_tweak_status trim-timer "$SYSTEM_TRIM_UNIT"; }
system_trim_timer_apply() { service_tweak_apply trim-timer "$SYSTEM_TRIM_UNIT"; }
system_trim_timer_revert() { service_tweak_revert trim-timer "$SYSTEM_TRIM_UNIT"; }

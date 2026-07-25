# shellcheck shell=bash
# General OS policy module. Keep each policy family in its own category
# directory so adding CPU, storage, networking, or another category does not
# turn this manifest into a monolith.

# shellcheck disable=SC2034 # consumed indirectly by the generic module adapter
declare -ga SYSTEM_TWEAKS=()

# shellcheck source=modules/system/memory/presets.sh
. "$SUITE_DIR/modules/system/memory/presets.sh"

system_detect() { return 0; }
system_model_line() { printf 'General OS tweaks'; }

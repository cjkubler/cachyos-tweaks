# shellcheck shell=bash
# Module manifest. Common implementations load first; user-facing modules are
# grouped by purpose and registered in the order shown in the TUI.

# shellcheck source=modules/common/graphics.sh
. "$SUITE_DIR/modules/common/graphics.sh"
# shellcheck source=modules/common/networking.sh
. "$SUITE_DIR/modules/common/networking.sh"
# shellcheck source=modules/common/power.sh
. "$SUITE_DIR/modules/common/power.sh"
declare -a TWEAK_MODULES=()
declare -a MODULE_DOC_MODULES=()
declare -a MODULE_DOC_CATEGORIES=()
declare -a MODULE_DOC_TITLES=()
declare -a MODULE_DOC_PATHS=()

# register_module_doc MODULE CATEGORY TITLE PATH
#
# Modules own their documentation and register it while they are sourced.
# Multiple calls are allowed, which lets a broad module expose one help item
# per maintainable category without changing the frontend.
register_module_doc() {
    local module=$1 category=$2 title=$3 path=$4 existing resolved canonical
    [[ -n "$module" && -n "$category" && -n "$title" ]] ||
        die 'module documentation requires a module, category, and title'
    resolved=$(realpath -e -- "$SUITE_DIR/$path" 2>/dev/null) ||
        die "module documentation is missing: $path"
    [[ "$resolved" == "$SUITE_DIR/modules/"* ]] ||
        die "module documentation path must stay under modules/: $path"
    canonical="modules/${resolved#"$SUITE_DIR/modules/"}"
    [[ "$path" == "$canonical" ]] ||
        die "module documentation path is not canonical: $path"
    [[ -r "$resolved" && -f "$resolved" ]] ||
        die "module documentation is not a readable regular file: $path"
    for existing in "${MODULE_DOC_PATHS[@]}"; do
        [[ "$existing" != "$path" ]] || die "module documentation is registered twice: $path"
    done
    MODULE_DOC_MODULES+=("$module")
    MODULE_DOC_CATEGORIES+=("$category")
    MODULE_DOC_TITLES+=("$title")
    MODULE_DOC_PATHS+=("$path")
}

# shellcheck source=modules/security/u2f.sh
. "$SUITE_DIR/modules/security/u2f.sh"

load_tweak_module() {
    local id=$1 relative_path=$2
    local file="$SUITE_DIR/modules/$relative_path"
    local resolved
    resolved=$(realpath -e -- "$file" 2>/dev/null) ||
        die "module is missing: $relative_path"
    [[ "$resolved" == "$SUITE_DIR/modules/"* && -f "$resolved" && -r "$resolved" ]] ||
        die "module path must stay below modules/: $relative_path"
    file=$resolved
    # shellcheck disable=SC1090
    . "$file"

    local list_name="${id^^}_TWEAKS"
    declare -p "$list_name" >/dev/null 2>&1 || die "module $id does not declare $list_name"
    declare -F "${id}_detect" >/dev/null || die "module $id has no ${id}_detect"
    declare -F "${id}_model_line" >/dev/null || die "module $id has no ${id}_model_line"
    local doc found=0
    for doc in "${MODULE_DOC_MODULES[@]}"; do
        [[ "$doc" == "$id" ]] && found=1
    done
    ((found)) || die "module $id does not register any documentation"
    TWEAK_MODULES+=("$id")
}

load_tweak_module system system/index.sh
load_tweak_module fw13 devices/framework-13.sh
load_tweak_module fw16 devices/framework-16.sh
load_tweak_module yoga devices/lenovo-yoga-7-14ahp9.sh
load_tweak_module egpu hardware/egpu.sh

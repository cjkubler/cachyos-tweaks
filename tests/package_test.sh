#!/usr/bin/env bash
set -Eeuo pipefail

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fake_binary="$test_dir/tweaks-tui-linux-amd64"
printf '#!/bin/sh\nexit 0\n' >"$fake_binary"

packaged_help=$(CACHYOS_TWEAKS_PROGRAM=tweaks-for-cachyos \
    CACHYOS_TWEAKS_COMMAND=tweaks-for-cachyos \
    CACHYOS_TWEAKS_PACKAGED=1 \
    bash "$repo_dir/tweaks.sh" --help)
grep -Fx 'Usage: tweaks-for-cachyos [command]' <<<"$packaged_help" >/dev/null ||
    { printf 'package_test: installed command was not shown in help\n' >&2; exit 1; }
if CACHYOS_TWEAKS_PROGRAM=tweaks-for-cachyos \
    CACHYOS_TWEAKS_COMMAND=tweaks-for-cachyos \
    CACHYOS_TWEAKS_PACKAGED=1 \
    bash "$repo_dir/tweaks.sh" get-tui >/dev/null 2>&1; then
    printf 'package_test: pacman-managed install allowed a binary-only self-update\n' >&2
    exit 1
fi
if CACHYOS_TWEAKS_PROGRAM=tweaks-for-cachyos \
    CACHYOS_TWEAKS_COMMAND=tweaks-for-cachyos \
    CACHYOS_TWEAKS_PACKAGED=1 \
    bash "$repo_dir/tweaks.sh" update >/dev/null 2>&1; then
    printf 'package_test: pacman-managed install allowed a portable self-update\n' >&2
    exit 1
fi

bash "$repo_dir/scripts/package-release.sh" v1.2.3 amd64 \
    "$fake_binary" "$test_dir"
archive="$test_dir/tweaks-for-cachyos-1.2.3-linux-amd64.tar.gz"
root='tweaks-for-cachyos-1.2.3-linux-amd64'

second_dir="$test_dir/second"
mkdir "$second_dir"
bash "$repo_dir/scripts/package-release.sh" v1.2.3 amd64 \
    "$fake_binary" "$second_dir"
cmp "$archive" "$second_dir/${archive##*/}" ||
    { printf 'package_test: identical inputs produced different archives\n' >&2; exit 1; }

if bash "$repo_dir/scripts/package-release.sh" vnot-a-version amd64 \
    "$fake_binary" "$test_dir" >/dev/null 2>&1; then
    printf 'package_test: invalid release version was accepted\n' >&2
    exit 1
fi
if bash "$repo_dir/scripts/package-release.sh" v1.2.3 riscv64 \
    "$fake_binary" "$test_dir" >/dev/null 2>&1; then
    printf 'package_test: unsupported release architecture was accepted\n' >&2
    exit 1
fi

for required in \
    "$root/tweaks.sh" \
    "$root/install-portable.sh" \
    "$root/build/tweaks-tui" \
    "$root/lib/common.sh" \
    "$root/modules/index.sh" \
    "$root/modules/security/u2f.sh" \
    "$root/modules/security/u2f.md" \
    "$root/modules/system/index.sh" \
    "$root/modules/system/memory/presets.sh" \
    "$root/modules/system/memory/README.md" \
    "$root/modules/devices/framework-13.md" \
    "$root/modules/devices/framework-16.md" \
    "$root/modules/devices/lenovo-yoga-7-14ahp9.md" \
    "$root/modules/hardware/egpu.md" \
    "$root/pam-auth-test.c" \
    "$root/README.md" \
    "$root/LICENSE" \
    "$root/SECURITY.md" \
    "$root/ATTRIBUTIONS.md" \
    "$root/THIRD_PARTY_LICENSES/github.com/charmbracelet/bubbletea/LICENSE" \
    "$root/THIRD_PARTY_LICENSES/golang.org/x/sys/unix/LICENSE"; do
    tar -tzf "$archive" | grep -Fx "$required" >/dev/null ||
        { printf 'package_test: missing %s\n' "$required" >&2; exit 1; }
done

if tar -tzf "$archive" | grep -Eq '/(\.git|tui|tests|docs|scripts)/'; then
    printf 'package_test: source-only content leaked into archive\n' >&2
    exit 1
fi

extract_dir="$test_dir/extracted"
mkdir "$extract_dir"
tar -C "$extract_dir" -xzf "$archive"
[[ -x "$extract_dir/$root/tweaks.sh" &&
    -x "$extract_dir/$root/build/tweaks-tui" ]] ||
    { printf 'package_test: runtime entrypoints are not executable\n' >&2; exit 1; }
(
    cd "$extract_dir/$root"
    ./tweaks.sh --help >/dev/null
    ./build/tweaks-tui --help >/dev/null
)

( cd "$test_dir" && sha256sum "${archive##*/}" >SHA256SUMS )
portable_root="$test_dir/portable"
portable_bin="$test_dir/bin"
TWEAKS_RELEASE_BASE_URL="file://$test_dir" \
TWEAKS_PORTABLE_ROOT="$portable_root" \
TWEAKS_PORTABLE_BIN_DIR="$portable_bin" \
    bash "$repo_dir/scripts/install-portable.sh"
[[ $(readlink "$portable_root/current") == versions/1.2.3 ]] ||
    { printf 'package_test: portable current link is incorrect\n' >&2; exit 1; }
grep -Fx '# Managed by Tweaks for CachyOS portable installer.' \
    "$portable_bin/tweaks-for-cachyos" >/dev/null ||
    { printf 'package_test: portable wrapper is not marked as managed\n' >&2; exit 1; }
"$portable_bin/tweaks-for-cachyos" --help >/dev/null
(
    register_module_doc() { :; }
    declare -a SYSTEM_TWEAKS=()
    declare -a EX_IDS=() EX_LABELS=() EX_DISABLED=() EX_CAPTURE=() EX_PRIVILEGED=() EX_DESC=()
    CACHYOS_TWEAKS_PORTABLE_ROOT=$portable_root
    # shellcheck source=modules/system/memory/presets.sh
    . "$portable_root/current/modules/system/memory/presets.sh"
    system_extra_build
    [[ "${EX_IDS[0]}" == update-suite &&
        "${EX_LABELS[0]}" == 'Update Tweaks for CachyOS' &&
        "${EX_PRIVILEGED[0]}" == 0 ]]
) || {
    printf 'package_test: portable update action is missing from the TUI protocol\n' >&2
    exit 1
}
CACHYOS_TWEAKS_PORTABLE_ROOT="$portable_root" \
CACHYOS_TWEAKS_PORTABLE_BIN_DIR="$portable_bin" \
TWEAKS_RELEASE_BASE_URL="file://$test_dir" \
    bash "$portable_root/current/tweaks.sh" update |
    grep -F 'is already current.' >/dev/null ||
    { printf 'package_test: portable update was not idempotent\n' >&2; exit 1; }

bash "$repo_dir/scripts/package-release.sh" v1.2.4 amd64 \
    "$fake_binary" "$test_dir"
next_archive="$test_dir/tweaks-for-cachyos-1.2.4-linux-amd64.tar.gz"
( cd "$test_dir" && sha256sum "${next_archive##*/}" >SHA256SUMS )
CACHYOS_TWEAKS_PORTABLE_ROOT="$portable_root" \
CACHYOS_TWEAKS_PORTABLE_BIN_DIR="$portable_bin" \
TWEAKS_RELEASE_BASE_URL="file://$test_dir" \
    "$portable_bin/tweaks-for-cachyos" update >/dev/null
[[ $(readlink "$portable_root/current") == versions/1.2.4 &&
    -d "$portable_root/versions/1.2.3" ]] ||
    { printf 'package_test: portable update was not atomic or dropped its rollback\n' >&2; exit 1; }

printf 'release package tests passed\n'

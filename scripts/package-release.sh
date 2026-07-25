#!/usr/bin/env bash
# Build a minimal, self-contained release archive from a compiled TUI binary.
set -Eeuo pipefail

[[ $# == 4 ]] || {
    printf 'usage: %s VERSION ARCH BINARY OUTPUT_DIR\n' "${0##*/}" >&2
    exit 2
}

version=${1#v}
arch=$2
binary=$3
output_dir=$4
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] || {
    printf 'invalid version: %s\n' "$version" >&2
    exit 2
}
[[ "$arch" == amd64 || "$arch" == arm64 ]] || {
    printf 'invalid architecture: %s\n' "$arch" >&2
    exit 2
}
[[ ${SOURCE_DATE_EPOCH:-0} =~ ^[0-9]+$ ]] || {
    printf 'invalid SOURCE_DATE_EPOCH: %s\n' "$SOURCE_DATE_EPOCH" >&2
    exit 2
}
[[ -f "$binary" ]] || {
    printf 'binary not found: %s\n' "$binary" >&2
    exit 2
}

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
archive_root="tweaks-for-cachyos-$version-linux-$arch"
work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT

install -d "$work_dir/$archive_root/build" "$output_dir"
install -m 0755 "$binary" "$work_dir/$archive_root/build/tweaks-tui"
install -m 0755 "$repo_dir/tweaks.sh" "$work_dir/$archive_root/tweaks.sh"
install -m 0755 "$repo_dir/scripts/install-portable.sh" \
    "$work_dir/$archive_root/install-portable.sh"
install -m 0644 "$repo_dir/pam-auth-test.c" "$repo_dir/README.md" \
    "$repo_dir/LICENSE" "$repo_dir/SECURITY.md" "$repo_dir/ATTRIBUTIONS.md" \
    "$work_dir/$archive_root/"
cp -a "$repo_dir/lib" "$repo_dir/modules" "$work_dir/$archive_root/"
cp -a "$repo_dir/THIRD_PARTY_LICENSES" "$work_dir/$archive_root/"

tar -C "$work_dir" --sort=name --mtime="@${SOURCE_DATE_EPOCH:-0}" \
    --owner=0 --group=0 --numeric-owner \
    -czf "$output_dir/$archive_root.tar.gz" "$archive_root"
printf 'created %s/%s.tar.gz\n' "$output_dir" "$archive_root"

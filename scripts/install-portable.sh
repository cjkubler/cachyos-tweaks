#!/usr/bin/env bash
# Install or update a self-contained Tweaks for CachyOS release without pacman.
set -Eeuo pipefail

readonly PROGRAM_NAME=tweaks-for-cachyos
readonly REPOSITORY=cjkubler/cachyos-tweaks
readonly WRAPPER_MARKER='# Managed by Tweaks for CachyOS portable installer.'

mode=install
case ${1:-} in
    '') ;;
    --update) mode=update ;;
    -h|--help)
        cat <<'EOF'
Usage: install-portable.sh [--update]

Install the latest portable Tweaks for CachyOS release for the current user.
The --update form is used by an existing managed portable installation.
EOF
        exit 0
        ;;
    *)
        printf 'install-portable.sh: unknown option: %s\n' "$1" >&2
        exit 2
        ;;
esac

die() {
    printf 'install-portable.sh: %s\n' "$*" >&2
    exit 1
}

(( EUID != 0 )) || die 'run the portable installer without sudo'

for command in awk chmod curl install ln mktemp mv readlink rm rmdir sha256sum tar uname; do
    command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

if [[ "$mode" == update ]]; then
    install_root=${CACHYOS_TWEAKS_PORTABLE_ROOT:-}
    bin_dir=${CACHYOS_TWEAKS_PORTABLE_BIN_DIR:-}
    [[ -n "$install_root" && -n "$bin_dir" ]] ||
        die 'this installation is not managed by the portable installer'
else
    [[ -n ${HOME:-} ]] ||
        die 'HOME is not set; specify TWEAKS_PORTABLE_ROOT and TWEAKS_PORTABLE_BIN_DIR'
    data_home=${XDG_DATA_HOME:-"${HOME:-}/.local/share"}
    install_root=${TWEAKS_PORTABLE_ROOT:-"$data_home/$PROGRAM_NAME"}
    bin_dir=${TWEAKS_PORTABLE_BIN_DIR:-"${HOME:-}/.local/bin"}
fi

[[ "$install_root" == /* && "$bin_dir" == /* ]] ||
    die 'the portable install and command directories must be absolute paths'
[[ "$install_root" != / && "$bin_dir" != / ]] ||
    die 'refusing to use a filesystem root as an install directory'

case $(uname -m) in
    x86_64) release_arch=amd64 ;;
    aarch64) release_arch=arm64 ;;
    *) die "no portable release is available for architecture: $(uname -m)" ;;
esac

release_base=${TWEAKS_RELEASE_BASE_URL:-"https://github.com/$REPOSITORY/releases/latest/download"}
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tweaks-for-cachyos-install.XXXXXX")
stage_dir=''
cleanup() {
    local status=$?
    set +e
    [[ -z "$stage_dir" || ! -d "$stage_dir" ]] || rm -rf -- "$stage_dir"
    rm -rf -- "$work_dir"
    exit "$status"
}
trap cleanup EXIT

sums_file="$work_dir/SHA256SUMS"
curl -fsSL "$release_base/SHA256SUMS" -o "$sums_file" ||
    die 'could not download the latest release checksums'

asset=$(awk -v arch="$release_arch" '
    $1 ~ /^[[:xdigit:]]{64}$/ &&
    $2 ~ ("^tweaks-for-cachyos-[0-9]+\\.[0-9]+\\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?-linux-" arch "\\.tar\\.gz$") {
        print $2
        found++
    }
    END {
        if (found != 1) {
            exit 1
        }
    }
' "$sums_file") || die "the latest release does not identify exactly one $release_arch archive"

version=${asset#"tweaks-for-cachyos-"}
version=${version%"-linux-$release_arch.tar.gz"}
archive_root=${asset%.tar.gz}
archive="$work_dir/$asset"

printf 'Downloading Tweaks for CachyOS %s (%s)...\n' "$version" "$release_arch"
curl -fL --progress-bar "$release_base/$asset" -o "$archive" ||
    die 'release download failed'

expected=$(awk -v asset="$asset" '$2 == asset { print $1; exit }' "$sums_file")
actual=$(sha256sum "$archive" | awk '{ print $1 }')
[[ "$actual" == "$expected" ]] || die 'release checksum verification failed'

# Verify the asset against the release manifest. These structural checks also
# prevent an accidentally malformed archive from escaping its version folder.
tar -tzf "$archive" |
    awk -v root="$archive_root/" '
        index($0, root) != 1 || $0 ~ /(^|\/)\.\.(\/|$)/ { bad = 1 }
        END { exit bad }
    ' || die 'release archive contains an unsafe path'

versions_dir="$install_root/versions"
target_dir="$versions_dir/$version"
command_path="$bin_dir/$PROGRAM_NAME"
install -d -m 0755 "$versions_dir" "$bin_dir"

if [[ -e "$command_path" || -L "$command_path" ]]; then
    wrapper_line_one=''
    wrapper_line_two=''
    if [[ -f "$command_path" ]]; then
        {
            IFS= read -r wrapper_line_one || true
            IFS= read -r wrapper_line_two || true
        } <"$command_path"
    fi
    if [[ "$wrapper_line_one" != '#!/usr/bin/env bash' ||
        "$wrapper_line_two" != "$WRAPPER_MARKER" ]]; then
        die "refusing to replace an unmanaged command: $command_path"
    fi
fi
if [[ -e "$install_root/current" && ! -L "$install_root/current" ]]; then
    die "refusing to replace a non-symlink: $install_root/current"
fi
if [[ -L "$target_dir" || ( -e "$target_dir" && ! -d "$target_dir" ) ]]; then
    die "refusing to replace an invalid release path: $target_dir"
fi

if [[ -d "$target_dir" ]]; then
    [[ -f "$target_dir/.release-sha256" ]] ||
        die "existing release directory is not managed: $target_dir"
    [[ "$(<"$target_dir/.release-sha256")" == "$expected" ]] ||
        die "release $version is already installed with a different checksum"
else
    stage_dir=$(mktemp -d "$versions_dir/.install-$version.XXXXXX")
    tar --extract --gzip --file "$archive" --directory "$stage_dir" \
        --no-same-owner --no-same-permissions
    extracted="$stage_dir/$archive_root"
    [[ -x "$extracted/tweaks.sh" &&
        -x "$extracted/build/tweaks-tui" &&
        -x "$extracted/install-portable.sh" ]] ||
        die 'release archive is missing a required executable'
    printf '%s\n' "$expected" >"$extracted/.release-sha256"
    chmod 0644 "$extracted/.release-sha256"
    mv -- "$extracted" "$target_dir"
    rmdir -- "$stage_dir"
    stage_dir=''
fi

current_target=$(readlink "$install_root/current" 2>/dev/null || true)
if [[ "$current_target" != "versions/$version" ]]; then
    next_link="$install_root/.current.$$"
    ln -s "versions/$version" "$next_link"
    mv -Tf -- "$next_link" "$install_root/current"
fi

wrapper_tmp=$(mktemp "$bin_dir/.tweaks-for-cachyos.XXXXXX")
{
    printf '%s\n' '#!/usr/bin/env bash' "$WRAPPER_MARKER"
    printf 'export CACHYOS_TWEAKS_PROGRAM=%q\n' "$PROGRAM_NAME"
    printf 'export CACHYOS_TWEAKS_COMMAND=%q\n' "$PROGRAM_NAME"
    printf 'export CACHYOS_TWEAKS_PORTABLE_ROOT=%q\n' "$install_root"
    printf 'export CACHYOS_TWEAKS_PORTABLE_BIN_DIR=%q\n' "$bin_dir"
    printf 'exec %q/current/tweaks.sh "$@"\n' "$install_root"
} >"$wrapper_tmp"
chmod 0755 "$wrapper_tmp"
mv -Tf -- "$wrapper_tmp" "$command_path"

if [[ "$mode" == update && "$current_target" == "versions/$version" ]]; then
    printf 'Tweaks for CachyOS %s is already current.\n' "$version"
else
    printf 'Tweaks for CachyOS %s is installed.\n' "$version"
fi
printf 'Command: %s\n' "$command_path"
case :$PATH: in
    *:"$bin_dir":*) ;;
    *) printf 'Add %s to PATH before launching %s.\n' "$bin_dir" "$PROGRAM_NAME" ;;
esac

# Maintainer: Christian Kubler <ckubler@polyfabrica.com>
pkgname=tweaks-for-cachyos-git
_appname=tweaks-for-cachyos
_srcname=cachyos-tweaks
pkgver=0.1.0.r1
pkgrel=1
pkgdesc='Development version of a terminal interface for reversible CachyOS system tweaks'
arch=('x86_64' 'aarch64')
url='https://github.com/cjkubler/cachyos-tweaks'
license=('MIT')
depends=(
    'bash'
    'coreutils'
    'gawk'
    'grep'
    'pacman'
    'pam'
    'procps-ng'
    'sed'
    'sudo'
    'systemd'
    'util-linux'
)
makedepends=('git' 'go')
checkdepends=('shellcheck')
optdepends=(
    'gcc: compile the optional U2F enrollment verifier'
    'iw: inspect and configure wireless regulatory domains'
    'libfido2: detect connected FIDO2/U2F authenticators'
    'networkmanager: apply NetworkManager-specific power settings'
    'pam-u2f: enable U2F authentication'
    'pciutils: hardware detection and eGPU diagnostics'
    'snapper: automatic and manual system snapshots'
    'usbutils: USB device diagnostics'
)
provides=("$_appname=$pkgver")
conflicts=("$_appname")
options=('!debug')
source=("$_srcname::git+$url.git#branch=main")
sha256sums=('SKIP')

pkgver() {
    cd "$srcdir/$_srcname"
    printf '0.1.0.r%s' "$(git rev-list --count HEAD)"
}

build() {
    local goarch
    case $CARCH in
        x86_64) goarch=amd64 ;;
        aarch64) goarch=arm64 ;;
        *) return 1 ;;
    esac

    cd "$srcdir/$_srcname/tui"
    CGO_ENABLED=0 GOOS=linux GOARCH=$goarch \
        GOCACHE="$srcdir/go-cache" \
        go build -mod=readonly -trimpath -ldflags='-s -w' \
        -o "$srcdir/tweaks-tui" .
}

check() {
    cd "$srcdir/$_srcname"
    GOCACHE="$srcdir/go-cache" make check
}

package() {
    local source_dir="$srcdir/$_srcname"
    local appdir="$pkgdir/usr/lib/$_appname"

    install -d "$appdir/build" "$appdir/lib" "$appdir/modules"
    install -m0755 "$srcdir/tweaks-tui" "$appdir/build/tweaks-tui"
    install -m0755 "$source_dir/tweaks.sh" "$appdir/tweaks.sh"
    install -m0644 "$source_dir/pam-auth-test.c" "$appdir/pam-auth-test.c"
    install -m0644 \
        "$source_dir/README.md" \
        "$source_dir/SECURITY.md" \
        "$source_dir/ATTRIBUTIONS.md" \
        "$source_dir/LICENSE" \
        "$appdir/"
    cp -a "$source_dir/lib/." "$appdir/lib/"
    cp -a "$source_dir/modules/." "$appdir/modules/"

    install -Dm0755 "$source_dir/packaging/tweaks-for-cachyos" \
        "$pkgdir/usr/bin/$_appname"
    install -Dm0644 "$source_dir/LICENSE" \
        "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
    install -d "$pkgdir/usr/share/licenses/$pkgname/THIRD_PARTY_LICENSES"
    cp -a "$source_dir/THIRD_PARTY_LICENSES/." \
        "$pkgdir/usr/share/licenses/$pkgname/THIRD_PARTY_LICENSES/"
    ln -s "/usr/share/licenses/$pkgname/THIRD_PARTY_LICENSES" \
        "$appdir/THIRD_PARTY_LICENSES"

    install -Dm0644 "$source_dir/README.md" \
        "$pkgdir/usr/share/doc/$pkgname/README.md"
    install -Dm0644 "$source_dir/CONTRIBUTING.md" \
        "$pkgdir/usr/share/doc/$pkgname/CONTRIBUTING.md"
    install -Dm0644 "$source_dir/docs/ARCHITECTURE.md" \
        "$pkgdir/usr/share/doc/$pkgname/ARCHITECTURE.md"
}

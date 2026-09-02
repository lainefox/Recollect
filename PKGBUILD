# Maintainer: Laine <lainefox@proton.me>
#
# Source package — compiled by makepkg. Downloads the source tarball from the
# v1.0.0 git tag on GitHub. For a precompiled binary, see PKGBUILD-bin.

pkgname=recollect
pkgver=1.0.0
pkgrel=1
pkgdesc="Search for text inside your images using OCR"
arch=('x86_64' 'aarch64')
url="https://github.com/lainefox/Recollect"
license=('GPL-3.0-or-later')
depends=(
	'glib2'
	'gtk4'
	'libadwaita'
	'sqlite'
	'tesseract'
	'glycin'
	'glycin-gtk4'
	'json-glib'
	'libsoup3'
	'gdk-pixbuf2'
)
makedepends=(
	'vala'
	'meson'
	'ninja'
	'gobject-introspection'  # needed by the Gom-Vala subproject for GIR
	'git'  # needed to fetch the Gom-Vala meson wrap at build time
)
source=("$pkgname-$pkgver.tar.gz::https://github.com/lainefox/Recollect/archive/v$pkgver.tar.gz")
sha256sums=('SKIP')  # TODO: replace with real hash after tagging v1.0.0

build() {
	# cd into the extracted source dir (GitHub archive extracts to Recollect-1.0.0).
	cd "$srcdir/Recollect-$pkgver"
	# AUR builds are distro-packaged: disable the in-app update checker.
	# Flatpak builds (build-aux/flatpak) keep it enabled by default.
	meson setup build --prefix=/usr -Dupdate-checker=false
	meson compile -C build
}

package() {
	cd "$srcdir/Recollect-$pkgver"
	meson install -C build --destdir "$pkgdir"
}
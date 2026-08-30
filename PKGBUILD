# Maintainer: Laine <lainefox@proton.me>
#
# NOTE: This PKGBUILD expects a `v0.1.0` git tag to exist on
# https://github.com/lainefox/Recollect. Create it before building:
#   git tag v0.1.0 && git push origin v0.1.0
# Then replace the SKIP sha256sum with the real one from the tarball.

pkgname=recollect
pkgver=0.1.0
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
	'git'  # needed to fetch the Gom-Vala meson wrap at build time
)
source=("$pkgname-$pkgver.tar.gz::https://github.com/lainefox/Recollect/archive/v$pkgver.tar.gz")
sha256sums=('SKIP')  # TODO: replace with real hash after tagging v0.1.0

build() {
	meson setup build --prefix=/usr
	meson compile -C build
}

package() {
	meson install -C build --destdir "$pkgdir"
}
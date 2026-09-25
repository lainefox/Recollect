#!/bin/sh
# Verify that everything we are about to release agrees on the app version.
#
# Flatpak (and GNOME Software / Discover) take the version of an app from the
# newest <release> entry in its AppStream metadata, so a metainfo file whose
# entries are out of order, or that was not updated for a release, ships a
# bundle that claims a different version than the one it is tagged with.
#
# Usage: check-version.sh [VERSION] [BUNDLE]
#
#   VERSION  expected version, defaults to the current git tag
#   BUNDLE   optional .flatpak bundle to inspect as well
#
# Exits non-zero on a mismatch. Missing inspection tools are reported as a
# warning only, so a runner without ostree does not block a release.
set -eu

app_id='org.laine.Recollect'
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
metainfo="$root/data/$app_id.metainfo.xml.in"

version=${1:-}
if [ -z "$version" ]; then
	version=${GITHUB_REF_NAME:-$(git -C "$root" describe --tags --abbrev=0)}
	version=${version#v}
fi

bundle=${2:-}
status=0
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT INT TERM

warn() { printf 'warning: %s\n' "$1" >&2; }
fail() { printf 'error: %s\n' "$1" >&2; status=1; }

# Print "<timestamp>\t<version>" for every release entry of a metainfo-style
# XML file, one per line. Timestamps are normalised to a single comparable
# form, so a release with a bare date counts as midnight UTC.
collect_releases() {
	grep -o '<release [^>]*>' "$1" | while IFS= read -r tag; do
		rel_version=$(printf '%s' "$tag" | sed -n 's/.*version="\([^"]*\)".*/\1/p')
		rel_date=$(printf '%s' "$tag" | sed -n 's/.*date="\([^"]*\)".*/\1/p')
		[ -n "$rel_date" ] || rel_date=$(printf '%s' "$tag" | sed -n 's/.*timestamp="\([^"]*\)".*/\1/p')
		case "$rel_date" in
			*[Tt]*) : ;;
			*) rel_date="${rel_date}T00:00:00Z" ;;
		esac
		printf '%s\t%s\n' "$rel_date" "$rel_version"
	done
}

# Newest release version in a metainfo-style XML file.
newest_release() {
	collect_releases "$1" | sort | tail -n 1 | cut -f 2
}

# Warn about releases that share a timestamp: the newest one is then picked by
# document order, which differs between flatpak and the software centres.
report_ambiguity() {
	for stamp in $(collect_releases "$1" | cut -f 1 | sort | uniq -d); do
		fail "$2 has more than one release dated $stamp"
	done
}

# The flatpak bundle carries the same AppStream metadata, so check the version
# a user would actually see after installing it.
check_bundle() {
	for tool in flatpak ostree gzip; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			warn "$tool is unavailable, not checking the version of $1"
			return
		fi
	done

	import="flatpak build-import-bundle"
	if command -v fakeroot >/dev/null 2>&1; then
		import="fakeroot flatpak build-import-bundle"
	fi
	mkdir -p "$tmpdir/repo"
	if ! ostree --repo="$tmpdir/repo" init --mode=archive-z2 ||
		! $import "$tmpdir/repo" "$1" >/dev/null 2>&1; then
		warn "could not import $1, not checking its version"
		return
	fi

	ref=$(ostree --repo="$tmpdir/repo" refs | head -n 1)
	if [ -z "$ref" ]; then
		warn "$1 has no commit, not checking its version"
		return
	fi
	commit=$(ostree --repo="$tmpdir/repo" rev-parse "$ref")

	metadata=$(ostree --repo="$tmpdir/repo" ls -R "$commit" files/share 2>/dev/null |
		grep -e '/files/share/app-info/xmls/.*\.xml\.gz$' |
		head -n 1 | awk '{print $NF}')
	if [ -z "$metadata" ]; then
		warn "$1 has no AppStream metadata, not checking its version"
		return
	fi
	ostree --repo="$tmpdir/repo" cat "$commit" "$metadata" > "$tmpdir/appinfo.xml.gz"
	gzip -dc "$tmpdir/appinfo.xml.gz" > "$tmpdir/appinfo.xml"

	bundled=$(newest_release "$tmpdir/appinfo.xml")
	if [ "$bundled" != "$version" ]; then
		fail "$1 reports version $bundled, expected $version"
	else
		printf 'bundle %s reports version %s\n' "$1" "$bundled"
	fi
	report_ambiguity "$tmpdir/appinfo.xml" "the AppStream metadata in $1"
}

printf 'checking version %s\n' "$version"

meson_version=$(sed -n "s/^ *version: *'\([0-9.]*\)'.*/\1/p" "$root/meson.build" | head -n 1)
if [ "$meson_version" != "$version" ]; then
	fail "meson.build declares $meson_version, expected $version"
fi

if [ -f "$root/build-aux/PKGBUILD-bin" ]; then
	pkgver=$(sed -n 's/^pkgver=//p' "$root/build-aux/PKGBUILD-bin" | head -n 1)
	if [ "$pkgver" != "$version" ]; then
		fail "build-aux/PKGBUILD-bin has pkgver=$pkgver, expected $version"
	fi
fi

if [ ! -f "$metainfo" ]; then
	fail "missing $metainfo"
else
	release=$(newest_release "$metainfo")
	if [ "$release" != "$version" ]; then
		fail "the newest release in $metainfo is $release, expected $version"
	fi
	report_ambiguity "$metainfo" "$metainfo"
fi

if [ -n "$bundle" ]; then
	check_bundle "$bundle"
fi

if [ "$status" -eq 0 ]; then
	printf 'version %s looks consistent\n' "$version"
fi
exit "$status"

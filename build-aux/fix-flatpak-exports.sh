#!/usr/bin/env bash
# fix-flatpak-exports.sh — Repair a broken system-level flatpak install.
#
# An interrupted `sudo flatpak uninstall` can leave an orphaned deployment
# behind (missing current/active symlinks) plus broken export symlinks in
# /var/lib/flatpak/exports/. The app then vanishes from the app grid.
#
# This script detects that state and cleans it up. It never touches a
# healthy install — it only removes things that are already broken.

set -euo pipefail

APP_ID="org.laine.Recollect"
APP_DIR="/var/lib/flatpak/app/$APP_ID"
EXPORTS="/var/lib/flatpak/exports"

needs_fix=false

echo "== Checking $APP_ID flatpak install =="

# 1. Deployment state
if [[ -d "$APP_DIR" ]]; then
	if [[ -L "$APP_DIR/current" && -e "$APP_DIR/current" ]]; then
		echo "  deployment: OK (current -> $(readlink "$APP_DIR/current"))"
	else
		echo "  deployment: ORPHANED (missing valid current/active symlink)"
		needs_fix=true
	fi
else
	echo "  deployment: not present (nothing to do)"
fi

# 2. Export symlinks
broken_exports=()
for link in \
	"$EXPORTS/bin/$APP_ID" \
	"$EXPORTS/share/applications/$APP_ID.desktop" \
	"$EXPORTS/share/icons/hicolor/scalable/apps/$APP_ID.svg" \
	"$EXPORTS/share/icons/hicolor/symbolic/apps/$APP_ID-symbolic.svg" \
	"$EXPORTS/share/metainfo/$APP_ID.metainfo.xml"; do
	if [[ -L "$link" && ! -e "$link" ]]; then
		echo "  broken export: $link"
		broken_exports+=("$link")
		needs_fix=true
	fi
done
if [[ ${#broken_exports[@]} -eq 0 ]]; then
	echo "  exports: OK (no broken symlinks)"
fi

if [[ "$needs_fix" == false ]]; then
	echo "== Nothing to fix — install is healthy. =="
	exit 0
fi

echo "== Cleaning up =="
sudo rm -rf "$APP_DIR" "${broken_exports[@]}"
sudo gtk-update-icon-cache -f "$EXPORTS/share/icons/hicolor/" 2>/dev/null || true
sudo update-desktop-database "$EXPORTS/share/applications/" 2>/dev/null || true

echo "== Done. Reinstall the app: =="
echo "  flatpak install --user recollect.flatpak"
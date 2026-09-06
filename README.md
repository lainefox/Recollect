<picture>
  <source media="(prefers-color-scheme: dark)" srcset="data/icons/hicolor/scalable/apps/org.laine.Recollect.svg">
  <img alt="Recollect" src="data/icons/hicolor/scalable/apps/org.laine.Recollect.svg" width="64" height="64">
</picture>

# Recollect

Recollect scans images with Tesseract OCR, indexes extracted text in a local SQLite database (via Gom), and provides a fast search UI built with GTK4 and libadwaita.

## Features

- **OCR-powered image text search**: direct Tesseract C API, no CLI dependency
- **Fast local search**: SQLite database via Gom ORM
- **List and grid view modes**: toggle between compact results and thumbnail tiles
- **Image preview sidebar**: extracted OCR text and file properties at a glance
- **Flexible search filters**: fuzzy, case-sensitive, whole-word, and diacritics matching
- **Sort by name or date**: ascending or descending
- **Date range filtering**: narrow results by scan date
- **Incremental file monitoring**: folders are watched for changes and re-indexed automatically
- **Downloadable language models**: fast, balanced, and best Tesseract variants
- **Onboarding wizard**: guides first-time setup of folders and models
- **Keyboard shortcuts**: full shortcut reference available in-app (Ctrl+?)
- **Background scanning**: continues indexing even when the window is closed
- **Internationalization**: gettext-based translations
- **13 image formats supported**: PNG, JPEG, TIFF, BMP, WebP, GIF, AVIF, HEIC/HEIF, JPEG XL, SVG

## How it works

Recollect watches your chosen folders and runs each image through Tesseract OCR to extract its text. That text is stored in a local SQLite database, so searching is instant, with no re-scanning needed. When you type a query, Recollect matches against the indexed text and shows the matching images with a snippet of the recognized content.

## Installation

Precompiled flatpak bundles are attached to each [GitHub release](https://github.com/lainefox/Recollect/releases). Download `recollect.flatpak` and install it:

```bash
flatpak install --user recollect.flatpak
```

> **Always use `--user`.** Installing at system level (`sudo flatpak install`) can leave orphaned files behind if an uninstall is interrupted, which breaks the desktop icon and app entry.

### Troubleshooting: missing desktop icon

If the app launches but shows no icon (or doesn't appear in the app grid), the most common cause is a **stale native-install desktop file** shadowing the flatpak one. The native install (`meson install` to `~/.local`) writes `~/.local/share/applications/org.laine.Recollect.desktop` with `Exec=recollect` — a bare command that GIO can't resolve (the desktop shell's `PATH` doesn't include `~/.local/bin`), which makes the app vanish from the app grid entirely.

Check if a native desktop file exists:

```bash
cat ~/.local/share/applications/org.laine.Recollect.desktop
```

If it has `Exec=recollect` (not an absolute path), remove it and reinstall the flatpak:

```bash
rm ~/.local/share/applications/org.laine.Recollect.desktop
flatpak install --user recollect.flatpak
```

> Since v1.1.0 the native desktop file uses an absolute `Exec` path, so this conflict no longer occurs for fresh installs. If you still see a bare `Exec=recollect`, rebuild and reinstall from source.

If the app still doesn't appear, a previous system-level install may have left broken export symlinks. Check for them:

```bash
ls -la /var/lib/flatpak/exports/share/applications/org.laine.Recollect.desktop
```

If the symlink is broken (points to a non-existent `current/active` path), run the bundled repair script — it detects the orphaned deployment and broken exports, removes only what's broken, and refreshes the caches:

```bash
build-aux/fix-flatpak-exports.sh
```

Then reinstall with `flatpak install --user recollect.flatpak`.

> The script never touches a healthy install — it only removes things that are already broken. If you prefer to do it by hand, the equivalent commands are:

> ```bash
> sudo rm -rf /var/lib/flatpak/app/org.laine.Recollect /var/lib/flatpak/exports/bin/org.laine.Recollect /var/lib/flatpak/exports/share/applications/org.laine.Recollect.desktop /var/lib/flatpak/exports/share/icons/hicolor/scalable/apps/org.laine.Recollect.svg /var/lib/flatpak/exports/share/icons/hicolor/symbolic/apps/org.laine.Recollect-symbolic.svg /var/lib/flatpak/exports/share/metainfo/org.laine.Recollect.metainfo.xml
> ```
>
> ```bash
> sudo gtk-update-icon-cache -f /var/lib/flatpak/exports/share/icons/hicolor/ && sudo update-desktop-database /var/lib/flatpak/exports/share/applications/
> ```

## Building from source

### Dependencies (Arch Linux)

```bash
sudo pacman -S vala meson ninja gtk4 libadwaita sqlite tesseract \
               glycin glycin-gtk4 json-glib libsoup3
```

Other distributions: install the equivalent packages for each dependency.  
A [Gom-Vala](https://github.com/spotshare-ykary-com/Gom-Vala) fork is auto-fetched via meson wrap, so no manual setup is needed.

### Build and install

```bash
meson setup build --prefix="$HOME/.local"
meson compile -C build
meson install -C build
```

The binary is installed to `~/.local/bin/recollect`.

## Troubleshooting

### `libgom.so.0: cannot open shared object file`

If you see this error at runtime, the dynamic linker can't find the Gom library.
Rebuild with the rpath fix applied (already included if you're using the latest
build files):

```bash
meson setup build --prefix="$HOME/.local" --reconfigure
meson compile -C build
meson install -C build
```

Alternatively, set `LD_LIBRARY_PATH`:

```bash
export LD_LIBRARY_PATH="$HOME/.local/lib:$LD_LIBRARY_PATH"
~/.local/bin/recollect
```

### Subproject `gom-vala` has no `meson.build` file

If `meson setup` fails with this error, it means the `subprojects/gom-vala/`
directory is missing its top-level `meson.build`. Ensure the repository includes
`subprojects/gom-vala/meson.build` and `subprojects/gom-vala/gom/meson.build`
with the correct include directory (pointing to `'.'`, not `'..'`).

### Development profile

Use a separate application ID (`org.laine.Recollect.Devel`) so development builds
don't interfere with the installed release:

```bash
meson configure build -Dprofile=development
meson compile -C build
```

Switch back to the release profile with:

```bash
meson configure build -Dprofile=default
meson compile -C build
```

## Usage

### CLI flags

| Flag | Description |
|------|-------------|
| `--reset` | Reset all settings to defaults |
| `--no-system-models` | Skip system Tesseract models; only use downloaded ones |
| `--background` | Start without a window (used by the autostart entry) |

## AI Disclosure

This program was written with the assistance of large language models (LLMs).
The UI/UX design, visual layout, and application icon were created entirely by
human effort (aka me, **laine**). [OpenCode](https://opencode.ai) made working on this project a breeze, shoutout <3

## License

Recollect is licensed under the [GNU General Public License v3.0](LICENSE).


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

## Building

### Dependencies (Arch Linux)

```bash
sudo pacman -S vala meson ninja gtk4 libadwaita sqlite tesseract \
               glycin glycin-gtk4 json-glib libsoup3
```

Other distributions: install the equivalent packages for each dependency.  
A Gom-Vala fork is auto-fetched via meson wrap — no manual setup needed.

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

Run without arguments to launch the GUI:

```bash
~/.local/bin/recollect
```

## AI Disclosure

This program was written with the assistance of large language models (LLMs).
The UI/UX design, visual layout, and application icon were created entirely by
human effort.


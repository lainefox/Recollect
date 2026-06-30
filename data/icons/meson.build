# App icons installed to hicolor theme directories
scalable_source = meson.current_source_dir() / 'hicolor' / 'scalable' / 'apps'
symbolic_source = meson.current_source_dir() / 'hicolor' / 'symbolic' / 'apps'

# Main app icon (uses .Devel variant in development profile)
if is_devel
  install_data(
    scalable_source / base_id + '.Devel.svg',
    install_dir: datadir / 'icons' / 'hicolor' / 'scalable' / 'apps',
    rename: application_id + '.svg',
  )
else
  install_data(
    scalable_source / base_id + '.svg',
    install_dir: datadir / 'icons' / 'hicolor' / 'scalable' / 'apps',
    rename: application_id + '.svg',
  )
endif

# Symbolic app icon
install_data(
  symbolic_source / base_id + '-symbolic.svg',
  install_dir: datadir / 'icons' / 'hicolor' / 'symbolic' / 'apps',
  rename: application_id + '-symbolic.svg',
)

# Generate configuration constants for Vala
config_vala = configure_file(
  input: 'Config.vala.in',
  output: 'config.vala',
  configuration: conf
)

# Vala sources
recollect_sources = [
  config_vala,

  # Entry point
  'main.vala',

  # Models
  'Models/ImageEntry.vala',
  'Models/Folder.vala',
  'Models/SortConfig.vala',
  'Models/TesseractModel.vala',

  # Services
  'Services/SettingsService.vala',
  'Services/DatabaseService.vala',
  'Services/OcrService.vala',
  'Services/ScannerService.vala',
  'Services/ThumbnailService.vala',
  'Services/TesseractModelService.vala',

  # Utils
  'Utils/Utils.vala',

  # Views
  'Views/ResultsListView.vala',
  'Views/ResultsGridView.vala',
  'Views/ImagePreviewSidebar.vala',
  'Views/ProgressPie.vala',
  'Views/SortPopover.vala',
  'Views/FilterPopover.vala',
  'Views/ScanPopover.vala',
  'MainWindow.vala',
  'PreferencesDialog.vala',
  'DownloadModelsDialog.vala',
  'OnboardingDialog.vala',

  # Application
  'Application.vala',
]

# Dependencies
recollect_deps = [
  libadwaita_dep,
  gtk_dep,
  glib_dep,
  gio_dep,
  gom_dep,
  sqlite_dep,
  tesseract_dep,
  glycin_dep,
  glycin_gtk4_dep,
  json_glib_dep,
  gdk_pixbuf_dep,
  soup_dep,
]

recollect_vapidir = join_paths(meson.current_source_dir(), 'Vapi')

# Compile GResources as a separate .gresource file (installed to pkgdatadir)
recollect_resources = gnome.compile_resources(
  application_id,
  '../data/' + application_id + '.gresource.xml',
  gresource_bundle: true,
  source_dir: ['../data'],
  install: true,
  install_dir: pkgdatadir,
)

executable('recollect',
  recollect_sources,
  recollect_resources,
  vala_args: [
    '--target-glib', '2.70',
    '--vapidir', recollect_vapidir,
    '--girdir', '/usr/share/gir-1.0',
    '--girdir', recollect_vapidir,
    '--pkg', 'gom-1.0',
    '--pkg', 'posix',
  ],
  dependencies: recollect_deps,
  install: true,
  install_rpath: prefix / get_option('libdir'),
  win_subsystem: 'windows',
)

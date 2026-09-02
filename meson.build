project('recollect', 'vala',
	version: '1.0.0',
	meson_version: '>= 0.59.0',
	license: 'GPL-3.0',
)

# Application ID
base_id = 'org.laine.Recollect'
is_devel = get_option('profile') == 'development'
application_id = is_devel ? base_id + '.Devel' : base_id

# Standard paths
prefix = get_option('prefix')
bindir = prefix / get_option('bindir')
datadir = prefix / get_option('datadir')
pkgdatadir = datadir / application_id
localedir = prefix / get_option('localedir')

# Version
recollect_version = meson.project_version()
version_array = recollect_version.split('.')
MAJOR_VERSION = version_array[0]
MINOR_VERSION = version_array[1]
MICRO_VERSION = version_array[2]

# Configuration data
conf = configuration_data()
conf.set_quoted('APPLICATION_ID', application_id)
conf.set_quoted('VERSION', recollect_version)
conf.set_quoted('PKGDATADIR', pkgdatadir)
conf.set_quoted('LOCALEDIR', localedir)
conf.set('GETTEXT_PACKAGE', application_id)
conf.set('MAJOR_VERSION', MAJOR_VERSION)
conf.set('MINOR_VERSION', MINOR_VERSION)
conf.set('MICRO_VERSION', MICRO_VERSION)
conf.set('UPDATE_CHECKER', get_option('update-checker') ? 'true' : 'false')

# Make GETTEXT_PACKAGE available to the C preprocessor for glib/gi18n-lib.h _() macro
add_project_arguments('-DGETTEXT_PACKAGE="@0@"'.format(application_id), language: 'c')

# Vala compiler flags
add_project_arguments('-X', '-fPIC', language: 'vala')

# Imports
gnome = import('gnome')
i18n = import('i18n')

# Dependencies
libadwaita_dep = dependency('libadwaita-1', version: '>= 1.9')
gtk_dep = dependency('gtk4', version: '>= 4.14')
glib_dep = dependency('glib-2.0', version: '>= 2.80')
gio_dep = dependency('gio-2.0', version: '>= 2.80')
sqlite_dep = dependency('sqlite3', version: '>= 3.40')
tesseract_dep = dependency('tesseract', version: '>= 5.0')
glycin_dep = dependency('glycin-2', version: '>= 2.0')
glycin_gtk4_dep = dependency('glycin-gtk4-2', version: '>= 2.0')
json_glib_dep = dependency('json-glib-1.0')
gdk_pixbuf_dep = dependency('gdk-pixbuf-2.0')
soup_dep = dependency('libsoup-3.0', version: '>= 3.0')

# Gom-Vala fork (meson wrap — auto-fetched from GitHub)
gom_sp = subproject('gom-vala')
gom_dep = gom_sp.get_variable('libgom_dep')

# Vala compiler
valac = meson.get_compiler('vala')
if not valac.version().version_compare('>= 0.56')
	error('Vala version 0.56 or higher is required')
endif

# Generate config header
configure_file(
	output: 'config.h',
	configuration: conf
)

# Subdirectories
subdir('data')
subdir('src')
if get_option('enable-i18n')
	subdir('po')
endif

# Post-install
gnome.post_install(
	glib_compile_schemas: true,
	gtk_update_icon_cache: true,
	update_desktop_database: true,
)

# Summary
summary({
	'Application ID': application_id,
	'Version': recollect_version,
	'Profile': get_option('profile'),
	'I18n Support': get_option('enable-i18n'),
	'Prefix': prefix,
}, section: 'Recollect')

project('gom', 'c',
	version: '0.0.1',
	meson_version: '>= 0.59.0',
	license: 'LGPL-2.1',
)

# Library configuration
lib_name = 'gom'
soversion = 0
lt_version = '0.0.0'
lib_version = '0.0'

# GLib version constraints (match the main project)
glib2_major_version = 2
glib2_minor_version = 80

# Enable GIR (needed for Vala bindings)
enable_gir = true

# Imports
gnome = import('gnome')

# Dependencies
glib_dep = dependency('glib-2.0', version: '>= 2.80')
gio_dep = dependency('gio-2.0', version: '>= 2.80')
gobject_dep = dependency('gobject-2.0', version: '>= 2.80')
sqlite3_dep = dependency('sqlite3', version: '>= 3.40')

# Subdirs
subdir('gom')

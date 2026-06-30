# GSettings schema — configured from template, installed directly
configure_file(
	input: base_id + '.gschema.xml.in',
	output: base_id + '.gschema.xml',
	configuration: conf,
	install: true,
	install_dir: datadir / 'glib-2.0' / 'schemas',
)

# Compile GSettings schema
gnome.compile_schemas(
	depend_files: files(base_id + '.gschema.xml.in'),
  build_by_default: true
)

# Desktop file
desktop_conf = configuration_data()
desktop_conf.set('APP_ID', application_id)
configure_file(
	input: base_id + '.desktop.in',
	output: application_id + '.desktop',
	configuration: desktop_conf,
	install: true,
	install_dir: datadir / 'applications',
)

# Metainfo file
metainfo_conf = configuration_data()
metainfo_conf.set('APP_ID', application_id)
configure_file(
	input: base_id + '.metainfo.xml.in',
	output: application_id + '.metainfo.xml',
	configuration: metainfo_conf,
	install: true,
	install_dir: datadir / 'metainfo',
)

# Subdirectories
subdir('icons')

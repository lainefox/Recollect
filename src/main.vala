using GLib;

public static int main(string[] args) {
		// Handle custom flags before passing to GApplication
		string[] filtered_args = {};
		bool did_reset = false;
		foreach(unowned string arg in args) {
				if(arg == "--reset") {
						var service = new SettingsService();
						service.reset_all();
						GLib.Settings.sync();
						printerr("All settings reset.\n");
						did_reset = true;
				} else if(arg == "--no-system-models") {
						Environment.set_variable("RECOLLECT_NO_SYSTEM_MODELS", "1", true);
				} else {
						filtered_args += arg;
				}
		}
		if(did_reset) return 0;

		Intl.bindtextdomain(Config.APPLICATION_ID, Config.LOCALEDIR);
		Intl.bind_textdomain_codeset(Config.APPLICATION_ID, "UTF-8");
		Intl.textdomain(Config.APPLICATION_ID);

		// Load and register GResource from installed location
		var resource_path = Config.PKGDATADIR + "/" + Config.APPLICATION_ID + ".gresource";
		try {
				var resource = Resource.load(resource_path);
				resources_register(resource);
		} catch(Error e) {
				critical("Could not load GResource from %s: %s", resource_path, e.message);
		}

		return new Application().run(filtered_args);
}

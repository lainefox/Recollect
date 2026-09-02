// SettingsService wraps GSettings for type-safe access to configuration
public class SettingsService : Object {
		private Settings settings;

		public signal void folder_paths_changed();
		public signal void incremental_scan_changed();
		public signal void background_scan_changed();

		public SettingsService() {
				settings = new Settings("org.laine.Recollect");

				settings.changed["folders"].connect(() => {
						folder_paths_changed();
				});

				settings.changed["incremental-scan"].connect(() => {
						incremental_scan_changed();
				});

				settings.changed["background-scan"].connect(() => {
						background_scan_changed();
				});
		}

		// ── Folder management ──
		public string[] get_folders() {
				return settings.get_strv("folders");
		}

		public void set_folders(string[] folders) {
				settings.set_strv("folders", folders);
		}

		public void add_folder(string path) {
				var folders = get_folders();
				if(!(path in folders)) {
						folders += path;
						settings.set_strv("folders", folders);
				}
		}

		public void remove_folder(string path) {
				var folders = get_folders();
				var new_folders = new string[folders.length - 1];
				int j = 0;
				for(int i = 0; i < folders.length; i++) {
						if(folders[i] != path) {
								new_folders[j++] = folders[i];
						}
				}
				settings.set_strv("folders", new_folders);
		}

		// ── Scan settings ──
		public bool get_scan_on_startup() {
				return settings.get_boolean("scan-on-startup");
		}

		public void set_scan_on_startup(bool enabled) {
				settings.set_boolean("scan-on-startup", enabled);
		}

		public bool get_background_scan() {
				return settings.get_boolean("background-scan");
		}

		public void set_background_scan(bool enabled) {
				settings.set_boolean("background-scan", enabled);
		}

		public bool get_incremental_scan() {
				return settings.get_boolean("incremental-scan");
		}

		public void set_incremental_scan(bool enabled) {
				settings.set_boolean("incremental-scan", enabled);
		}

		// ── OCR settings ──
		public string get_ocr_accuracy() {
				return settings.get_string("ocr-accuracy");
		}

		public void set_ocr_accuracy(string level) {
				if(level in new string[] { "fast", "balanced", "best" }) {
						settings.set_string("ocr-accuracy", level);
				}
		}

		public string get_ocr_language() {
				return settings.get_string("ocr-language");
		}

		public void set_ocr_language(string language) {
				settings.set_string("ocr-language", language);
		}

// Return available languages from tesseract + user-downloaded models.
// Caches result in GSettings, but always re-checks the user directory
// so newly downloaded models appear without needing re-detection.
		public string[] get_available_languages() {
				var cached = settings.get_strv("available-languages");
				string[] languages = {};

				foreach(unowned string lang in cached) {
						string v = lang.make_valid(-1).strip();
						if(v.length > 0 && !v.contains(":") && !v.contains("/") && v.length <= 12) {
								languages += v;
						}
				}

				// If cache empty or we're suppressing system models, do full re-detection
				bool no_system_models =(Environment.get_variable("RECOLLECT_NO_SYSTEM_MODELS") == "1");
				bool needs_full_detection =(languages.length == 0
						||(languages.length == 1 && languages[0] == "eng")
						|| no_system_models);

				// Always scan user models directory and merge in new ones
				bool added_user_model = false;
				string models_dir = Path.build_filename(Environment.get_user_data_dir(), Config.APPLICATION_ID, "models");
				string[] variant_dirs = { "tessdata", "tessdata_fast", "tessdata_best" };
				foreach(unowned string sub in variant_dirs) {
						string dir_path = Path.build_filename(models_dir, sub);
						if(!FileUtils.test(dir_path, FileTest.IS_DIR)) continue;
						try {
								var dir = Dir.open(dir_path);
								string? name = null;
								while((name = dir.read_name()) != null) {
										if(!name.has_suffix(".traineddata")) continue;
										string code = name.substring(0, name.length - ".traineddata".length);
										if(code.length == 0) continue;
										bool already_known = false;
										foreach(unowned string known in languages) {
												if(known == code) {
														already_known = true;
														break;
												}
										}
										if(!already_known) {
												languages += code;
												added_user_model = true;
										}
								}
						} catch(FileError e) {
								warning("Failed to scan user models directory %s: %s", dir_path, e.message);
						}
				}

				if(needs_full_detection) {
						return detect_available_languages();
				}

				if(added_user_model || cached.length != languages.length) {
						settings.set_strv("available-languages", languages);
				}

				return languages;
		}

		private string[] detect_available_languages() {
				string[] languages = {};

				// Honour --no-system-models flag for testing (env var set by main())
				bool skip_system = Environment.get_variable("RECOLLECT_NO_SYSTEM_MODELS") == "1";

				if(!skip_system) {
						try {
								string output;
								int exit_code;

								Process.spawn_sync(
										null,
										{ "tesseract", "--list-langs" },
										null,
										SpawnFlags.SEARCH_PATH,
										null,
										out output,
										null,
										out exit_code
								);

								if(exit_code == 0) {
										bool first_line = true;
										foreach(unowned string lang in output.strip().split("\n")) {
												string valid_lang = lang.make_valid(-1).strip();
												if(first_line) {
														first_line = false;
														if(valid_lang.contains(":") || valid_lang.contains("/") || valid_lang.length > 12) {
																continue;
														}
												}
												if(valid_lang.length > 0 && !valid_lang.contains(":") && !valid_lang.contains("/")) {
														languages += valid_lang;
												}
										}
								}
						} catch(Error e) {
								warning("Failed to detect Tesseract languages: %s", e.message);
						}
				}

				// Merge in user-downloaded models from ~/.local/share/<app-id>/models/
				string models_dir = Path.build_filename(Environment.get_user_data_dir(), Config.APPLICATION_ID, "models");
				string[] variant_dirs = { "tessdata", "tessdata_fast", "tessdata_best" };
				foreach(unowned string sub in variant_dirs) {
						string dir_path = Path.build_filename(models_dir, sub);
						if(!FileUtils.test(dir_path, FileTest.IS_DIR)) continue;
						try {
								var dir = Dir.open(dir_path);
								string? name = null;
								while((name = dir.read_name()) != null) {
										if(name == "." || name == "..") continue;
										if(!name.has_suffix(".traineddata")) continue;
										string code = name.substring(0, name.length - ".traineddata".length);
										if(code.length == 0) continue;
										bool already_known = false;
										foreach(unowned string known in languages) {
												if(known == code) {
														already_known = true;
														break;
												}
										}
										if(!already_known) {
												languages += code;
										}
								}
						} catch(FileError e) {
								warning("Failed to scan user models directory %s: %s", dir_path, e.message);
						}
				}

				settings.set_strv("available-languages", languages);
				return languages;
		}

		// Force re-detection (ignores cache)
		public string[] refresh_available_languages() {
				settings.set_strv("available-languages", {});
				return detect_available_languages();
		}

		// ── UI preferences ──
		public string get_view_mode() {
				return settings.get_string("view-mode");
		}

		public void set_view_mode(string mode) {
				if(mode in new string[] { "list", "grid" }) {
						settings.set_string("view-mode", mode);
				}
		}

		public bool get_sidebar_visible() {
				return settings.get_boolean("sidebar-visible");
		}

		public void set_sidebar_visible(bool visible) {
				settings.set_boolean("sidebar-visible", visible);
		}

		// ── Onboarding ──
		public bool get_onboarding_completed() {
				return settings.get_boolean("onboarding-completed");
		}

		public void set_onboarding_completed(bool completed) {
				settings.set_boolean("onboarding-completed", completed);
		}

// Reset all GSettings to defaults and clear onboarding state
		public void reset_all() {
				settings.reset("folders");
				settings.reset("ocr-accuracy");
				settings.reset("ocr-language");
				settings.reset("available-languages");
				settings.reset("view-mode");
				settings.reset("last-scan-time");
				settings.reset("scan-on-startup");
				settings.reset("background-scan");
				settings.reset("incremental-scan");
				settings.reset("sidebar-visible");
				settings.reset("onboarding-completed");
				settings.reset("fuzzy-search");
				settings.reset("match-case");
				settings.reset("match-diacritics");
				settings.reset("whole-words");
				settings.reset("scan-hidden-folders");
		}

		public int64 get_last_scan_time() {
				return settings.get_int64("last-scan-time");
		}

		public void set_last_scan_time(int64 timestamp) {
				settings.set_int64("last-scan-time", timestamp);
		}

		// ── Search filter options ──
		public bool get_fuzzy_search() {
				return settings.get_boolean("fuzzy-search");
		}

		public void set_fuzzy_search(bool enabled) {
				settings.set_boolean("fuzzy-search", enabled);
		}

		public bool get_match_case() {
				return settings.get_boolean("match-case");
		}

		public void set_match_case(bool enabled) {
				settings.set_boolean("match-case", enabled);
		}

		public bool get_match_diacritics() {
				return settings.get_boolean("match-diacritics");
		}

		public void set_match_diacritics(bool enabled) {
				settings.set_boolean("match-diacritics", enabled);
		}

		public bool get_whole_words() {
				return settings.get_boolean("whole-words");
		}

		public void set_whole_words(bool enabled) {
				settings.set_boolean("whole-words", enabled);
		}

		public bool get_scan_hidden_folders() {
				return settings.get_boolean("scan-hidden-folders");
		}

		public void set_scan_hidden_folders(bool enabled) {
				settings.set_boolean("scan-hidden-folders", enabled);
		}

		// ── Update checking ──
		public bool get_check_for_updates() {
				return settings.get_boolean("check-for-updates");
		}

		public void set_check_for_updates(bool enabled) {
				settings.set_boolean("check-for-updates", enabled);
		}

		// ── Quality tier detection ──

// Find the tessdata directory by checking TESSDATA_PREFIX and common paths.
		private string find_tessdata_dir() {
				string? env_dir = Environment.get_variable("TESSDATA_PREFIX");
				if(env_dir != null && env_dir != "") {
						string dir = env_dir;
						if(!dir.has_suffix("/")) dir += "/";
						if(FileUtils.test(dir, FileTest.IS_DIR)) {
								return dir;
						}
				}

				// Check common installation paths
				string[] common_paths = {
						"/usr/share/tessdata/",
						"/usr/local/share/tessdata/",
						"/opt/homebrew/share/tessdata/",
						"/opt/tesseract/share/tessdata/"
				};

				foreach(string path in common_paths) {
						if(FileUtils.test(path, FileTest.IS_DIR)) {
								return path;
						}
				}

				return "";
		}

		private bool check_traineddata_exists(string dir_path, string lang_code) {
				if(dir_path == "") return false;
				string dir = dir_path;
				if(!dir.has_suffix("/")) dir += "/";
				return FileUtils.test(dir + lang_code + ".traineddata", FileTest.EXISTS);
		}

// Get available quality tiers for a given language code.
// Returns "fast", "balanced", and/or "best" depending on which
// traineddata files are installed for this language.
		public string[] get_language_quality_tiers(string lang_code) {
				string base_dir = find_tessdata_dir();
				string[] tiers = {};

				// Check user-downloaded models first (they take priority)
				string models_dir = Path.build_filename(Environment.get_user_data_dir(), Config.APPLICATION_ID, "models");
				string[] variant_names = { "fast", "balanced", "best" };
				string[] variant_subdirs = { "tessdata_fast", "tessdata", "tessdata_best" };
				for(int i = 0; i < variant_names.length; i++) {
						string path = Path.build_filename(models_dir, variant_subdirs[i], lang_code + ".traineddata");
						if(FileUtils.test(path, FileTest.EXISTS)) {
								tiers += variant_names[i];
						}
				}

				if(tiers.length > 0) {
						return tiers;
				}

				if(base_dir == "") {
						return { "balanced" };
				}

				// System variants: balanced (base tessdata) is always available
				tiers += "balanced";

				string base_stripped = base_dir;
				if(base_stripped.has_suffix("/"))
						base_stripped = base_stripped.substring(0, base_stripped.length - 1);

				string fast_dir = base_stripped + "_fast/";
				if(check_traineddata_exists(fast_dir, lang_code))
						tiers += "fast";

				string best_dir = base_stripped + "_best/";
				if(check_traineddata_exists(best_dir, lang_code))
						tiers += "best";

				return tiers;
		}

		// ── User model detection helpers ──

		private string get_user_models_dir() {
				return Path.build_filename(Environment.get_user_data_dir(), Config.APPLICATION_ID, "models");
		}

		public bool has_user_model(string code) {
				string models_dir = get_user_models_dir();
				string[] subdirs = new string[] { "tessdata", "tessdata_fast", "tessdata_best" };
				for(int i = 0; i < subdirs.length; i++) {
						string p = Path.build_filename(models_dir, subdirs[i], code + ".traineddata");
						if(FileUtils.test(p, FileTest.EXISTS))
								return true;
				}
				return false;
		}

		public string? get_user_model_variant(string code) {
				string models_dir = get_user_models_dir();
				string[] variants = new string[] { "fast", "balanced", "best" };
				string[] subdirs  = new string[] { "tessdata_fast", "tessdata", "tessdata_best" };
				for(int i = 0; i < variants.length; i++) {
						string p = Path.build_filename(models_dir, subdirs[i], code + ".traineddata");
						if(FileUtils.test(p, FileTest.EXISTS))
								return variants[i];
				}
				return null;
		}

		public bool is_system_model_installed(string code) {
				if(Environment.get_variable("RECOLLECT_NO_SYSTEM_MODELS") == "1") return false;
				string dir = find_tessdata_dir();
				return check_traineddata_exists(dir, code);
		}

// Delete a user-downloaded model. If the model was active and no system
// model remains for the code, removes it from the OCR language setting.
		public void delete_user_model(string code) {
				string models_dir = get_user_models_dir();
				string[] subdirs = new string[] { "tessdata", "tessdata_fast", "tessdata_best" };
				for(int i = 0; i < subdirs.length; i++) {
						string p = Path.build_filename(models_dir, subdirs[i], code + ".traineddata");
						if(FileUtils.test(p, FileTest.EXISTS)) {
								try {
										var file = File.new_for_path(p);
										file.delete();
								} catch(Error e) {
										warning("Failed to delete user model %s: %s", code, e.message);
								}
						}
				}

				refresh_available_languages();

				// If no system model provides this code, remove it from the active
				// OCR language setting so the app doesn't try to use a missing model.
				if(!is_system_model_installed(code)) {
						remove_code_from_ocr_language(code);
				}
		}

		private void remove_code_from_ocr_language(string code) {
				string current = get_ocr_language();
				string[] parts = current.split("+");
				string[] kept = {};
				bool changed = false;

				foreach(unowned string part in parts) {
						string trimmed = part.strip();
						if(trimmed.length == 0) continue;
						if(trimmed == code) {
								changed = true;
								continue;
						}
						kept += trimmed;
				}

				if(!changed) return;

				if(kept.length == 0) {
						set_ocr_language("eng");
				} else {
						set_ocr_language(string.joinv("+", kept));
				}
		}

// Returns true if any OCR model is available (system or user-downloaded).
		public bool has_any_model_available() {
				string[] langs = get_available_languages();
				return langs.length > 0;
		}

// Fast check: return cached languages without spawning tesseract.
// Safe to call during early construction. May return stale data
// if the cache was never populated (returns empty).
		public string[] get_available_languages_fast() {
				var cached = settings.get_strv("available-languages");
				string[] languages = {};
				foreach(unowned string lang in cached) {
						string v = lang.make_valid(-1).strip();
						if(v.length > 0 && !v.contains(":") && !v.contains("/") && v.length <= 12) {
								languages += v;
						}
				}
				return languages;
		}
}

// PreferencesDialog provides settings for folders, scanning, and OCR
public class PreferencesDialog : Adw.PreferencesDialog {
		private SettingsService settings;
		private ScannerService scanner;
		private DatabaseService database;
		private weak Gtk.Window parent_window;
		private weak Application app;

		// Folder page
		private Adw.PreferencesGroup folder_group;
		private Adw.PreferencesPage folder_page;
		private List<Adw.ActionRow> folder_rows = new List<Adw.ActionRow>();
		private uint folder_refresh_id = 0;

		// General page
		private Adw.PreferencesPage general_page;
		private Adw.SwitchRow background_scan_row;
		private Adw.SwitchRow incremental_scan_row;
		private Adw.SwitchRow hidden_folders_row;

		// OCR page
		private Adw.PreferencesPage ocr_page;
		private Adw.PreferencesGroup models_group;
		private List<Adw.ActionRow> model_rows = new List<Adw.ActionRow>();

		private bool ui_built = false;

		private void build_ui() {
				if(ui_built) return;
				ui_built = true;

				build_folder_page();
				build_general_page();
				build_ocr_page();

				// Set initial values from settings
				background_scan_row.active = settings.get_background_scan();
				incremental_scan_row.active = settings.get_incremental_scan();
				hidden_folders_row.active = settings.get_scan_hidden_folders();

				// Connect signals
				database.folders_changed.connect(() => {
						if(folder_refresh_id == 0) {
								folder_refresh_id = Idle.add(() => {
										folder_refresh_id = 0;
										populate_folder_list();
										return Source.REMOVE;
								});
						}
				});
				background_scan_row.notify["active"].connect(() => {
						settings.set_background_scan(background_scan_row.active);
				});
				incremental_scan_row.notify["active"].connect(() => {
						settings.set_incremental_scan(incremental_scan_row.active);
				});
				hidden_folders_row.notify["active"].connect(() => {
						settings.set_scan_hidden_folders(hidden_folders_row.active);
				});

				populate_folder_list();
		}

		public PreferencesDialog(SettingsService settings, ScannerService scanner, DatabaseService database, Gtk.Window parent_window, Application app) {
				Object();
				this.settings = settings;
				this.scanner = scanner;
				this.database = database;
				this.parent_window = parent_window;
				this.app = app;
				build_ui();
		}

// Navigate directly to the OCR page(used by the no-models toast button).
		public void show_ocr_page() {
				if(ocr_page != null) {
						set_visible_page(ocr_page);
				}
		}

		private void build_folder_page() {
				folder_page = new Adw.PreferencesPage();
				folder_page.icon_name = "folder-symbolic";
				folder_page.title = _("_Folders");
				folder_page.use_underline = true;

				var folder_group = new Adw.PreferencesGroup();
				folder_group.title = _("Scan Paths");

				this.folder_group = folder_group;

				populate_folder_list();

				// Add folder button — GNOME pattern: header suffix with flat button + Adw.ButtonContent
				var add_button = new Gtk.Button();
				var button_content = new Adw.ButtonContent();
				button_content.icon_name = "list-add-symbolic";
				button_content.label = _("Add Folder");
				add_button.child = button_content;
				add_button.add_css_class("flat");
				add_button.clicked.connect(on_add_folders);
				folder_group.set_header_suffix(add_button);

				// Hidden folders option belongs with folder configuration
				var hidden_folders_row = new Adw.SwitchRow();
				hidden_folders_row.title = _("Scan Hidden Folders");
				hidden_folders_row.subtitle = _("Include hidden(dot-prefixed) files and folders during scanning");
				this.hidden_folders_row = hidden_folders_row;

				var options_group = new Adw.PreferencesGroup();
				options_group.title = _("Options");
				options_group.add(hidden_folders_row);
				folder_page.add(folder_group);
				folder_page.add(options_group);

				add(folder_page);
		}

		private void populate_folder_list() {
				if(database == null || folder_group == null) return;

				// Remove all tracked folder rows from the group
				foreach(var row in folder_rows) {
						folder_group.remove(row);
				}
				folder_rows = new List<Adw.ActionRow>();

				uint count = database.get_all_folders_count();
				for(uint i = 0; i < count; i++) {
						Folder? folder = database.get_folder(i);
						if(folder == null) {
								continue;
						}

						var path =(!) folder.path;
						var row = create_folder_row(path);
						folder_rows.append(row);
						folder_group.add(row);
				}
		}

		private Adw.ActionRow create_folder_row(string folder_path) {
				var row = new Adw.ActionRow();
				row.title = folder_path.make_valid(-1);

				// Recursively count files and subfolders (like Nautilus).
				// Just reads directory entries — fast, no file I/O.
				uint file_count;
				uint folder_count;
				count_files_recursive(folder_path, out file_count, out folder_count);
				if(folder_count > 0) {
						row.subtitle = _("%u files, %u subfolders").printf(file_count, folder_count);
				} else if(file_count == 1) {
						row.subtitle = _("1 file");
				} else {
						row.subtitle = _("%u files").printf(file_count);
				}

				// Open folder button
				var open_btn = new Gtk.Button.from_icon_name("document-open-symbolic");
				open_btn.add_css_class("flat");
				open_btn.valign = Gtk.Align.CENTER;
				open_btn.tooltip_text = _("Open folder");
				var path_for_open = folder_path;
				open_btn.clicked.connect(() => {
						try {
								var file = File.new_for_path(path_for_open);
								AppInfo.launch_default_for_uri(file.get_uri(), null);
						} catch(Error e) {
								warning("Error opening folder: %s", e.message);
						}
				});
				row.add_suffix(open_btn);

				// Remove button(trash icon)
				var remove_btn = new Gtk.Button.from_icon_name("user-trash-symbolic");
				remove_btn.add_css_class("flat");
				remove_btn.valign = Gtk.Align.CENTER;
				remove_btn.tooltip_text = _("Remove folder");
				row.add_suffix(remove_btn);
				var path_for_delete = folder_path;
				remove_btn.clicked.connect(() => {
						// Disable both buttons so user can't interact during deletion
						open_btn.sensitive = false;
						remove_btn.sensitive = false;

						// Stop any ongoing scan for this folder before removing
						scanner.stop_scan();

						// Remove from GSettings(source of truth), then sync DB.
						// This deletes the folder row and all its images from the database.
						// The folders_changed signal is emitted, but the list refresh is
						// deferred via Idle.add so it happens after this click handler returns,
						// avoiding widget tree modification during event handling.
						settings.remove_folder(path_for_delete);
						database.sync_folders_from_settings(settings.get_folders());
				});

				return row;
		}

		private void on_add_folders() {
				var dialog = new Gtk.FileDialog();
				dialog.title = _("Select Folders to Scan");
				dialog.set_modal(true);

				dialog.select_folder.begin(parent_window, null,(obj, res) => {
						try {
								var file = dialog.select_folder.end(res);
								if(file == null) return;

								string path = file.get_path();
								if(path == null || path.length == 0) return;

								// Normalize path
								if(path.has_suffix("/") && path.length > 1) {
										path = path[0:path.length - 1];
								}

								// Check for duplicates and subfolder conflicts.
								// Since scanning includes subfolders, we reject paths that are
								// subfolders of(or parent folders of) already-added folders.
								string[] existing_paths = settings.get_folders();
								string? conflict_path = null;
								string? conflict_reason = null;

								foreach(string existing in existing_paths) {
										// Exact duplicate
										if(existing == path) {
												conflict_path = existing;
												conflict_reason = "already added";
												break;
										}
										// New path is a subfolder of an existing one
										string existing_with_sep = existing.has_suffix("/") ? existing : existing + "/";
										string path_with_sep = path.has_suffix("/") ? path : path + "/";
										if(path.has_prefix(existing_with_sep)) {
												conflict_path = existing;
												conflict_reason = _("a subfolder of %s which is already added").printf(existing);
												break;
										}
										// New path is a parent of an existing one
										if(existing.has_prefix(path_with_sep)) {
												conflict_path = existing;
												conflict_reason = _("a parent of %s which is already added").printf(existing);
												break;
										}
								}

								if(conflict_path != null) {
										string msg;
										if(conflict_reason == "already added") {
												msg = _("Folder already added: %s").printf(path);
										} else {
												msg = _("%s is %s").printf(path,(!) conflict_reason);
										}
										var toast = new Adw.Toast(msg);
										var window = app.main_window;
										if(window != null && window.toast_overlay != null) {
												window.toast_overlay.add_toast(toast);
										}
										return;
								}

								// Add to GSettings(source of truth), then sync DB
								settings.add_folder(path);
								database.sync_folders_from_settings(settings.get_folders());

								// If no scan is in progress, start scanning the new folder immediately
								if(!scanner.is_scanning()) {
										scanner.start_scan();
								}
								// Note: No explicit populate_folder_list() call here.
								// The folders_changed signal(emitted by sync_folders_from_settings) triggers
								// an Idle.add-queued refresh that will update the list.
						} catch(Error e) {
								// User cancelled
						}
				});
		}

		private void build_general_page() {
				general_page = new Adw.PreferencesPage();
				general_page.icon_name = "preferences-system-symbolic";
				general_page.title = _("_General");
				general_page.use_underline = true;

				var behavior_group = new Adw.PreferencesGroup();
				behavior_group.title = _("Behavior");

				background_scan_row = new Adw.SwitchRow();
				background_scan_row.title = _("Run in Background");
				background_scan_row.subtitle = _("Keep the app running and scanning when the window is closed");
				behavior_group.add(background_scan_row);

				incremental_scan_row = new Adw.SwitchRow();
				incremental_scan_row.title = _("Incremental Scanning");
				incremental_scan_row.subtitle = _("Monitor folders for file changes");
				behavior_group.add(incremental_scan_row);

				general_page.add(behavior_group);

				var actions_group = new Adw.PreferencesGroup();
				actions_group.title = _("Maintenance");
				var rescan_button = new Adw.ActionRow();
				rescan_button.title = _("Rescan All Folders");
				rescan_button.subtitle = _("Re-process all images in configured folders");

				var rescan_btn = new Gtk.Button.with_label(_("Rescan"));
				rescan_btn.valign = Gtk.Align.CENTER;
				rescan_btn.clicked.connect(() => {
						uint folder_count = database.get_all_folders_count();
						if(folder_count == 0) {
								var toast = new Adw.Toast(_("No folders configured"));
								var window = app.main_window;
								if(window != null && window.toast_overlay != null) {
										window.toast_overlay.add_toast(toast);
								}
								return;
						}

						scanner.stop_scan();
						// stop_scan() joins the background thread synchronously,
						// so calling start_scan immediately is safe — no delay needed.
						scanner.start_scan(true);  // force = true to re-process all files
						var toast = new Adw.Toast(_("Rescan started for %u folder(s)").printf(folder_count));
						var window = app.main_window;
						if(window != null && window.toast_overlay != null) {
								window.toast_overlay.add_toast(toast);
						}
				});
				rescan_button.add_suffix(rescan_btn);
				actions_group.add(rescan_button);

				// Clean up deleted files row
				var cleanup_row = new Adw.ActionRow();
				cleanup_row.title = _("Clean Up Deleted Files");
				cleanup_row.subtitle = _("Remove database entries for images that no longer exist on disk");

				var cleanup_btn = new Gtk.Button.with_label(_("Clean Up"));
				cleanup_btn.valign = Gtk.Align.CENTER;
				cleanup_btn.clicked.connect(() => {
						if(scanner.is_scanning() || scanner.is_cleanup_mode()) {
								var toast = new Adw.Toast(_("A scan or cleanup is already running"));
								var window = app.main_window;
								if(window != null && window.toast_overlay != null) {
										window.toast_overlay.add_toast(toast);
								}
								return;
						}

						scanner.start_cleanup();
						var toast = new Adw.Toast(_("Cleaning up deleted files…"));
						var window = app.main_window;
						if(window != null && window.toast_overlay != null) {
								window.toast_overlay.add_toast(toast);
						}
				});
				cleanup_row.add_suffix(cleanup_btn);
				actions_group.add(cleanup_row);

				// Purge database row(dev/testing)
				var purge_row = new Adw.ActionRow();
				purge_row.title = _("Purge Database");
				purge_row.subtitle = _("Delete all indexed images and folders");
				purge_row.add_css_class("destructive-action");

				var purge_btn = new Gtk.Button.with_label(_("Purge All Data"));
				purge_btn.add_css_class("destructive-action");
				purge_btn.valign = Gtk.Align.CENTER;
				purge_btn.clicked.connect(() => {
						var dialog = new Adw.AlertDialog(
								_("Purge All Data?"),
								_("This will permanently delete all indexed images and folders from the database. The image files on disk will not be affected.")
						);
						dialog.add_response("cancel", _("Cancel"));
						dialog.add_response("purge", _("Purge"));
						dialog.set_response_appearance("purge", Adw.ResponseAppearance.DESTRUCTIVE);
						dialog.set_default_response("cancel");
						dialog.response.connect((response) => {
								if(response == "purge") {
										// Stop any running scan first, then defer purge until scan is clean
										if(scanner.is_scanning()) {
												scanner.stop_scan();
										}
										// Defer purge to next idle cycle so scan cleanup completes
										GLib.Idle.add(() => {
												database.purge_database();
												settings.set_folders({});  // Clear GSettings too
												var toast = new Adw.Toast(_("Database purged — all entries removed"));
												var window = app.main_window;
												if(window != null && window.toast_overlay != null) {
														window.toast_overlay.add_toast(toast);
												}
												return GLib.Source.REMOVE;
										});
								}
						});
						dialog.present(parent_window);
				});
				purge_row.add_suffix(purge_btn);
				actions_group.add(purge_row);

				// Reset & start over row
				var reset_row = new Adw.ActionRow();
				reset_row.title = _("Reset and Start Over");
				reset_row.subtitle = _("Reset all settings and show the setup wizard on next launch");

				var reset_btn = new Gtk.Button.with_label(_("Reset"));
				reset_btn.add_css_class("destructive-action");
				reset_btn.valign = Gtk.Align.CENTER;
				reset_btn.clicked.connect(() => {
						// Confirm with a dialog
						var dialog = new Adw.AlertDialog(
								_("Reset All Settings?"),
								_("This will reset all preferences and show the onboarding wizard on the next launch. Your scanned data will not be deleted.")
						);
						dialog.add_response("cancel", _("Cancel"));
						dialog.add_response("reset", _("Reset"));
						dialog.set_response_appearance("reset", Adw.ResponseAppearance.DESTRUCTIVE);
						dialog.set_default_response("cancel");
						dialog.response.connect((response) => {
								if(response == "reset") {
										settings.reset_all();
										force_close();
										var app_instance = app;
										if(app_instance != null) {
												app_instance.quit();
										}
								}
						});
						dialog.present(parent_window);
				});
				reset_row.add_suffix(reset_btn);
				actions_group.add(reset_row);

				general_page.add(actions_group);

				add(general_page);
		}

		private void build_ocr_page() {
				ocr_page = new Adw.PreferencesPage();
				ocr_page.icon_name = "document-page-setup-symbolic";
				ocr_page.title = _("_OCR");
				ocr_page.use_underline = true;

				models_group = new Adw.PreferencesGroup();
				models_group.title = _("Models");


				// Download more models button — header suffix
				var download_btn = new Gtk.Button();
				var download_content = new Adw.ButtonContent();
				download_content.icon_name = "folder-download-symbolic";
				download_content.label = _("Download Models");
				download_btn.child = download_content;
				download_btn.add_css_class("flat");
				download_btn.clicked.connect(() => {
						var dialog = new DownloadModelsDialog(settings);
						dialog.model_changed.connect(() => {
								settings.refresh_available_languages();
								populate_models_list();
						});
						dialog.present(this);
				});
				models_group.set_header_suffix(download_btn);

				// Populate the list from installed languages
				populate_models_list();

				ocr_page.add(models_group);
				add(ocr_page);
		}

		private void populate_models_list() {
				if(models_group == null) return;

				// Always refresh from tesseract so newly installed models show up
				var langs = settings.refresh_available_languages();
				if(langs.length == 0) {
						langs = { "eng" };
				}

				// Parse the current setting into a set of active languages(separated by +)
				var active_set = new HashTable<string, string>(str_hash, str_equal);
				var active_str = settings.get_ocr_language();
				foreach(string code in active_str.split("+")) {
						string trimmed = code.strip();
						if(trimmed.length > 0) {
								active_set.set(trimmed, trimmed);
						}
				}

				// Remove all existing rows before repopulating
				foreach(var row in model_rows) {
						models_group.remove(row);
				}
				model_rows = new List<Adw.ActionRow>();

				foreach(unowned string lang in langs) {
						// Skip utility models that aren't OCR languages
						if(lang == "osd" || lang == "equ") continue;

						bool sys_avail = settings.is_system_model_installed(lang);
						bool user_avail = settings.has_user_model(lang);

						// System row
						if(sys_avail) {
								var row = create_model_row(lang, "system", null, active_set);
								models_group.add(row);
								model_rows.append(row);
						}

						// User row — shown even if system also exists(distinct entry).
						if(user_avail) {
								string? variant = settings.get_user_model_variant(lang);
								var row = create_model_row(lang, "user", variant, active_set);
								models_group.add(row);
								model_rows.append(row);
						}
				}
		}

// Create a single model row for |lang| with |source|("system"|"user").
// |variant| is the quality tier name if known.
		private Adw.ActionRow create_model_row(string lang, string source, string? variant, HashTable<string,string> active_set) {
				string display = get_language_display_name(lang);
				bool is_system =(source == "system");

				var row = new Adw.ActionRow();

				if(is_system) {
						row.title = display;
						// Build subtitle with language code and system quality tiers.
						var tiers = settings.get_language_quality_tiers(lang);
						string[] labels = {};
						foreach(unowned string t in tiers) {
								switch(t) {
										case "fast":   labels += _("Fast");     break;
										case "balanced":
										case "standard": labels += _("Balanced"); break;
										case "best":   labels += _("Best");     break;
										default:       labels += t;             break;
								}
						}
						row.subtitle = _("%s — %s").printf(lang, string.joinv(", ", labels));
				} else {
						row.title = display;
						row.subtitle = _("%s — %s").printf(lang,
								variant != null ? variant_display_name(variant) : "?");
				}

				// Badge(system) or delete button(user).
				if(is_system) {
						var badge = new Gtk.Label(_("System"));
						badge.add_css_class("caption");
						badge.add_css_class("dimmed");
						badge.valign = Gtk.Align.CENTER;
						badge.tooltip_text = _("Managed by your system's package manager or preinstalled with the system");
						row.add_suffix(badge);
				} else {
						var delete_btn = new Gtk.Button() {
								icon_name = "user-trash-symbolic",
								tooltip_text = _("Delete this downloaded model"),
								valign = Gtk.Align.CENTER
						};
						delete_btn.add_css_class("flat");
						delete_btn.add_css_class("destructive-action");
						delete_btn.clicked.connect(() => {
								settings.delete_user_model(lang);
								populate_models_list();
						});
						row.add_suffix(delete_btn);
				}

				// Checkbox — initially active if the language is in the active set.
				// When both system and user models exist for the same code, only the
				// user model is active(the one the user explicitly chose to install).
				bool active;
				if(is_system && settings.has_user_model(lang)) {
						active = false;  // user model takes priority
				} else {
						active = active_set.contains(lang);
				}
				var check = new Gtk.CheckButton();
				check.add_css_class("selection-mode");
				check.valign = Gtk.Align.CENTER;
				check.active = active;
				row.add_prefix(check);
				row.activatable_widget = check;

				// Store metadata on the row so the toggled handler can do mutual exclusion.
				row.set_data_full("lang-code",(void*) lang.dup(), g_free);
				row.set_data_full("source",(void*) source.dup(), g_free);

				// Toggle handler
				check.toggled.connect(() => {
						if(!check.active) {
								// Let the normal collection below handle the update.
						} else {
								// Mutual exclusion: de-select the opposite source for this code.
								string code = lang;
								string src = source;
								foreach(var r in model_rows) {
										if(r == row) continue;
										string? other_code = r.get_data<string?>("lang-code");
										string? other_src  = r.get_data<string?>("source");
										if(other_code == code && other_src != src) {
												var cb = r.activatable_widget as Gtk.CheckButton;
												if(cb != null) cb.active = false;
										}
								}
						}

						// Collect all currently checked codes.
						string[] active_langs = {};
						foreach(var r in model_rows) {
								var cb = r.activatable_widget as Gtk.CheckButton;
								if(cb != null && cb.active) {
										unowned string? row_code = r.get_data<string?>("lang-code");
										if(row_code != null) {
												active_langs += row_code;
										}
								}
						}
						if(active_langs.length == 0) {
								check.active = true;
								return;
						}
						settings.set_ocr_language(string.joinv("+", active_langs));
				});

				return row;
		}

		private static string variant_display_name(string variant) {
				switch(variant) {
						case "fast":     return _("Fast");
						case "best":     return _("Best");
						case "balanced":
						default:         return _("Balanced");
				}
		}

// Convert a language code to a human-readable name
		public static string get_language_display_name(string code) {
				var lang_codes = new HashTable<string, string>(str_hash, str_equal);
				lang_codes.set("afr", "Afrikaans");
				lang_codes.set("amh", "Amharic");
				lang_codes.set("ara", "Arabic");
				lang_codes.set("asm", "Assamese");
				lang_codes.set("aze", "Azerbaijani");
				lang_codes.set("aze_cyrl", "Azerbaijani(Cyrillic)");
				lang_codes.set("bel", "Belarusian");
				lang_codes.set("ben", "Bengali");
				lang_codes.set("bod", "Tibetan");
				lang_codes.set("bos", "Bosnian");
				lang_codes.set("bre", "Breton");
				lang_codes.set("bul", "Bulgarian");
				lang_codes.set("cat", "Catalan");
				lang_codes.set("ceb", "Cebuano");
				lang_codes.set("ces", "Czech");
				lang_codes.set("chi_sim", "Chinese Simplified");
				lang_codes.set("chi_sim_vert", "Chinese Simplified(vertical)");
				lang_codes.set("chi_tra", "Chinese Traditional");
				lang_codes.set("chi_tra_vert", "Chinese Traditional(vertical)");
				lang_codes.set("chr", "Cherokee");
				lang_codes.set("cos", "Corsican");
				lang_codes.set("cym", "Welsh");
				lang_codes.set("dan", "Danish");
				lang_codes.set("dan_frak", "Danish(Fraktur)");
				lang_codes.set("deu", "German");
				lang_codes.set("deu_frak", "German(Fraktur)");
				lang_codes.set("deu_latf", "German(Latin Fraktur)");
				lang_codes.set("div", "Divehi");
				lang_codes.set("dzo", "Dzongkha");
				lang_codes.set("ell", "Greek");
				lang_codes.set("eng", "English");
				lang_codes.set("enm", "English(Middle)");
				lang_codes.set("epo", "Esperanto");
				lang_codes.set("equ", "Math / Equations");
				lang_codes.set("est", "Estonian");
				lang_codes.set("eus", "Basque");
				lang_codes.set("fao", "Faroese");
				lang_codes.set("fas", "Persian");
				lang_codes.set("fil", "Filipino");
				lang_codes.set("fin", "Finnish");
				lang_codes.set("fra", "French");
				lang_codes.set("frk", "German Fraktur(deprecated)");
				lang_codes.set("frm", "French(Middle)");
				lang_codes.set("fry", "Frisian");
				lang_codes.set("gla", "Scottish Gaelic");
				lang_codes.set("gle", "Irish");
				lang_codes.set("glg", "Galician");
				lang_codes.set("grc", "Greek(Ancient)");
				lang_codes.set("guj", "Gujarati");
				lang_codes.set("hat", "Haitian");
				lang_codes.set("heb", "Hebrew");
				lang_codes.set("hin", "Hindi");
				lang_codes.set("hrv", "Croatian");
				lang_codes.set("hun", "Hungarian");
				lang_codes.set("hye", "Armenian");
				lang_codes.set("iku", "Inuktitut");
				lang_codes.set("ind", "Indonesian");
				lang_codes.set("isl", "Icelandic");
				lang_codes.set("ita", "Italian");
				lang_codes.set("ita_old", "Italian(Old)");
				lang_codes.set("jav", "Javanese");
				lang_codes.set("jpn", "Japanese");
				lang_codes.set("jpn_vert", "Japanese(vertical)");
				lang_codes.set("kan", "Kannada");
				lang_codes.set("kat", "Georgian");
				lang_codes.set("kat_old", "Georgian(Old)");
				lang_codes.set("kaz", "Kazakh");
				lang_codes.set("khm", "Khmer");
				lang_codes.set("kir", "Kyrgyz");
				lang_codes.set("kmr", "Kurmanji");
				lang_codes.set("kor", "Korean");
				lang_codes.set("kor_vert", "Korean(vertical)");
				lang_codes.set("lao", "Lao");
				lang_codes.set("lat", "Latin");
				lang_codes.set("lav", "Latvian");
				lang_codes.set("lit", "Lithuanian");
				lang_codes.set("ltz", "Luxembourgish");
				lang_codes.set("mal", "Malayalam");
				lang_codes.set("mar", "Marathi");
				lang_codes.set("mkd", "Macedonian");
				lang_codes.set("mlt", "Maltese");
				lang_codes.set("mon", "Mongolian");
				lang_codes.set("mri", "Maori");
				lang_codes.set("msa", "Malay");
				lang_codes.set("mya", "Burmese");
				lang_codes.set("nep", "Nepali");
				lang_codes.set("nld", "Dutch");
				lang_codes.set("nor", "Norwegian");
				lang_codes.set("oci", "Occitan");
				lang_codes.set("ori", "Oriya");
				lang_codes.set("osd", "Orientation and Script Detection");
				lang_codes.set("pan", "Punjabi");
				lang_codes.set("pol", "Polish");
				lang_codes.set("por", "Portuguese");
				lang_codes.set("pus", "Pashto");
				lang_codes.set("que", "Quechua");
				lang_codes.set("ron", "Romanian");
				lang_codes.set("rus", "Russian");
				lang_codes.set("san", "Sanskrit");
				lang_codes.set("sin", "Sinhala");
				lang_codes.set("slk", "Slovak");
				lang_codes.set("slk_frak", "Slovak(Fraktur)");
				lang_codes.set("slv", "Slovenian");
				lang_codes.set("snd", "Sindhi");
				lang_codes.set("spa", "Spanish");
				lang_codes.set("spa_old", "Spanish(Old)");
				lang_codes.set("sqi", "Albanian");
				lang_codes.set("srp", "Serbian");
				lang_codes.set("srp_latn", "Serbian(Latin)");
				lang_codes.set("sun", "Sundanese");
				lang_codes.set("swa", "Swahili");
				lang_codes.set("swe", "Swedish");
				lang_codes.set("syr", "Syriac");
				lang_codes.set("tam", "Tamil");
				lang_codes.set("tat", "Tatar");
				lang_codes.set("tel", "Telugu");
				lang_codes.set("tgk", "Tajik");
				lang_codes.set("tgl", "Tagalog");
				lang_codes.set("tha", "Thai");
				lang_codes.set("tir", "Tigrinya");
				lang_codes.set("ton", "Tonga");
				lang_codes.set("tur", "Turkish");
				lang_codes.set("uig", "Uyghur");
				lang_codes.set("ukr", "Ukrainian");
				lang_codes.set("urd", "Urdu");
				lang_codes.set("uzb", "Uzbek");
				lang_codes.set("uzb_cyrl", "Uzbek(Cyrillic)");
				lang_codes.set("vie", "Vietnamese");
				lang_codes.set("yid", "Yiddish");
				lang_codes.set("yor", "Yoruba");

				// Script models
				lang_codes.set("script/Latin", "Latin Script");
				lang_codes.set("script/Cyrillic", "Cyrillic Script");
				lang_codes.set("script/Arabic", "Arabic Script");
				lang_codes.set("script/Devanagari", "Devanagari Script");
				lang_codes.set("script/Fraktur", "Fraktur Script");
				lang_codes.set("script/HanS", "Han Simplified Script");
				lang_codes.set("script/HanT", "Han Traditional Script");
				lang_codes.set("script/Hangul", "Hangul Script");
				lang_codes.set("script/Hebrew", "Hebrew Script");
				lang_codes.set("script/Japanese", "Japanese Script");
				lang_codes.set("script/Greek", "Greek Script");
				lang_codes.set("script/Thai", "Thai Script");
				lang_codes.set("script/Armenian", "Armenian Script");
				lang_codes.set("script/Georgian", "Georgian Script");
				lang_codes.set("script/Ethiopic", "Ethiopic Script");
				lang_codes.set("script/Bengali", "Bengali Script");
				lang_codes.set("script/Gujarati", "Gujarati Script");
				lang_codes.set("script/Gurmukhi", "Gurmukhi Script");
				lang_codes.set("script/Kannada", "Kannada Script");
				lang_codes.set("script/Khmer", "Khmer Script");
				lang_codes.set("script/Lao", "Lao Script");
				lang_codes.set("script/Malayalam", "Malayalam Script");
				lang_codes.set("script/Myanmar", "Myanmar Script");
				lang_codes.set("script/Oriya", "Oriya Script");
				lang_codes.set("script/Sinhala", "Sinhala Script");
				lang_codes.set("script/Syriac", "Syriac Script");
				lang_codes.set("script/Tamil", "Tamil Script");
				lang_codes.set("script/Telugu", "Telugu Script");
				lang_codes.set("script/Thaana", "Thaana Script");
				lang_codes.set("script/Tibetan", "Tibetan Script");
				lang_codes.set("script/Vietnamese", "Vietnamese Script");
				lang_codes.set("script/Canadian_Aboriginal", "Canadian Aboriginal Script");
				lang_codes.set("script/Cherokee", "Cherokee Script");

				var display_name = lang_codes.get(code);
				if(display_name != null) {
						return display_name;
				}
				return code;
		}

// Supported file extensions(must match ScannerService)
		private const string[] SUPPORTED_EXTENSIONS = {
				"png", "jpg", "jpeg", "tiff", "tif", "bmp", "webp", "gif",
				"avif", "heic", "heif", "jxl", "svg"
		};

// Check if a filename has a supported file extension
		private bool is_supported_file(string name) {
				string name_down = name.down();
				foreach(string ext in SUPPORTED_EXTENSIONS) {
						if(name_down.has_suffix(".%s".printf(ext))) {
								return true;
						}
				}
				return false;
		}

// Count files and subfolders recursively in a directory.
// Uses GFile.enumerate_children which only reads directory entries(fast,
// like Nautilus) — no file I/O or content inspection needed.
// Respects the "scan hidden folders" setting.
		private void count_files_recursive(string dir_path, out uint file_count, out uint folder_count) {
				file_count = 0;
				folder_count = 0;
				bool show_hidden = settings.get_scan_hidden_folders();
				try {
						var dir = File.new_for_path(dir_path);
						if(!dir.query_exists()) return;

						var enumerator = dir.enumerate_children(
								"standard::type,standard::name,standard::is-hidden",
								FileQueryInfoFlags.NONE
						);
						FileInfo? info;
						while((info = enumerator.next_file()) != null) {
								// Skip hidden entries unless setting is enabled
								if(!show_hidden && info.get_attribute_boolean("standard::is-hidden")) continue;

								if(info.get_file_type() == FileType.DIRECTORY) {
										folder_count++;
										uint child_files, child_folders;
										string child_path = Path.build_filename(dir_path, info.get_name());
										count_files_recursive(child_path, out child_files, out child_folders);
										file_count += child_files;
										folder_count += child_folders;
								} else if(info.get_file_type() == FileType.REGULAR) {
										if(is_supported_file(info.get_name())) {
												file_count++;
										}
								}
						}
				} catch(Error e) {
						warning("Error counting files in %s: %s", dir_path, e.message);
				}
		}
}

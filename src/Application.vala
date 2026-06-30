public class Application : Adw.Application {
		private SettingsService settings_service;
		private DatabaseService database_service;
		private OcrService ocr_service;
		private ScannerService scanner_service;
		private ThumbnailService thumbnail_service;
		public MainWindow? main_window;

		public Application() {
				Object(
						application_id: Config.APPLICATION_ID,
						flags: ApplicationFlags.HANDLES_OPEN
				);
		}

		protected override void startup() {
				base.startup();

				settings_service = new SettingsService();
				database_service = new DatabaseService();
				ocr_service = new OcrService();
				scanner_service = new ScannerService(database_service, ocr_service, settings_service);
				thumbnail_service = new ThumbnailService();

				database_service.init_sync();

				// Sync folder database with GSettings (source of truth for folder paths)
				database_service.sync_folders_from_settings(settings_service.get_folders());

				// Start incremental file monitoring if enabled, but only after
				// onboarding is complete so we don't pick up files mid-setup.
				if(settings_service.get_incremental_scan() && settings_service.get_onboarding_completed()) {
						scanner_service.start_monitoring();
				}

				// Keep DB in sync when GSettings folders change externally (e.g., via CLI).
				// During onboarding, only sync the DB — don't start monitors or scans.
				settings_service.folder_paths_changed.connect(() => {
						database_service.sync_folders_from_settings(settings_service.get_folders());
						if(!settings_service.get_onboarding_completed()) return;
						if(settings_service.get_incremental_scan()) {
								scanner_service.restart_monitoring();
						}
						// If a scan is running, queue a rescan so new folders are picked up
						// without requiring an app restart.
						scanner_service.request_rescan();
				});

				settings_service.incremental_scan_changed.connect(() => {
						if(settings_service.get_incremental_scan()) {
								scanner_service.start_monitoring();
						} else {
								scanner_service.stop_monitoring();
						}
				});

				// If background scanning is enabled, keep the process alive so scanning
				// continues even when no window is visible.
				if(settings_service.get_background_scan()) {
						hold();
				}

				// Start scanning on startup if configured, but only after onboarding
				// is complete. This ensures we don't scan while the user is still
				// setting up folders on their first launch.
				bool startup_scan = settings_service.get_scan_on_startup();
				bool onboarding_done = settings_service.get_onboarding_completed();
				if(startup_scan && onboarding_done) {
						maybe_start_scan();
				}

				settings_service.background_scan_changed.connect(() => {
						if(settings_service.get_background_scan()) {
								hold();
								if(settings_service.get_incremental_scan()) {
										scanner_service.start_monitoring();
								}
						} else {
								release();
						}
				});

				// Defer deduplication to after window is shown so it doesn't block startup
				set_resource_base_path("/org/laine/Recollect");

				var icon_theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
				icon_theme.add_resource_path("/org/laine/Recollect/icons");

				var css_provider = new Gtk.CssProvider();
				css_provider.load_from_resource("/org/laine/Recollect/style.css");
				var display = Gdk.Display.get_default();
				if(display != null) {
						Gtk.StyleContext.add_provider_for_display(display, css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
				}

				var quit_action = new SimpleAction("quit", null);
				quit_action.activate.connect(() => action_quit());
				add_action(quit_action);
				set_accels_for_action("app.quit", {"<Control>q"});

				var about_action = new SimpleAction("about", null);
				about_action.activate.connect(() => action_about());
				add_action(about_action);

				var preferences_action = new SimpleAction("preferences", null);
				preferences_action.activate.connect(() => action_preferences());
				add_action(preferences_action);
				set_accels_for_action("app.preferences", {"<Control>comma"});

				var open_ocr_settings_action = new SimpleAction("open-ocr-settings", null);
				open_ocr_settings_action.activate.connect(() => action_open_ocr_settings());
				add_action(open_ocr_settings_action);

				var focus_search_action = new SimpleAction("focus-search", null);
				focus_search_action.activate.connect(() => action_focus_search());
				add_action(focus_search_action);
				set_accels_for_action("app.focus-search", {"<Control>l", "<Control>f"});

				var rescan_action = new SimpleAction("rescan", null);
				rescan_action.activate.connect(() => action_rescan());
				add_action(rescan_action);
				set_accels_for_action("app.rescan", {"<Control>r", "F5"});

				var view_list_action = new SimpleAction("switch-to-list", null);
				view_list_action.activate.connect(() => action_switch_to_list());
				add_action(view_list_action);
				set_accels_for_action("app.switch-to-list", {"<Control>1"});

				var view_grid_action = new SimpleAction("switch-to-grid", null);
				view_grid_action.activate.connect(() => action_switch_to_grid());
				add_action(view_grid_action);
				set_accels_for_action("app.switch-to-grid", {"<Control>2"});

				var shortcuts_action = new SimpleAction("shortcuts", null);
				shortcuts_action.activate.connect(() => action_shortcuts());
				add_action(shortcuts_action);
				set_accels_for_action("app.shortcuts", {"<Control>question"});

				var clear_search_action = new SimpleAction("clear-search", null);
				clear_search_action.activate.connect(() => action_clear_search());
				add_action(clear_search_action);
				set_accels_for_action("app.clear-search", {"<Control>BackSpace"});

				var focus_preview_action = new SimpleAction("focus-preview", null);
				focus_preview_action.activate.connect(() => action_focus_preview());
				add_action(focus_preview_action);
				set_accels_for_action("app.focus-preview", {"<Control>e"});

				var close_preview_action = new SimpleAction("close-preview", null);
				close_preview_action.activate.connect(() => action_close_preview());
				add_action(close_preview_action);
				set_accels_for_action("app.close-preview", {"<Control>w"});

				var open_filter_action = new SimpleAction("open-filter-popover", null);
				open_filter_action.activate.connect(() => action_open_filter_popover());
				add_action(open_filter_action);
				set_accels_for_action("app.open-filter-popover", {"<Control>d", "<Control><Shift>f"});

				var open_file_action = new SimpleAction("open-file", null);
				open_file_action.activate.connect(() => action_open_file());
				add_action(open_file_action);
				set_accels_for_action("app.open-file", {"<Control>Return", "<Control>KP_Enter"});
		}

		protected override void activate() {
				base.activate();

				var window = get_active_window();
				if(window == null) {
						window = new MainWindow(this, database_service, scanner_service, settings_service, thumbnail_service);
						main_window =(MainWindow) window;
						main_window.init_signals();
						window.present();

						// Defer housekeeping so it doesn't block startup
						Idle.add(() => {
								database_service.deduplicate_folders();
								return Source.REMOVE;
						});

						// Sync UI if background scanning already started in startup()
						if(scanner_service.is_scanning()) {
								main_window.set_scanning(true);
						}

						if(!settings_service.get_onboarding_completed()) {
								var wizard = new OnboardingDialog(settings_service, database_service, scanner_service, this, main_window);
								wizard.onboarding_completed.connect(() => {
										// Start file monitoring now that onboarding is done
										if(settings_service.get_incremental_scan()) {
												scanner_service.start_monitoring();
										}
										uint folder_count = database_service.get_all_folders_count();
										if(folder_count > 0) {
												scanner_service.start_scan();
										}
								});
								wizard.present(main_window);
						} else {
								// Always schedule a scan when the window appears —
								// start_scan() skips already-indexed files via
								// known_paths, so this completes instantly if
								// everything is already scanned. Otherwise it
								// resumes any interrupted scan from last session.
								Idle.add(() => {
										if(main_window == null) return Source.REMOVE;
										uint final_folder_count = database_service.get_all_folders_count();
										if(final_folder_count > 0) {
												scanner_service.start_scan();
										}
										return Source.REMOVE;
								});
						}
				} else {
						// Single-instance: bring existing window to front.
						// If hidden (background mode), refresh state to show latest results.
						if(main_window != null) {
								main_window.refresh_state();
						}
						window.present();
				}
		}

// Action: Quit
		private void action_quit() {
				quit();
		}

// Action: Show About dialog
		private void action_about() {
				var about = new Adw.AboutDialog();
				about.set_application_name(_("Recollect"));
				about.set_version(Config.VERSION);
				about.set_application_icon(Config.APPLICATION_ID);
				about.set_copyright("© 2026 Laine");
				about.set_license_type(Gtk.License.GPL_3_0);
				about.set_comments(_("Search for text inside your images with powerful OCR technology"));
				about.set_website("https://github.com/laine/recollect");
				about.set_issue_url("https://github.com/laine/recollect/issues");
				about.present(get_active_window());
		}

// Action: Show Preferences dialog
		private void action_preferences() {
				var prefs = new PreferencesDialog(settings_service, scanner_service, database_service, main_window, this);
				prefs.present(main_window);
		}

// Action: Show Preferences dialog with OCR page selected
		private void action_open_ocr_settings() {
				var prefs = new PreferencesDialog(settings_service, scanner_service, database_service, main_window, this);
				prefs.show_ocr_page();
				prefs.present(main_window);
		}

// Action: Focus the search bar
		private void action_focus_search() {
				if(main_window != null) {
						main_window.focus_search();
				}
		}

// Action: Start a rescan
		private void action_rescan() {
				uint folder_count = database_service.get_all_folders_count();
				if(folder_count > 0 && !scanner_service.is_scanning()) {
						scanner_service.start_scan();
				}
		}

// Action: Switch to list view
		private void action_switch_to_list() {
				if(main_window != null) {
						main_window.switch_to_view("list");
				}
		}

// Action: Switch to grid view
		private void action_switch_to_grid() {
				if(main_window != null) {
						main_window.switch_to_view("grid");
				}
		}

// Action: Show keyboard shortcuts window
		private void action_shortcuts() {
				try {
						var builder = new Gtk.Builder.from_resource("/org/laine/Recollect/shortcuts-dialog.ui");
						var window =(Gtk.ShortcutsWindow) builder.get_object("shortcuts");
						window.set_transient_for(get_active_window());
						window.present();
				} catch(Error e) {
						warning("Failed to load shortcuts window: %s", e.message);
				}
		}

// Action: Clear the search bar and show all results
		private void action_clear_search() {
				if(main_window != null) {
						main_window.clear_search();
				}
		}

// Action: Open the filter popover
		private void action_open_filter_popover() {
				if(main_window != null) {
						main_window.open_filter_popover();
				}
		}

// Action: Focus the preview sidebar (OCR text area)
		private void action_focus_preview() {
				if(main_window != null) {
						main_window.focus_preview();
				}
		}

// Action: Close the preview sidebar
		private void action_close_preview() {
				if(main_window != null) {
						main_window.close_preview_sidebar();
				}
		}

// Action: Open the currently selected image in the default application
		private void action_open_file() {
				if(main_window != null) {
						main_window.open_current_file();
				}
		}

// Start a scan if folders are configured.
// Safe to call multiple times — ScannerService guards against re-entry.
		private void maybe_start_scan() {
				uint folder_count = database_service.get_all_folders_count();
				if(folder_count > 0) {
						scanner_service.start_scan();
				}
		}
}

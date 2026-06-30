// DownloadModelsDialog — modal dialog for browsing downloadable Tesseract models.
// Uses TesseractModelService for data/network operations, only handles presentation.
public class DownloadModelsDialog : Adw.Dialog {
		private SettingsService settings;
		private TesseractModelService service;

		// UI
		private Adw.ViewStack view_stack;
		private Gtk.Stack state_stack;
		private Adw.StatusPage error_page;
		private Adw.PreferencesGroup language_group;
		private Adw.PreferencesGroup script_group;
		private Gtk.SearchEntry language_search_entry;
		private Gtk.SearchEntry script_search_entry;
		private Gtk.SearchBar search_bar;
		private bool language_search_active = false;
		private bool script_search_active = false;

		// Stored model arrays for filtering.
		private GenericArray<TesseractModel> language_models = new GenericArray<TesseractModel>();
		private GenericArray<TesseractModel> script_models = new GenericArray<TesseractModel>();

		// Per-model widget references for in-place updates.
		private HashTable<string, ModelRowWidgets> model_widgets = new HashTable<string, ModelRowWidgets>(str_hash, str_equal);

		private const string[] VARIANT_ORDER = { "fast", "balanced", "best" };

// Emitted when a model is successfully downloaded or deleted.
		public signal void model_changed();

		public DownloadModelsDialog(SettingsService settings) {
				Object(title: _("Download Models"));
				this.settings = settings;
				this.service = new TesseractModelService();
				connect_service_signals();
				build_ui();
				service.load_models();
		}

		private void connect_service_signals() {
				service.models_loaded.connect(on_models_loaded);
				service.load_failed.connect(on_load_failed);
				service.download_started.connect(on_download_started);
				service.download_progress.connect(on_download_progress);
				service.download_completed.connect(on_download_completed);
				service.download_failed.connect(on_download_failed);
				service.model_deleted.connect(on_model_deleted);
		}

		private void build_ui() {
				content_width = 620;
				content_height = 520;

				language_group = create_preferences_group();
				language_group.description = _(
						"Language models contain OCR data for specific languages (e.g. English, French, Arabic). " +
						"Each language model already includes its writing system.\n\n" +
						"PS: You do not need to also install the matching script model (e.g. Latin) — " +
						"the language model already covers it."
				);

				script_group = create_preferences_group();
				script_group.description = _(
						"Script models contain OCR data for writing systems or alphabets (e.g. Latin, Cyrillic, Arabic). " +
						"They are useful when multiple languages share the same script, or when no language-specific " +
						"model is available. Script models generally have lower accuracy than language-specific models because they " +
						"must handle many languages at once.\n\n" +
						"PS: If you already have a language model (e.g. English), you do not need its script model (e.g. Latin Script)."
				);

				language_search_entry = new Gtk.SearchEntry() {
						placeholder_text = _("Search languages…"),
				};

				script_search_entry = new Gtk.SearchEntry() {
						placeholder_text = _("Search scripts…"),
				};

				language_search_entry.search_changed.connect(() => {
						filter_and_rebuild_group(language_group, language_models, language_search_entry.text);
				});
				script_search_entry.search_changed.connect(() => {
						filter_and_rebuild_group(script_group, script_models, script_search_entry.text);
				});

				view_stack = new Adw.ViewStack();

				var search_button = new Gtk.ToggleButton() {
						icon_name = "edit-find-symbolic",
						tooltip_text = _("Search")
				};

				search_bar = new Gtk.SearchBar() {
						key_capture_widget = this,
						search_mode_enabled = false,
						child = language_search_entry
				};
				search_button.bind_property(
						"active",
						search_bar,
						"search-mode-enabled",
						BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE
				);

				var header = new Adw.HeaderBar() {
						show_end_title_buttons = true,
						title_widget = new Adw.ViewSwitcher() {
								stack = view_stack,
								policy = Adw.ViewSwitcherPolicy.NARROW
						}
				};
				header.pack_start(search_button);

				view_stack.add_titled_with_icon(
						create_tab_widget(language_group),
						"languages",
						_("Languages"),
						"language-symbolic"
				);
				view_stack.add_titled_with_icon(
						create_tab_widget(script_group),
						"scripts",
						_("Scripts"),
						"text-insert-symbolic"
				);

				view_stack.notify["visible-child-name"].connect(on_visible_tab_changed);

				var loading_spinner = new Adw.Spinner() {
						halign = Gtk.Align.CENTER
				};

				var loading_title = new Gtk.Label(_("Fetching Models")) {
						halign = Gtk.Align.CENTER,
						justify = Gtk.Justification.CENTER,
						wrap = true,
						max_width_chars = 50
				};
				loading_title.add_css_class("title-2");

				var loading_desc = new Gtk.Label(
						_("Downloading the list of available models from GitHub…")
				) {
						halign = Gtk.Align.CENTER,
						justify = Gtk.Justification.CENTER,
						wrap = true,
						max_width_chars = 50
				};
				loading_desc.add_css_class("body");

				var loading_page = new Gtk.Box(Gtk.Orientation.VERTICAL, 16) {
						valign = Gtk.Align.CENTER,
						halign = Gtk.Align.CENTER,
						vexpand = true
				};
				loading_page.append(loading_spinner);
				loading_page.append(loading_title);
				loading_page.append(loading_desc);

				var offline_page = new Adw.StatusPage() {
						title = _("No Internet Connection"),
						description = _("Connect to the internet to browse available models."),
						icon_name = "network-offline-symbolic",
						vexpand = true
				};

				var retry_button = new Gtk.Button.with_label(_("Retry"));
				retry_button.halign = Gtk.Align.CENTER;
				retry_button.add_css_class("suggested-action");
				retry_button.add_css_class("pill");
				retry_button.clicked.connect(() => service.load_models());

				error_page = new Adw.StatusPage() {
						title = _("Could Not Load Models"),
						icon_name = "network-error-symbolic",
						child = retry_button,
						vexpand = true
				};

				state_stack = new Gtk.Stack() {
						transition_type = Gtk.StackTransitionType.CROSSFADE,
						vexpand = true
				};
				state_stack.add_named(loading_page, "loading");
				state_stack.add_named(offline_page, "offline");
				state_stack.add_named(error_page, "error");
				state_stack.add_named(view_stack, "content");

				var toolbar_view = new Adw.ToolbarView();
				toolbar_view.add_top_bar(header);
				toolbar_view.add_top_bar(search_bar);
				toolbar_view.set_content(state_stack);
				set_child(toolbar_view);

				show_state("loading");
		}

		private Adw.PreferencesGroup create_preferences_group() {
				return new Adw.PreferencesGroup();
		}

		private Adw.PreferencesPage create_preferences_page(Adw.PreferencesGroup group) {
				var page = new Adw.PreferencesPage();
				page.add(group);
				return page;
		}

		private Gtk.Widget create_tab_widget(Adw.PreferencesGroup group) {
				var scrolled = new Gtk.ScrolledWindow() {
						child = create_preferences_page(group),
						vexpand = true
				};
				return scrolled;
		}

		private void on_visible_tab_changed() {
				if(search_bar.child == language_search_entry) {
						language_search_active = search_bar.search_mode_enabled;
				} else {
						script_search_active = search_bar.search_mode_enabled;
				}

				if(view_stack.visible_child_name == "languages") {
						search_bar.child = language_search_entry;
						search_bar.search_mode_enabled = language_search_active;
				} else {
						search_bar.child = script_search_entry;
						search_bar.search_mode_enabled = script_search_active;
				}
		}

		private void filter_and_rebuild_group(Adw.PreferencesGroup group, GenericArray<TesseractModel> models, string text) {
				string filter = text.strip().down();

				// Clear all rows.
				clear_group(group);

				if(models.length == 0) {
						var row = new Adw.ActionRow() {
								title = _("No models available"),
								subtitle = _("The model list could not be fetched."),
								sensitive = false
						};
						group.add(row);
						return;
				}

				for(uint i = 0; i < models.length; i++) {
						var model = models.get(i);
						bool matches =(filter == ""
								|| model.display_name.down().contains(filter)
								|| model.code.down().contains(filter));
						if(matches) {
								group.add(create_model_expander_row(model));
						}
				}
		}

		private void show_state(string name) {
				state_stack.visible_child_name = name;
		}

		private void on_models_loaded(GenericArray<TesseractModel> lang_models, GenericArray<TesseractModel> scr_models) {
				this.language_models = lang_models;
				this.script_models = scr_models;

				model_widgets.remove_all();
				// Re-build group with filtering if search text is active.
				filter_and_rebuild_group(language_group, language_models, language_search_entry.text);
				filter_and_rebuild_group(script_group, script_models, script_search_entry.text);
				show_state("content");
		}

		private void on_load_failed(string error) {
				show_error(error);
		}

		private void on_download_started(string code, string variant_name) {
				set_variant_state(code, variant_name, VariantState.DOWNLOADING);
		}

		private void on_download_progress(string code, string variant_name, double progress) {
				// Spinner is indeterminate; progress percentage is not displayed.
		}

		private void on_download_completed(string code, string variant_name) {
				TesseractModel? model = service.find_model(code);
				if(model != null) {
						model.installed_variant = variant_name;
				}
				set_variant_state(code, variant_name, VariantState.INSTALLED);
				refresh_variant_states(code);
				model_changed();
		}

		private void on_download_failed(string code, string variant_name, string error) {
				TesseractModel? model = service.find_model(code);
				bool is_installed = model != null && model.installed_variant == variant_name;
				set_variant_state(code, variant_name, is_installed ? VariantState.INSTALLED : VariantState.DOWNLOADABLE);
				show_error(error);
		}

		private void on_model_deleted(string code) {
				TesseractModel? model = service.find_model(code);
				if(model != null) {
						model.installed_variant = null;
				}
				refresh_variant_states(code);
				model_changed();
		}



		private Adw.ExpanderRow create_model_expander_row(TesseractModel model) {
				var expander = new Adw.ExpanderRow() {
						title = model.display_name,
						subtitle = model.code
				};

				var widgets = new ModelRowWidgets(expander);
				model_widgets.insert(model.code, widgets);

				foreach(string variant_name in VARIANT_ORDER) {
						TesseractModelVariant? variant = service.find_variant(model, variant_name);
						if(variant == null) continue;

						bool is_installed = model.installed_variant == variant_name;
						var variant_row = create_variant_row(model, variant_name, variant.size, is_installed);
						expander.add_row(variant_row);
				}

				return expander;
		}

		private Adw.ActionRow create_variant_row(TesseractModel model, string variant_name, int64 size, bool is_installed) {
				var row = new Adw.ActionRow() {
						title = variant_display_name(variant_name)
				};

				var size_label = new Gtk.Label(format_size(size)) {
						valign = Gtk.Align.CENTER
				};
				size_label.add_css_class("caption");
				size_label.add_css_class("dim-label");
				row.add_suffix(size_label);

				var download_button = new Gtk.Button() {
						icon_name = "folder-download-symbolic",
						tooltip_text = _("Download %s model").printf(variant_display_name(variant_name)),
						valign = Gtk.Align.CENTER
				};
				download_button.add_css_class("flat");
				download_button.clicked.connect(() => service.download_model(model.code, variant_name));

				var spinner = new Adw.Spinner() {
						width_request = 16,
						height_request = 16,
						valign = Gtk.Align.CENTER
				};

				var checkmark = new Gtk.Image.from_icon_name("check-round-outline-symbolic") {
						valign = Gtk.Align.CENTER
				};

				var status_stack = new Gtk.Stack() {
						valign = Gtk.Align.CENTER,
						transition_type = Gtk.StackTransitionType.NONE
				};
				status_stack.add_named(download_button, "downloadable");
				status_stack.add_named(spinner, "downloading");
				status_stack.add_named(checkmark, "installed");

				row.add_suffix(status_stack);

				ModelRowWidgets? widgets = model_widgets.lookup(model.code);
				if(widgets != null) {
						widgets.variant_widgets.insert(variant_name, new VariantWidgets(status_stack));
				}

				update_status_stack(status_stack, is_installed ? VariantState.INSTALLED : VariantState.DOWNLOADABLE);

				return row;
		}

		private void set_variant_state(string code, string variant_name, VariantState state) {
				ModelRowWidgets? widgets = model_widgets.lookup(code);
				if(widgets == null) return;

				VariantWidgets? variant_widgets = widgets.variant_widgets.lookup(variant_name);
				if(variant_widgets == null) return;

				update_status_stack(variant_widgets.status_stack, state);
		}

		private void update_status_stack(Gtk.Stack status_stack, VariantState state) {
				switch(state) {
						case VariantState.DOWNLOADABLE:
								status_stack.visible_child_name = "downloadable";
								break;
						case VariantState.DOWNLOADING:
								status_stack.visible_child_name = "downloading";
								break;
						case VariantState.INSTALLED:
								status_stack.visible_child_name = "installed";
								break;
				}
		}

		private void refresh_variant_states(string code) {
				TesseractModel? model = service.find_model(code);
				if(model == null) return;

				ModelRowWidgets? widgets = model_widgets.lookup(code);
				if(widgets == null) return;

				foreach(string variant_name in VARIANT_ORDER) {
						if(!widgets.variant_widgets.contains(variant_name)) continue;

						bool is_installed = model.installed_variant == variant_name;
						set_variant_state(code, variant_name, is_installed ? VariantState.INSTALLED : VariantState.DOWNLOADABLE);
				}
		}

		private enum VariantState {
				DOWNLOADABLE,
				DOWNLOADING,
				INSTALLED
		}

		private string variant_display_name(string variant_name) {
				switch(variant_name) {
						case "fast": return _("Fast");
						case "best": return _("Best");
						case "balanced":
						default: return _("Balanced");
				}
		}

		private void clear_group(Adw.PreferencesGroup group) {
				// Use get_row() to reliably iterate rows managed by the group.
				while(true) {
						var row = group.get_row(0);
						if(row == null) break;
						group.remove(row);
				}
		}

		private void show_error(string message) {
				error_page.description = Markup.escape_text(message);
				show_state("error");
		}

		private static string format_size(int64 bytes) {
				if(bytes < 1024) return _("%.0f B").printf((double) bytes);
				if(bytes < 1024 * 1024) return _("%.1f KB").printf(bytes / 1024.0);
				if(bytes < 1024 * 1024 * 1024) return _("%.1f MB").printf(bytes /(1024.0 * 1024.0));
				return _("%.1f GB").printf(bytes /(1024.0 * 1024.0 * 1024.0));
		}

		private class ModelRowWidgets : Object {
				public Adw.ExpanderRow expander_row { get; construct; }
				public HashTable<string, VariantWidgets> variant_widgets { get; construct; }

				public ModelRowWidgets(Adw.ExpanderRow expander_row) {
						Object(
								expander_row: expander_row,
								variant_widgets: new HashTable<string, VariantWidgets>(str_hash, str_equal)
						);
				}
		}

		private class VariantWidgets : Object {
				public Gtk.Stack status_stack { get; construct; }

				public VariantWidgets(Gtk.Stack status_stack) {
						Object(status_stack: status_stack);
				}
		}
}

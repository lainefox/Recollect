// OnboardingDialog is a multi-page modal shown on first launch
// Pages: Welcome → [Models (if needed)] → Choose Folders
public class OnboardingDialog : Adw.Dialog {
		private SettingsService settings;
		private DatabaseService database;
		private ScannerService scanner;
		private Application app;
		private TesseractModelService model_service;

		private Adw.Carousel carousel;
		private Gtk.Button next_button;
		private Gtk.Button back_button;
		private Gtk.Button skip_button;

		private int current_page = 0;
		private int page_count = 2;

		// Page indices
		private int model_page_index = -1;
		private int folder_page_index = 1;

		// Folder page
		private Adw.PreferencesGroup folder_group;
		private List<Adw.ActionRow> folder_rows = new List<Adw.ActionRow>();
		private weak Gtk.Window parent_window;

		// Model page
		private Gtk.Button model_download_button;
		private Gtk.Spinner model_download_spinner;
		private Gtk.Button model_error_button;
		private enum ModelDownloadState { LOADING, READY, DOWNLOADING, SUCCESS, ERROR }
		private ModelDownloadState model_dl_state = ModelDownloadState.LOADING;
		private string model_error_message = "";
		private bool model_page_initialized = false;
		private bool disposed = false;

		public signal void onboarding_completed();

		public OnboardingDialog(SettingsService settings, DatabaseService database, ScannerService scanner, Application app, Gtk.Window parent_window) {
				Object(title: _("Welcome to Recollect"));
				this.settings = settings;
				this.database = database;
				this.scanner = scanner;
				this.app = app;
				this.parent_window = parent_window;
				this.model_service = new TesseractModelService();
				determine_pages();
				build_ui();
		}

		private bool ui_built = false;
		private bool folder_page_initialized = false;

		private void build_ui() {
				if(ui_built) return;
				ui_built = true;

				content_width = 520;
				content_height = 500;
				can_close = false;

				var toolbar_view = new Adw.ToolbarView();
				toolbar_view.hexpand = true;
				toolbar_view.vexpand = true;

				// Header bar with back button(left) and skip button(right)
				// No window controls — user must use Skip or Get Started
				// ToolbarView automatically gives the header bar a flat appearance
				// when used as a top bar, so no .flat style class is needed.
				var header = new Adw.HeaderBar();
				header.show_start_title_buttons = false;
				header.show_end_title_buttons = false;

				back_button = new Gtk.Button.with_label(_("Back"));
				back_button.add_css_class("flat");
				back_button.visible = false;
				back_button.clicked.connect(() => {
						carousel.scroll_to(carousel.get_nth_page(current_page - 1), true);
				});
				header.pack_start(back_button);

				skip_button = new Gtk.Button.with_label(_("Skip"));
				skip_button.add_css_class("flat");
				skip_button.clicked.connect(() => {
						// Clear any folders that were auto-detected during onboarding
						settings.set_folders({});
						database.sync_folders_from_settings(settings.get_folders());
						settings.set_onboarding_completed(true);
						onboarding_completed();
						force_close();
				});
				header.pack_end(skip_button);

				toolbar_view.add_top_bar(header);

				// Carousel for pages
				carousel = new Adw.Carousel();
				carousel.hexpand = true;
				carousel.vexpand = true;
				carousel.allow_scroll_wheel = false;
				carousel.allow_mouse_drag = false;
				carousel.allow_long_swipes = false;

				carousel.page_changed.connect((index) => {
						current_page =(int) index;
						update_buttons();
						// Initialize model page on first visit
						if(current_page == model_page_index && !model_page_initialized) {
								model_page_initialized = true;
								model_service.load_models();
						}
						// Initialize folder page on first visit — auto-detect Screenshots
						if(current_page == folder_page_index && !folder_page_initialized) {
								folder_page_initialized = true;
								auto_detect_screenshots();
								populate_folder_list();
						}
				});

				// Page 1: Welcome
				carousel.append(build_welcome_page());

				// Page 2(conditional): Download Models
				if(model_page_index >= 0) {
						carousel.append(build_model_page());
				}

				// Page N: Choose Folders
				carousel.append(build_folder_page());

				// Bottom navigation — buttons stacked in a fixed-height container
				// so switching between download button / spinner / error doesn't shift content.
				bottom_stack = new Gtk.Stack();
				bottom_stack.set_halign(Gtk.Align.CENTER);
				bottom_stack.set_margin_start(24);
				bottom_stack.set_margin_end(24);
				bottom_stack.set_margin_bottom(24);
				bottom_stack.vhomogeneous = true;

				next_button = new Gtk.Button.with_label(_("Next"));
				next_button.add_css_class("pill");
				next_button.add_css_class("suggested-action");
				next_button.clicked.connect(() => {
						if(current_page < page_count - 1) {
								carousel.scroll_to(carousel.get_nth_page(current_page + 1), true);
						}
				});
				bottom_stack.add_named(next_button, "next");

				model_download_button = new Gtk.Button.with_label(_("Loading…"));
				model_download_button.add_css_class("pill");
				model_download_button.add_css_class("suggested-action");
				model_download_button.sensitive = false;
				model_download_button.clicked.connect(on_download_eng_model);
				bottom_stack.add_named(model_download_button, "model-dl");

				model_download_spinner = new Gtk.Spinner();
				model_download_spinner.set_halign(Gtk.Align.CENTER);
				model_download_spinner.set_valign(Gtk.Align.CENTER);
				bottom_stack.add_named(model_download_spinner, "spinner");

				model_error_button = new Gtk.Button.with_label(_("Network Error"));
				model_error_button.add_css_class("pill");
				model_error_button.sensitive = false;
				model_error_button.clicked.connect(() => {
						carousel.scroll_to(carousel.get_nth_page(current_page + 1), true);
				});
				bottom_stack.add_named(model_error_button, "error");

				var get_started_button = new Gtk.Button.with_label(_("Get Started"));
				get_started_button.add_css_class("pill");
				get_started_button.add_css_class("suggested-action");
				get_started_button.clicked.connect(() => {
						settings.set_onboarding_completed(true);
						onboarding_completed();
						force_close();
				});
				bottom_stack.add_named(get_started_button, "started");

				// Indicator dots
				var indicator = new Adw.CarouselIndicatorDots();
				indicator.carousel = carousel;
				indicator.margin_bottom = 16;

				// Wrap the carousel, bottom stack, and indicator in a content box
				// for ToolbarView's content area.
				var content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
				content_box.hexpand = true;
				content_box.vexpand = true;
				content_box.append(carousel);
				content_box.append(bottom_stack);
				content_box.append(indicator);
				toolbar_view.set_content(content_box);

				child = toolbar_view;

				// Don't populate folders yet — GSettings starts empty.
				// Auto-detect only when user navigates to the folder page.

				// Listen for folder changes so the list stays in sync
				database.folders_changed.connect(() => {
						if(folder_refresh_id == 0) {
								folder_refresh_id = Idle.add(() => {
										folder_refresh_id = 0;
										populate_folder_list();
										return Source.REMOVE;
								});
						}
				});

				// Prevent signal handlers from touching destroyed widgets
				closed.connect(() => {
						disposed = true;
				});

				update_buttons();
		}

		private uint folder_refresh_id = 0;
		private Gtk.Stack bottom_stack;

// Check whether OCR models are available and configure page layout.
		private void determine_pages() {
				// Use cached check only(no process spawn) to avoid corruption
				// during early construction.
				bool no_system =(Environment.get_variable("RECOLLECT_NO_SYSTEM_MODELS") == "1");
				string[] cached = settings.get_available_languages_fast();
				if(cached.length == 0 || no_system) {
						page_count = 3;
						model_page_index = 1;
						folder_page_index = 2;
				}
				// else: page_count stays 2, model_page_index stays -1, folder_page_index stays 1
		}

		private Gtk.Widget build_model_page() {
				var page_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 16);
				page_box.set_margin_start(32);
				page_box.set_margin_end(32);
				page_box.set_margin_top(24);
				page_box.set_margin_bottom(24);
				page_box.hexpand = true;
				page_box.vexpand = true;
				page_box.set_valign(Gtk.Align.CENTER);

				var icon = new Gtk.Image.from_icon_name("document-page-setup-symbolic");
				icon.pixel_size = 64;
				icon.set_halign(Gtk.Align.CENTER);
				page_box.append(icon);

				var title = new Gtk.Label(_("<span size=\"large\" weight=\"bold\">OCR Language Models</span>"));
				title.use_markup = true;
				title.set_halign(Gtk.Align.CENTER);
				page_box.append(title);

				var desc = new Gtk.Label(_("Recollect needs language models to read text from your images. Without at least one model installed, scanning will not work.\n\nYou can download the English model now — it only takes a moment. More languages can be added later in Settings."));
				desc.wrap = true;
				desc.set_halign(Gtk.Align.CENTER);
				desc.add_css_class("dimmed");
				page_box.append(desc);

				connect_model_service_signals();

				return page_box;
		}

		private void connect_model_service_signals() {
				model_service.models_loaded.connect(() => {
						if(disposed) return;
						model_dl_state = ModelDownloadState.READY;
						update_buttons();
				});
				model_service.load_failed.connect((error) => {
						if(disposed) return;
						model_dl_state = ModelDownloadState.ERROR;
						model_error_message = error;
						update_buttons();
				});
				model_service.download_completed.connect((code, variant) => {
						if(disposed) return;
						if(code == "eng") {
								model_dl_state = ModelDownloadState.SUCCESS;
								settings.refresh_available_languages();
								update_buttons();
						}
				});
				model_service.download_failed.connect((code, variant, error) => {
						if(disposed) return;
						if(code == "eng") {
								model_dl_state = ModelDownloadState.ERROR;
								model_error_message = error;
								update_buttons();
						}
				});
		}

		private void on_download_eng_model() {
				model_dl_state = ModelDownloadState.DOWNLOADING;
				update_buttons();
				model_service.download_model("eng", "balanced");
		}

		private Gtk.Widget build_welcome_page() {
				var status = new Adw.StatusPage();
				status.icon_name = Config.APPLICATION_ID;
				status.title = _("Welcome to Recollect");
				status.description = _("Ever spent ages looking for a screenshot you know you saved? Pick some folders and I'll make every bit of text in your images searchable.");
				status.set_vexpand(true);
				return status;
		}

		private Gtk.Widget build_folder_page() {
				var page_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
				page_box.set_margin_start(24);
				page_box.set_margin_end(24);
				page_box.set_margin_top(12);
				page_box.set_margin_bottom(12);
				page_box.hexpand = true;

				var title_label = new Gtk.Label(_("<span size=\"large\" weight=\"bold\">Choose folders to scan</span>"));
				title_label.use_markup = true;
				title_label.set_halign(Gtk.Align.CENTER);
				page_box.append(title_label);

				var subtitle_label = new Gtk.Label(_("Select the folders that contain images you want to search through."));
				subtitle_label.add_css_class("dimmed");
				subtitle_label.wrap = true;
				subtitle_label.set_halign(Gtk.Align.CENTER);
				page_box.append(subtitle_label);

				// Folder group — same pattern as PreferencesDialog
				folder_group = new Adw.PreferencesGroup();
				folder_group.title = _("Scan Paths");

				// Add folder button — header suffix with Adw.ButtonContent(GNOME pattern)
				var add_button = new Gtk.Button();
				var button_content = new Adw.ButtonContent();
				button_content.icon_name = "list-add-symbolic";
				button_content.label = _("Add Folder");
				add_button.child = button_content;
				add_button.add_css_class("flat");
				add_button.clicked.connect(on_add_folder);
				folder_group.set_header_suffix(add_button);

				page_box.append(folder_group);

				return page_box;
		}

// Same folder row creation as PreferencesDialog — with file counts, open, and remove buttons
		private Adw.ActionRow create_folder_row(string folder_path) {
				var row = new Adw.ActionRow();
				row.title = folder_path.make_valid(-1);

				// Recursively count files and subfolders
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

				// Remove button
				var remove_btn = new Gtk.Button.from_icon_name("user-trash-symbolic");
				remove_btn.add_css_class("flat");
				remove_btn.valign = Gtk.Align.CENTER;
				remove_btn.tooltip_text = _("Remove folder");
				row.add_suffix(remove_btn);
				var path_for_delete = folder_path;
				remove_btn.clicked.connect(() => {
						open_btn.sensitive = false;
						remove_btn.sensitive = false;

						scanner.stop_scan();
						settings.remove_folder(path_for_delete);
						database.sync_folders_from_settings(settings.get_folders());
				});

				return row;
		}

		private void populate_folder_list() {
				if(database == null || folder_group == null) return;

				// Remove all tracked folder rows
				foreach(var row in folder_rows) {
						folder_group.remove(row);
				}
				folder_rows = new List<Adw.ActionRow>();

				uint count = database.get_all_folders_count();
				for(uint i = 0; i < count; i++) {
						Folder? folder = database.get_folder(i);
						if(folder == null) continue;

						var path =(!) folder.path;
						var row = create_folder_row(path);
						folder_rows.append(row);
						folder_group.add(row);
				}
		}

		private void on_add_folder() {
				var dialog = new Gtk.FileDialog();
				dialog.title = _("Select Folder to Scan");
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

								// Check for duplicates and subfolder conflicts(same as PreferencesDialog)
								string[] existing_paths = settings.get_folders();
								string? conflict_path = null;
								string? conflict_reason = null;

								foreach(string existing in existing_paths) {
										if(existing == path) {
												conflict_path = existing;
												conflict_reason = "already added";
												break;
										}
										string existing_with_sep = existing.has_suffix("/") ? existing : existing + "/";
										string path_with_sep = path.has_suffix("/") ? path : path + "/";
										if(path.has_prefix(existing_with_sep)) {
												conflict_path = existing;
												conflict_reason = "a subfolder of %s which is already added".printf(existing);
												break;
										}
										if(existing.has_prefix(path_with_sep)) {
												conflict_path = existing;
												conflict_reason = "a parent of %s which is already added".printf(existing);
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
										// OnboardingDialog is an Adw.Dialog, we need the parent window for toasts
										var window = app.main_window;
										if(window != null && window.toast_overlay != null) {
												window.toast_overlay.add_toast(toast);
										}
										return;
								}

								// Add to GSettings(source of truth), then sync DB
								settings.add_folder(path);
								database.sync_folders_from_settings(settings.get_folders());
								// Scanning starts after onboarding completes(in Application.vala)
						} catch(Error e) {
								// User cancelled
						}
				});
		}

		private void auto_detect_screenshots() {
				string pictures_dir = Environment.get_user_special_dir(UserDirectory.PICTURES);
				if(pictures_dir != null) {
						string screenshots_dir = Path.build_filename(pictures_dir, "Screenshots");
						if(File.new_for_path(screenshots_dir).query_exists()) {
								string[] existing = settings.get_folders();
								if(!(screenshots_dir in existing)) {
										settings.add_folder(screenshots_dir);
										database.sync_folders_from_settings(settings.get_folders());
								}
						}
				}
		}

		private void update_buttons() {
				back_button.visible = current_page > 0;
				skip_button.visible = true;

				if(current_page == model_page_index) {
						// On the model page: replace Next with download/spinner/error
						switch(model_dl_state) {
								case ModelDownloadState.LOADING:
										model_download_button.label = _("Loading…");
										model_download_button.sensitive = false;
										bottom_stack.set_visible_child_name("model-dl");
										break;
								case ModelDownloadState.READY:
										model_download_button.label = _("Download English Model");
										model_download_button.sensitive = true;
										bottom_stack.set_visible_child_name("model-dl");
										break;
								case ModelDownloadState.DOWNLOADING:
										model_download_spinner.start();
										bottom_stack.set_visible_child_name("spinner");
										break;
								case ModelDownloadState.SUCCESS:
										bottom_stack.set_visible_child_name("next");
										break;
								case ModelDownloadState.ERROR:
										model_error_button.label = _("Network Error(%s)").printf(model_error_message);
										bottom_stack.set_visible_child_name("error");
										break;
						}
				} else if(current_page == page_count - 1) {
						bottom_stack.set_visible_child_name("started");
				} else {
						bottom_stack.set_visible_child_name("next");
				}
		}

// Supported file extensions(must match ScannerService)
		private const string[] SUPPORTED_EXTENSIONS = {
				"png", "jpg", "jpeg", "tiff", "tif", "bmp", "webp", "gif",
				"avif", "heic", "heif", "jxl", "svg"
		};

		private bool is_supported_file(string name) {
				string name_down = name.down();
				foreach(string ext in SUPPORTED_EXTENSIONS) {
						if(name_down.has_suffix(".%s".printf(ext))) {
								return true;
						}
				}
				return false;
		}

// Count files and subfolders recursively — same logic as PreferencesDialog
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
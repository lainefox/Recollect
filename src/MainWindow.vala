public class MainWindow : Adw.ApplicationWindow {
		public DatabaseService database { get; construct set; }
		public ScannerService scanner { get; construct set; }
		public SettingsService settings { get; construct set; }
		public ThumbnailService thumbnail_service { get; construct set; }
		
		private Gtk.SearchEntry search_entry;
		private Gtk.Button filter_button;
		private FilterPopover filter_popover;
		private Gtk.Stack stack;
		private Gtk.Widget? results_page;
		private Gtk.Stack view_stack;
		public Adw.ToastOverlay toast_overlay;
		
		private ResultsListView? list_view = null;
		private ResultsGridView? grid_view = null;
		private ImagePreviewSidebar? preview_sidebar = null;
		private Gtk.Button preview_close_btn;
		private Gtk.Stack sidebar_stack;
		private Adw.OverlaySplitView split_view;



		private ProgressPie scan_pie;
		private Gtk.Button pie_click;
		private double scan_progress_fraction = 0.0;
		private bool scanning = false;
		private bool scan_paused = false;
		private ScanPopover scan_popover;
		private Gtk.Label scan_sublabel;

		// Throttle progress display to at most once per 1000ms
		private int latest_current = 0;
		private int latest_total = 0;
		private uint progress_display_id = 0;

		private uint search_timeout_id = 0;

		// Batch scan entries to avoid flooding GTK during rapid inserts
		private List<ImageEntry> pending_scan_entries;
		private uint scan_flush_id = 0;
		private const int SCAN_FLUSH_BATCH = 20;

		// Guard to prevent callbacks from touching widgets during teardown
		private bool disposing = false;

		// Tracks whether hide_preview_sidebar() is the one changing show_sidebar
		// vs. an external swipe/click-away on mobile. Lets the notify handler
		// distinguish programmatic hides from user-initiated ones.
		private bool hiding_sidebar = false;

		private ImageEntry? current_selected_entry = null;

		// View toggle(list/grid)
		private Adw.ToggleGroup view_toggle;

		// Sort state
		private SortCriteria current_sort_criteria = SortCriteria.DATE;
		private SortDirection current_sort_direction = SortDirection.DESCENDING;
		private string current_search_query = "";
		private bool current_match_case = false;
		private bool current_whole_words = false;
		private Gtk.MenuButton sort_button;

		// Date filter state (synced from FilterPopover)
		private int64 current_date_from = 0;
		private int64 current_date_to = 0;

		public MainWindow(Gtk.Application app, DatabaseService db, ScannerService scan, SettingsService set, ThumbnailService thumbs) {
				Object(application: app, database: db, scanner: scan, settings: set, thumbnail_service: thumbs);
		}

		construct {
				default_width = 900;
				default_height = 600;
				title = _("Recollect");

				preview_sidebar = new ImagePreviewSidebar(thumbnail_service);
				preview_sidebar.set_database(database);
				preview_sidebar.hexpand = false;
				preview_sidebar.vexpand = true;
				preview_sidebar.valign = Gtk.Align.FILL;

				list_view = new ResultsListView(database, thumbnail_service);
				list_view.hexpand = true;
				list_view.vexpand = true;

				grid_view = new ResultsGridView(database, thumbnail_service);
				grid_view.hexpand = true;
				grid_view.vexpand = true;

				scan_pie = new ProgressPie(24);
				scan_pie.visible = false;

				pie_click = new Gtk.Button();
				pie_click.set_child(scan_pie);
				pie_click.add_css_class("flat");
				pie_click.visible = false;
				set_widget_accessible_description(pie_click, _("Show scan progress and folder details"));

				scan_popover = new ScanPopover();
				scan_popover.set_parent(pie_click);
				scan_popover.stop_folder.connect((path) => {
						scanner.cancel_folder(path);
				});

				search_entry = new Gtk.SearchEntry();
				search_entry.placeholder_text = _("Search images…");
				search_entry.search_changed.connect(on_search_changed);
				search_entry.hexpand = true;
				set_widget_accessible_description(search_entry, _("Type to search for text extracted from your images"));

				// Filter button overlaid inside the search entry (Nautilus-style)
				filter_button = new Gtk.Button.from_icon_name("funnel-symbolic");
				filter_button.add_css_class("flat");
				filter_button.add_css_class("circular");
				filter_button.add_css_class("search-filter-btn");
				filter_button.tooltip_text = _("Search filters");
				set_widget_accessible_description(filter_button, _("Filter search results by case, diacritics, whole words, or date range"));
				// Overlay the filter button inside the SearchEntry (like Nautilus)
				filter_button.halign = Gtk.Align.END;
				filter_button.valign = Gtk.Align.CENTER;

				filter_popover = new FilterPopover(settings);
				filter_popover.set_parent(filter_button);
				filter_popover.filters_changed.connect(() => {
						refilter_current_results();
				});

				filter_button.clicked.connect(() => {
						if(filter_popover.get_visible()) {
								filter_popover.popdown();
						} else {
								filter_popover.popup();
						}
				});

				// Move the funnel button right of the X icon when text is present,
				// or flush to the right edge when the entry is empty (no X icon).
				search_entry.notify["text"].connect(update_filter_button_position);
				// Set initial position
				update_filter_button_position();

				var search_overlay = new Gtk.Overlay();
				search_overlay.child = search_entry;
				search_overlay.add_overlay(filter_button);

				search_entry.add_css_class("search-with-filter");

				sort_button = new Gtk.MenuButton();
				sort_button.icon_name = "view-sort-descending-symbolic";
				sort_button.tooltip_text = _("Sort results");
				sort_button.add_css_class("flat");
				set_widget_accessible_description(sort_button, _("Change sort order by name or date, ascending or descending"));

				var sort_popover = new SortPopover();
				sort_button.set_popover(sort_popover);
				sort_popover.changed.connect((criteria, direction) => {
						current_sort_criteria = criteria;
						current_sort_direction = direction;
						sort_button.icon_name = direction == SortDirection.DESCENDING
								? "view-sort-descending-symbolic"
								: "view-sort-ascending-symbolic";
						apply_sort();
				});

				var menu_button = new Gtk.MenuButton();
				menu_button.icon_name = "open-menu-symbolic";

				var menu = new GLib.Menu();
				menu.append(_("Preferences"), "app.preferences");
				menu.append(_("Keyboard Shortcuts"), "app.shortcuts");
				menu.append(_("About"), "app.about");
				menu.append_section(null, new GLib.Menu());
				menu.append(_("Quit"), "app.quit");
				menu_button.menu_model = menu;

				view_toggle = new Adw.ToggleGroup();
				view_toggle.orientation = Gtk.Orientation.HORIZONTAL;

				var list_toggle = new Adw.Toggle();
				list_toggle.icon_name = "view-list-symbolic";
				list_toggle.tooltip = _("List view");
				list_toggle.name = "list";
				list_toggle.description = _("Switch to list view with columns for name, text, date and path");
				view_toggle.add(list_toggle);

				var grid_toggle = new Adw.Toggle();
				grid_toggle.icon_name = "view-grid-symbolic";
				grid_toggle.tooltip = _("Grid view");
				grid_toggle.name = "grid";
				grid_toggle.description = _("Switch to thumbnail grid view");
				view_toggle.add(grid_toggle);

				string saved_mode = settings.get_view_mode();
				view_toggle.active_name = saved_mode;
				on_view_toggled(saved_mode == "list");

				view_toggle.notify["active-name"].connect(() => {
						on_view_toggled(view_toggle.active_name == "list");
						settings.set_view_mode(view_toggle.active_name);
				});

			// --- Results page header ---
			var sort_group = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 2);
			sort_group.append(sort_button);
			sort_group.append(view_toggle);
			sort_group.append(menu_button);

			var results_title = new Gtk.CenterBox();
			results_title.set_center_widget(search_overlay);

			var results_header = new Adw.HeaderBar();
			results_header.pack_start(pie_click);
			results_header.title_widget = results_title;
			results_header.pack_end(sort_group);

			// Toast overlay
			toast_overlay = new Adw.ToastOverlay();

			// Stack for switching between states
			stack = new Gtk.Stack();
			stack.transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT;
			stack.hexpand = true;
			stack.vexpand = true;

			var no_folders_status = new Adw.StatusPage();
			no_folders_status.icon_name = "folder-new-symbolic";
			no_folders_status.title = _("No folders configured");
			no_folders_status.description = _("Add folders with images to start scanning");
			no_folders_status.set_vexpand(true);

			var add_folder_btn = new Gtk.Button.with_label(_("Open Settings"));
			add_folder_btn.add_css_class("pill");
			add_folder_btn.add_css_class("suggested-action");
			add_folder_btn.set_halign(Gtk.Align.CENTER);
			add_folder_btn.clicked.connect(() => {
					var app = get_application() as Application;
					if(app != null) app.activate_action("preferences", null);
			});
			no_folders_status.set_child(add_folder_btn);
			stack.add_named(no_folders_status, "no-folders");

			var no_images_status = new Adw.StatusPage();
			no_images_status.icon_name = "image-x-generic-symbolic";
			no_images_status.title = _("No images scanned yet");
			no_images_status.description = _("Add images to your folders or run a scan to get started");
			no_images_status.set_vexpand(true);
			stack.add_named(no_images_status, "no-images");

			var empty_status = new Adw.StatusPage();
			empty_status.icon_name = "system-search-symbolic";
			empty_status.title = _("Start searching to find text inside your images");
			empty_status.set_vexpand(true);
			empty_status.set_hexpand(true);
			stack.add_named(empty_status, "empty");

			var scan_state_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 16);
			scan_state_box.set_halign(Gtk.Align.CENTER);
			scan_state_box.set_valign(Gtk.Align.CENTER);
			scan_state_box.set_hexpand(true);
			scan_state_box.set_vexpand(true);
((Gtk.Accessible) scan_state_box).accessible_role = Gtk.AccessibleRole.GROUP;
			set_widget_accessible_label(scan_state_box, _("Scanning"));

			var scan_spinner = new Adw.Spinner();
			scan_spinner.set_size_request(48, 48);
			scan_state_box.append(scan_spinner);

			var scan_label = new Gtk.Label(_("Scanning images..."));
			scan_label.add_css_class("title-3");
			scan_state_box.append(scan_label);

			scan_sublabel = new Gtk.Label("");
			scan_sublabel.add_css_class("dimmed");
			scan_sublabel.add_css_class("caption");
			scan_state_box.append(scan_sublabel);
			stack.add_named(scan_state_box, "scanning");

			var search_state_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 16);
			search_state_box.set_halign(Gtk.Align.CENTER);
			search_state_box.set_valign(Gtk.Align.CENTER);
			search_state_box.set_hexpand(true);
			search_state_box.set_vexpand(true);

			var search_spinner = new Adw.Spinner();
			search_spinner.set_size_request(48, 48);
			search_state_box.append(search_spinner);

			var search_label = new Gtk.Label(_("Searching..."));
			search_label.add_css_class("title-3");
			search_state_box.append(search_label);
			stack.add_named(search_state_box, "searching");

			view_stack = new Gtk.Stack();
			view_stack.transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT;
			view_stack.hexpand = true;
			view_stack.vexpand = true;
			view_stack.add_named(list_view, "list");
			view_stack.add_named(grid_view, "grid");

			view_stack.visible_child_name = settings.get_view_mode();
			results_page = view_stack;
			stack.add_named(results_page, "results");

			// --- ToolbarView wraps the stack with the header bar ---
			var results_toolbar = new Adw.ToolbarView();
			results_toolbar.add_top_bar(results_header);
			results_toolbar.set_content(stack);

			// --- Sidebar stack contains only the preview sidebar ---
			sidebar_stack = new Gtk.Stack();
			sidebar_stack.transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT;
			sidebar_stack.hexpand = true;
			sidebar_stack.vexpand = true;
			sidebar_stack.add_named(preview_sidebar, "preview");
			sidebar_stack.visible_child_name = "preview";

			// --- Preview header buttons ---
			preview_close_btn = new Gtk.Button.from_icon_name("sidebar-show-right-symbolic");
			preview_close_btn.add_css_class("flat");
			preview_close_btn.tooltip_text = _("Close preview");
		var preview_folder_btn = new Gtk.Button.from_icon_name("document-open-symbolic");
		preview_folder_btn.add_css_class("flat");
		preview_folder_btn.tooltip_text = _("Open containing folder");
		var preview_open_btn = new Gtk.Button.from_icon_name("external-link-symbolic");
		preview_open_btn.add_css_class("flat");
		preview_open_btn.tooltip_text = _("Open externally");
		var preview_copy_btn = new Gtk.Button.from_icon_name("edit-copy-symbolic");
		preview_copy_btn.add_css_class("flat");
		preview_copy_btn.tooltip_text = _("Copy image to clipboard");
		preview_close_btn.clicked.connect(() => hide_preview_sidebar());
		preview_folder_btn.clicked.connect(() => open_containing_folder());
		preview_open_btn.clicked.connect(() => open_current_file());
		preview_copy_btn.clicked.connect(() => copy_current_image());

			// --- Preview NavigationPage ---
			var preview_header = new Adw.HeaderBar();
			preview_header.show_title = false;
			preview_header.pack_start(preview_close_btn);
			preview_header.pack_end(preview_open_btn);
			preview_header.pack_end(preview_folder_btn);
			preview_header.pack_end(preview_copy_btn);

			var preview_toolbar = new Adw.ToolbarView();
			preview_toolbar.add_top_bar(preview_header);
			preview_toolbar.set_content(sidebar_stack);

			// --- OverlaySplitView: results as content, preview as sidebar ---
		split_view = new Adw.OverlaySplitView();
		split_view.content = results_toolbar;
		split_view.sidebar = preview_toolbar;
		split_view.sidebar_position = Gtk.PackType.END;
		split_view.show_sidebar = false;

		var breakpoint = new Adw.Breakpoint(
				new Adw.BreakpointCondition.length(
						Adw.BreakpointConditionLengthType.MAX_WIDTH, 720, Adw.LengthUnit.PX));
		breakpoint.add_setter(split_view, "collapsed", true);
		add_breakpoint(breakpoint);

		// When transitioning back from collapsed (mobile) to desktop, ensure
		// the sidebar stays hidden if there's nothing selected.
		split_view.notify["collapsed"].connect(() => {
				if(!split_view.collapsed && current_selected_entry == null) {
						split_view.show_sidebar = false;
				}
		});

		// Catch external sidebar dismissals (swipe/click-away on mobile).
		// When that happens, show_sidebar becomes false but our cleanup
		// in hide_preview_sidebar() never runs, so the item stays selected.
		split_view.notify["show-sidebar"].connect(() => {
				if(!split_view.show_sidebar && !hiding_sidebar && current_selected_entry != null) {
						preview_sidebar.clear();
						current_selected_entry = null;
						if(list_view != null) list_view.select_entry(null);
						if(grid_view != null) grid_view.select_entry(null);
				}
		});

			toast_overlay.set_child(split_view);
			set_content(toast_overlay);

			list_view.image_selected.connect((entry) => {
					current_selected_entry = entry;
					preview_sidebar.set_entry(entry);
					show_preview_sidebar();
			});
			grid_view.image_selected.connect((entry) => {
					current_selected_entry = entry;
					preview_sidebar.set_entry(entry);
					show_preview_sidebar();
			});

			preview_sidebar.close_preview.connect(() => {
					hide_preview_sidebar();
			});

		}

// Intercept printable key presses in the main window and redirect them to
// the search entry, focusing it and inserting the typed character.
		private bool on_window_key_pressed(uint keyval, uint keycode, Gdk.ModifierType state) {
				// If a text widget already has focus, let it handle typing normally.
				var focus = get_focus();
				if(focus is Gtk.Editable || focus is Gtk.TextView) {
						return false;
				}

				// Ignore keys combined with Ctrl/Alt/Super(shortcuts), and ignore
				// navigation/action keys. Tab must be excluded explicitly because
				// keyval_to_unicode(Tab) returns '\t'(0x09), not 0.
				if((state &(Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK)) != 0) {
						return false;
				}
				if(keyval == Gdk.Key.Tab || keyval == Gdk.Key.ISO_Left_Tab ||
						keyval == Gdk.Key.KP_Tab || keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) {
						return false;
				}

				// Escape: close scan popover, clear search, close preview, or focus search
				if(keyval == Gdk.Key.Escape) {
						// If scan popover is visible, close it first
						if(scan_popover.get_visible()) {
								scan_popover.popdown();
								return true;
						}
						// If search has focus and has text, clear it
						if(search_entry.has_focus && search_entry.get_text().length > 0) {
								search_entry.set_text("");
								return true;
						}
						// If preview sidebar is visible, close it
						if(split_view.show_sidebar) {
								hide_preview_sidebar();
								return true;
						}
						// Otherwise focus the search entry
						search_entry.grab_focus();
						return true;
				}

				unichar c =(unichar) Gdk.keyval_to_unicode(keyval);
				if(c == 0) {
						return false;
				}

				search_entry.grab_focus();
				search_entry.set_text(search_entry.get_text() + c.to_string());
				search_entry.set_position(-1);
				return true;
		}

		public void init_signals() {
				// Connect pie click to show popover(toggle)
				pie_click.clicked.connect(() => {
						if(scan_popover.get_visible()) {
								scan_popover.popdown();
						} else {
								scan_popover.popup();
						}
				});

				// Show appropriate empty state immediately, defer heavy data loading
				// so the window appears quickly before querying the database
				stack.set_visible_child_name("empty");

				Idle.add(() => {
						if(disposing) return Source.REMOVE;

						uint count = database.get_all_images_count();
						uint folder_count = database.get_all_folders_count();
						bool is_scanning = scanner.is_scanning();
						if(count > 0) {
								show_all_results();
						} else if(is_scanning) {
								// Scan is in progress — show results view so images
								// appear as they're scanned. Do NOT switch to an
								// empty-state page (e.g. "no-images") because that
								// would hide the scan progress UI. This guard
								// prevents a race where this idle fires after
								// scan_started and overwrites the "results" page.
								stack.set_visible_child_name("results");
						} else if(folder_count == 0) {
								stack.set_visible_child_name("no-folders");
						} else {
								stack.set_visible_child_name("no-images");
						}
						return Source.REMOVE;
				});

				// Connect scanner signals
				scanner.scan_started.connect((total) => {
						if(disposing) return;
						scanning = true;
						scan_paused = false;
						scan_pie.visible = true;
						pie_click.visible = true;
						scan_progress_fraction = 0.0;
						scan_pie.progress = 0.0;
						// Clear per-folder rows from previous scan
						scan_popover.clear_folders();

						// Show results view so images appear as they're scanned.
						// Only call show_all_results() if we're NOT already on the
						// results page — otherwise it would reset the search and
						// interrupt auto_load, leaving only 50 items visible.
						if(stack.visible_child_name == "results") {
								// Already showing results — new entries arrive via
								// file_saved → add_entry incrementally.
						} else if(database.get_all_images_count() > 0) {
								show_all_results();
						} else {
								stack.set_visible_child_name("results");
						}

						scan_pie.queue_draw();
						announce_to_screen_reader(_("Scan started"));
				});
				scanner.scan_progress.connect((current, total) => {
						if(disposing) return;
						// Store latest values for throttled display
						latest_current = current;
						latest_total = total;
						scan_progress_fraction = total > 0 ?(double) current / total : 0.0;

						// Update pie chart immediately(cheap redraw)
						scan_pie.progress = scan_progress_fraction;

						// Throttle label updates to 1000ms
						if(progress_display_id == 0) {
								update_progress_labels(current, total);
								progress_display_id = Timeout.add(1000,() => {
										update_progress_labels(latest_current, latest_total);
										progress_display_id = 0;
										return Source.REMOVE;
								});
						}
				});
				scanner.scan_paused.connect(() => {
						if(disposing) return;
						scan_paused = true;
						scan_sublabel.set_text(_("Paused — %d / %d").printf(latest_current, latest_total));
						announce_to_screen_reader(_("Scan paused"));
				});
				scanner.scan_resumed.connect(() => {
						if(disposing) return;
						scan_paused = false;
						scan_sublabel.set_text(_("%d / %d").printf(latest_current, latest_total));
						announce_to_screen_reader(_("Scan resumed"));
				});
				scanner.file_deleted.connect((path) => {
						if(disposing) return;
						// Remove from the flush buffer first — the entry may not
						// have been flushed to the list model yet (race between
						// the deletion queue drain at ~50ms and the flush timer
						// at ~200ms). Without this, a file that was saved to
						// the buffer then deleted before the flush timer fires
						// would survive permanently in the UI.
						// Collect entries to keep via intermediate array to avoid
						// modifying the list during iteration. The buffer is tiny
						// (<20 entries, usually 0-1).
						ImageEntry[] keep = {};
						for(int i = 0; i < pending_scan_entries.length(); i++) {
								var e = pending_scan_entries.nth_data(i);
								if(e.path != path) {
										keep += e;
								}
						}
						pending_scan_entries = new List<ImageEntry>();
						foreach(var e in keep) {
								pending_scan_entries.append(e);
						}
						if(list_view != null) {
								list_view.remove_entry_by_path(path);
						}
						if(grid_view != null) {
								grid_view.remove_entry_by_path(path);
						}
						// If the deleted file was selected, close the preview and clear it
						if(current_selected_entry != null && current_selected_entry.path == path) {
								hide_preview_sidebar();
						}
				});
				scanner.scan_folder_started.connect((folder_path, file_count) => {
						if(disposing) return;
						scan_popover.add_folder(folder_path, file_count);
						// Re-present popover so it resizes to fit new content
						if(scan_popover.visible) {
								scan_popover.present();
						}
				});
				scanner.scan_folder_progress.connect((folder_path, current, total) => {
						if(disposing) return;
						scan_popover.update_folder(folder_path, current, total);
				});
				scanner.scan_folder_completed.connect((folder_path, scanned, total) => {
						if(disposing) return;
						scan_popover.complete_folder(folder_path, scanned, total);
				});
				// Each newly saved image is added incrementally to the results view.
				// This uses O(1) duplicate checking via HashSet, so it's efficient
				// even with 10K+ files.
				scanner.file_saved.connect((entry) => {
						if(disposing) return;
						// Buffer entries for batched UI updates instead of per-file inserts
						pending_scan_entries.append(entry);
						if(scan_flush_id == 0) {
								// Schedule a flush 200ms from now(or sooner if we batch enough)
								scan_flush_id = Timeout.add(200,() => {
										scan_flush_id = 0;
										flush_scan_entries();
										return Source.REMOVE;
								});
						}
						// Also flush immediately if we have enough entries buffered
						if(pending_scan_entries.length() >= SCAN_FLUSH_BATCH) {
								if(scan_flush_id != 0) {
										Source.remove(scan_flush_id);
										scan_flush_id = 0;
								}
								flush_scan_entries();
						}
				});
				scanner.scan_completed.connect((scanned, total) => {
						if(disposing) return;
						// Flush any remaining buffered entries before completing
						if(scan_flush_id != 0) {
								Source.remove(scan_flush_id);
								scan_flush_id = 0;
						}
						flush_scan_entries();

						// Clean up progress display timer
						if(progress_display_id != 0) {
								Source.remove(progress_display_id);
								progress_display_id = 0;
						}

						scanning = false;
						scan_paused = false;
						scan_pie.visible = false;
						pie_click.visible = false;
						scan_progress_fraction = 1.0;
						scan_pie.progress = 1.0;
						scan_sublabel.set_text(_("Scan complete: %d / %d").printf(scanned, total));
						update_pause_button_icon();

						// Clear popover rows since scan is done
						scan_popover.clear_folders();

						// Final full refresh to ensure completeness, preserving any
						// active search query(important after a cleanup run).
						trigger_search_if_active();

						announce_to_screen_reader(_("Scan complete: %d images processed").printf(scanned));
				});
				scanner.scan_error.connect((message) => {
						if(disposing) return;
						warning("Scan error: %s", message);
						var toast = new Adw.Toast(message);
						toast_overlay.add_toast(toast);
						announce_to_screen_reader(_("Scan error: %s").printf(message));
				});
				scanner.no_models_available.connect(() => {
						if(disposing) return;
						var toast = new Adw.Toast(_("No OCR language models installed — download one in Settings to enable scanning"));
						toast.button_label = _("Open Settings");
						toast.action_name = "app.open-ocr-settings";
						toast_overlay.add_toast(toast);
				});

				// Refresh results when folders change (e.g. folder removed in preferences)
				database.folders_changed.connect(() => {
						if(disposing) return;
						// Defer the refresh to avoid modifying widgets during event handling
						Idle.add(() => {
								if(disposing) return Source.REMOVE;
								uint count = database.get_all_images_count();
								uint folder_count = database.get_all_folders_count();
								if(folder_count == 0) {
										stack.set_visible_child_name("no-folders");
								} else if(count > 0) {
										show_all_results();
								} else {
										stack.set_visible_child_name("no-images");
								}
								return Source.REMOVE;
						});
				});
		}

		public void set_scan_progress(int current, int total) {
				if(total > 0) {
						scan_progress_fraction =(double) current / total;
						scan_pie.progress = scan_progress_fraction;
				}
		}

		public void set_scanning(bool is_scanning) {
				scanning = is_scanning;
				if(!is_scanning) {
						scan_paused = false;
				}
				scan_pie.visible = is_scanning;
				pie_click.visible = is_scanning;
		}

		private void update_filter_button_position() {
				if (search_entry.get_text().length > 0) {
						filter_button.add_css_class("has-text");
				} else {
						filter_button.remove_css_class("has-text");
				}
		}

		private void on_search_changed() {
				hide_preview_sidebar();

				// Debounce search
				if(search_timeout_id != 0) {
						GLib.Source.remove(search_timeout_id);
						search_timeout_id = 0;
				}

				var query = search_entry.get_text();
				if(query.length == 0) {
						// Show all results when search is cleared.
						// Run on next main loop iteration to avoid UI freeze from immediate DB reload.
						Idle.add(() => {
								show_all_results();
								return Source.REMOVE;
						});
						return;
				}

				// Show searching state with Adwaita spinner
				stack.set_visible_child_name("searching");

				search_timeout_id = GLib.Timeout.add(300,() => {
						// Perform search with current filter settings
						bool match_case = settings.get_match_case();
						bool whole_words = settings.get_whole_words();

						// Track current search state for lazy view population
						current_search_query = query;
						current_match_case = match_case;
						current_whole_words = whole_words;

						populate_active_view();
						stack.set_visible_child_name("results");
						search_timeout_id = 0;
						return GLib.Source.REMOVE;
				});
		}

// Show all scanned images(empty query)
		private void show_all_results() {
				hide_preview_sidebar();

				// Track current search state for lazy view population
				current_search_query = "";
				current_match_case = false;
				current_whole_words = false;

				uint count = database.get_all_images_count();
				uint folder_count = database.get_all_folders_count();
				if(folder_count == 0) {
						stack.set_visible_child_name("no-folders");
				} else if(count > 0) {
						populate_active_view();
						stack.set_visible_child_name("results");
				} else {
						// Folders exist but no images yet
						stack.set_visible_child_name("no-images");
				}
		}

// Populate only the currently visible view(list or grid) with search results.
// The inactive view is left empty and will be populated on demand when the
// user switches to it, halving memory usage for results.
		private void populate_active_view() {
				bool is_list =(view_toggle != null && view_toggle.active_name == "list")
											 ||(view_toggle == null && settings.get_view_mode() == "list");
				if(is_list) {
						if(list_view != null) {
								list_view.search(current_search_query, current_match_case, current_whole_words,
																	current_sort_criteria, current_sort_direction,
																	current_date_from, current_date_to);
						}
				} else {
						if(grid_view != null) {
								grid_view.search(current_search_query, current_match_case, current_whole_words,
																	current_sort_criteria, current_sort_direction,
																	current_date_from, current_date_to);
						}
				}
		}

// Re-run search with current filters only if there's an active query.
// Directly re-apply text filters to current results.
// Used by filter checkboxes — same pattern as the date-clear fix.
		private void refilter_current_results() {
				var query = search_entry.get_text();
				if(query.length == 0) {
						show_all_results();
						return;
				}
				// Read filter state from FilterPopover — it keeps its properties
				// in sync with the checkbox widgets before emitting filters_changed.
				current_match_case = filter_popover.match_case;
				current_whole_words = filter_popover.whole_words;
				current_date_from = filter_popover.date_from;
				current_date_to = filter_popover.date_to;

				// Track current search state for lazy view population
				current_search_query = query;

				populate_active_view();
				stack.set_visible_child_name("results");
		}

// Used by other callers(sort, date apply) — kept for compatibility.
		private void trigger_search_if_active() {
				refilter_current_results();
		}

// Re-run the current search or refresh all results with the new sort order.
		private void apply_sort() {
				trigger_search_if_active();
		}

// Flush buffered scan entries to the active results view in one batch.
// Only the visible view receives new entries; the other will be populated
// on demand when the user switches to it.
		private void flush_scan_entries() {
				if(disposing) return;
				if(pending_scan_entries.length() == 0) return;

				// Make sure we're showing the results view
				if(stack.visible_child_name != "results") {
						stack.set_visible_child_name("results");
				}

				// Move entries to a local list to avoid reentrancy issues
				var entries =(owned) pending_scan_entries;
				pending_scan_entries = new List<ImageEntry>();
				scan_flush_id = 0;

				bool is_list =(view_toggle != null && view_toggle.active_name == "list")
											 ||(view_toggle == null && settings.get_view_mode() == "list");
				foreach(unowned var entry in entries) {
						if(is_list) {
								if(list_view != null) {
										list_view.add_entry(entry);
								}
						} else {
								if(grid_view != null) {
										grid_view.add_entry(entry);
								}
						}
				}
		}

// Switch between list and grid view
		private void on_view_toggled(bool is_list_view) {
				if(view_stack != null) {
						view_stack.visible_child_name = is_list_view ? "list" : "grid";
				}

				// Lazy population: if the newly active view has no results,
				// populate it now. This halves memory by only keeping one
				// view's results in memory at a time.
				bool needs_populate = false;
				if(is_list_view && list_view != null) {
						needs_populate = !list_view.has_results();
				} else if(!is_list_view && grid_view != null) {
						needs_populate = !grid_view.has_results();
				}
				if(needs_populate) {
						populate_active_view();
				}

				// Preserve selection state when switching views
				if(current_selected_entry != null) {
						if(is_list_view && list_view != null) {
								list_view.select_entry(current_selected_entry);
						} else if(!is_list_view && grid_view != null) {
								grid_view.select_entry(current_selected_entry);
						}
						show_preview_sidebar();
				}
		}

// Update progress labels with current/total values
		private void update_progress_labels(int current, int total) {
				if(scan_paused) {
						scan_sublabel.set_text(_("Paused — %d / %d").printf(current, total));
				} else {
						scan_sublabel.set_text(_("%d / %d").printf(current, total));
				}
		}

// Toggle pause/resume button icon and tooltip(now unused — kept for pie icon)
		private void update_pause_button_icon() {
				// Pause/resume buttons removed from popover; this is now a no-op
		}

// Handle window close request.
// If background scanning is enabled, just hide the window and keep running.
// Otherwise, stop the scan and allow the window to close(app quits).
		public override bool close_request() {
				if(settings.get_background_scan()) {
						// Keep scanning in the background — just hide the window.
						// Free UI model memory since nothing is visible.
						// The app stays alive via the hold() in Application.startup().
						free_ui_memory();
						hide();
						return true; // prevent close/destroy
				}

				disposing = true;

				if(scanning) {
						// Stop the scan cleanly before closing
						scanner.stop_scan();
				}

				// Clean up any pending timers to avoid callbacks on destroyed widgets
				if(progress_display_id != 0) {
						Source.remove(progress_display_id);
						progress_display_id = 0;
				}
				if(scan_flush_id != 0) {
						Source.remove(scan_flush_id);
						scan_flush_id = 0;
				}

				// Dismiss popovers to avoid Gtk-CRITICAL on dispose
				if(scan_popover != null && scan_popover.visible) {
						scan_popover.popdown();
				}
				if(filter_popover != null && filter_popover.visible) {
						filter_popover.popdown();
				}

				return false; // allow close
		}

// Free UI model memory when the window is hidden(background mode).
// Clears list/grid models, buffers, and thumbnails — they will be
// reloaded from the database when the window is reshown.
		private void free_ui_memory() {
				if(list_view != null) {
						list_view.free_memory();
				}
				if(grid_view != null) {
						grid_view.free_memory();
				}
				pending_scan_entries = new List<ImageEntry>();
				preview_sidebar.clear();
				thumbnail_service.clear_cache();
				database.clear_caches();
		}

// Refresh the UI state when the window is re-shown (e.g., after being hidden
// during background scanning). Ensures the pie, progress, and results view
// are up to date with the current scanner and database state.
		public void refresh_state() {
				if(disposing) return;

				// Sync scanning state
				bool is_scanning = scanner.is_scanning();
				set_scanning(is_scanning);
				if(is_scanning) {
						scan_paused = scanner.is_paused();
						if(scan_paused) {
								scan_sublabel.set_text(_("Paused"));
						}
				}

				// Show appropriate content based on current database state
				uint count = database.get_all_images_count();
				uint folder_count = database.get_all_folders_count();
				if(folder_count == 0) {
						stack.set_visible_child_name("no-folders");
				} else if(count > 0) {
						show_all_results();
				} else if(is_scanning) {
						stack.set_visible_child_name("results");
				} else {
						stack.set_visible_child_name("no-images");
				}
		}

// Show the preview sidebar — sets the OverlaySplitView show_sidebar property.
	private void show_preview_sidebar() {
		split_view.show_sidebar = true;
	}

// Hide the preview sidebar — clears preview, deselects the item, and hides sidebar.
		private void hide_preview_sidebar() {
				if(!split_view.show_sidebar) return;
				hiding_sidebar = true;
				split_view.show_sidebar = false;
				preview_sidebar.clear();
				current_selected_entry = null;
				if(list_view != null) {
						list_view.select_entry(null);
				}
				if(grid_view != null) {
						grid_view.select_entry(null);
				}
				hiding_sidebar = false;
		}

// Whether the preview sidebar is currently visible.
	public bool is_preview_visible() {
		return split_view.show_sidebar;
	}

// Close the preview sidebar if open.
		public void close_preview_sidebar() {
				if(split_view.show_sidebar) {
						hide_preview_sidebar();
				}
		}

// Focus the preview sidebar OCR text if the preview is visible.
		public void focus_preview() {
				if(split_view.show_sidebar) {
						preview_sidebar.focus_ocr_text();
				} else {
						// No preview open — focus search instead
						search_entry.grab_focus();
				}
		}

// Open the containing folder and highlight the file (like browsers do).
		public void open_containing_folder() {
				if(current_selected_entry == null) {
						return;
				}
				var file = GLib.File.new_for_path(current_selected_entry.path);
				// Try DBus ShowItems first to highlight the file in the file manager
				try {
						var connection = Bus.get_sync(BusType.SESSION);
						var uri = file.get_uri();
						var variant = new Variant.tuple(new Variant[] {
								new Variant.strv(new string[] { uri }),
								new Variant.string("")
						});
						connection.call(
								"org.freedesktop.FileManager1",
								"/org/freedesktop/FileManager1",
								"org.freedesktop.FileManager1",
								"ShowItems",
								variant,
								null,
								DBusCallFlags.NONE,
								3000,
								null);
						return;
				} catch(Error dbus_error) {
						// DBus not available — fall back to just opening the folder
				}
				try {
						var parent = file.get_parent();
						if(parent != null) {
								AppInfo.launch_default_for_uri(parent.get_uri(), null);
						}
				} catch(Error e) {
						warning("Failed to open containing folder: %s", e.message);
				}
		}

// Move keyboard focus to the search entry.
		public void focus_search() {
				search_entry.grab_focus();
		}

// Switch between list and grid view programmatically.
		public void switch_to_view(string view_name) {
				view_toggle.active_name = view_name;
		}

// Clear the search bar text and show all results.
		public void clear_search() {
				search_entry.set_text("");
				search_entry.grab_focus();
				show_all_results();
		}

// Open the filter popover(search filters + date range).
		public void open_filter_popover() {
				filter_popover.popup();
		}

// Open the currently selected image in the default image viewer.
		public void open_current_file() {
				if(current_selected_entry == null) {
						return;
				}
				try {
						var uri = GLib.File.new_for_path(current_selected_entry.path).get_uri();
						AppInfo.launch_default_for_uri(uri, null);
				} catch(Error e) {
						warning("Failed to open file: %s", e.message);
				}
		}

// Copy the currently selected image to the clipboard.
		public void copy_current_image() {
				if(current_selected_entry == null) {
						return;
				}
				try {
						var texture = Gdk.Texture.from_filename(current_selected_entry.path);
						var clipboard = Gdk.Display.get_default().get_clipboard();
						clipboard.set_texture(texture);
				} catch(Error e) {
						warning("Failed to copy image to clipboard: %s", e.message);
				}
		}





// Helper: set accessible label on any widget via the Gtk.Accessible interface.
		private void set_widget_accessible_label(Gtk.Widget widget, string label) {
				Gtk.AccessibleProperty[] props = { Gtk.AccessibleProperty.LABEL };
				var val = GLib.Value(typeof(string));
				val.set_string(label);
				GLib.Value[] vals = { val };
((Gtk.Accessible) widget).update_property_value(props, vals);
		}

// Helper: set accessible description on any widget via the Gtk.Accessible interface.
		private void set_widget_accessible_description(Gtk.Widget widget, string description) {
				Gtk.AccessibleProperty[] props = { Gtk.AccessibleProperty.DESCRIPTION };
				var val = GLib.Value(typeof(string));
				val.set_string(description);
				GLib.Value[] vals = { val };
((Gtk.Accessible) widget).update_property_value(props, vals);
		}

// Announce a message to screen readers for important state changes.
		private void announce_to_screen_reader(string message) {
((Gtk.Accessible) this).announce(message, Gtk.AccessibleAnnouncementPriority.MEDIUM);
		}
}

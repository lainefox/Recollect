// Simple list model wrapping ImageEntry[] for use with Gtk.ColumnView
public class ImageEntryListModel : Object, ListModel {
	private ImageEntry[] entries = {};

	public uint get_n_items() {
		return entries.length;
	}

	public Object? get_item(uint position) {
		if(position < entries.length) {
			return entries[position];
		}
		return null;
	}

	public Type get_item_type() {
		return typeof(ImageEntry);
	}

	public void clear() {
		uint old_n = entries.length;
		entries = {};
		items_changed(0, old_n, 0);
	}

	public void append_entries(ImageEntry[] new_entries) {
		if(new_entries.length == 0) return;
		uint pos = entries.length;
		ImageEntry[] combined = new ImageEntry[entries.length + new_entries.length];
		for(int i = 0; i < entries.length; i++) {
			combined[i] = entries[i];
		}
		for(int i = 0; i < new_entries.length; i++) {
			combined[entries.length + i] = new_entries[i];
		}
		entries = combined;
		items_changed(pos, 0, new_entries.length);
	}

	public void insert_entry(ImageEntry entry, int pos) {
		if(pos < 0) pos = 0;
		if(pos > entries.length) pos = entries.length;
		ImageEntry[] combined = new ImageEntry[entries.length + 1];
		for(int i = 0; i < pos; i++) {
			combined[i] = entries[i];
		}
		combined[pos] = entry;
		for(int i = pos; i < entries.length; i++) {
			combined[i + 1] = entries[i];
		}
		entries = combined;
		items_changed((uint) pos, 0, 1);
	}

	public void remove_at(uint index) {
		if(index >= entries.length) return;
		if(entries.length == 1) {
			entries = {};
			items_changed(0, 1, 0);
			return;
		}
		var new_entries = new ImageEntry[entries.length - 1];
		for(int i = 0; i <(int) index; i++) {
			new_entries[i] = entries[i];
		}
		for(int i =(int) index + 1; i < entries.length; i++) {
			new_entries[i - 1] = entries[i];
		}
		entries = new_entries;
		items_changed(index, 1, 0);
	}
}

// ResultsListView displays search results in a column view
public class ResultsListView : Gtk.Box {
	public DatabaseService db { get; construct set; }
	public ThumbnailService thumbnail_service { get; construct set; }
	private Gtk.ColumnView column_view;
	private Gtk.ScrolledWindow scroller;
	private ImageEntryListModel list_model;
	private Gtk.SingleSelection selection_model;
	private Gtk.Overlay overlay;
	private Adw.StatusPage no_results_page;

	private string current_query = "";
	private bool current_match_case = false;
	private bool current_whole_words = false;
	private SortCriteria current_sort_criteria = SortCriteria.DATE;
	private SortDirection current_sort_direction = SortDirection.DESCENDING;
	private int64 current_date_from = 0;
	private int64 current_date_to = 0;
	private HashTable<string, bool> displayed_paths = new HashTable<string, bool>(str_hash, str_equal);

	// Column references for visibility toggling
	private Gtk.ColumnViewColumn name_column;
	private Gtk.ColumnViewColumn text_column;
	private Gtk.ColumnViewColumn date_column;
	private Gtk.ColumnViewColumn path_column;

	public signal void image_selected(ImageEntry entry);
	public signal void context_menu_requested(ImageEntry entry, Gtk.Widget anchor, double x, double y);

	public ResultsListView(DatabaseService database, ThumbnailService thumbnail_service) {
		Object(db: database, thumbnail_service: thumbnail_service);
	}

	construct {
		orientation = Gtk.Orientation.VERTICAL;
		spacing = 0;
		hexpand = true;
		vexpand = true;
		margin_start = 8;
		margin_end = 8;

		list_model = new ImageEntryListModel();
		selection_model = new Gtk.SingleSelection(list_model);
		selection_model.autoselect = false;
		selection_model.can_unselect = true;

		column_view = new Gtk.ColumnView(selection_model);
		column_view.show_column_separators = false;
		column_view.show_row_separators = false;
		column_view.hexpand = true;
		column_view.vexpand = true;

		// ── Name column(expanding star column) ──
		var name_factory = new Gtk.SignalListItemFactory();
		name_factory.setup.connect((obj) => {
			var list_item =(Gtk.ListItem) obj;

			var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
			box.valign = Gtk.Align.FILL;

			var thumb = new Gtk.Image();
			thumb.set_pixel_size(32);
			thumb.valign = Gtk.Align.FILL;
			// Force minimum size so row height never collapses to 0
			thumb.set_size_request(32, 32);

			var label = new Gtk.Label("");
			label.halign = Gtk.Align.START;
			label.xalign = 0.0f;
			label.ellipsize = Pango.EllipsizeMode.END;
			label.valign = Gtk.Align.FILL;
			label.add_css_class("heading");

			box.hexpand = true;
			box.halign = Gtk.Align.FILL;
			box.append(thumb);
			box.append(label);
			list_item.child = box;
		});
		name_factory.bind.connect((obj) => {
			var list_item =(Gtk.ListItem) obj;
			var entry = list_item.item as ImageEntry;
			if(entry == null) return;
			var box = list_item.child as Gtk.Box;
			var thumb = box.get_first_child() as Gtk.Image;
			var label = thumb.get_next_sibling() as Gtk.Label;
			label.label = entry.get_filename().make_valid(-1);
			// Accessible labels for screen readers(on the ListItem, since 4.12)
			list_item.accessible_label = entry.get_filename();
			list_item.accessible_description = entry.get_accessible_text_summary();
			thumb.set_from_icon_name("image-x-generic-symbolic");
			load_thumbnail_async(entry.path, thumb);
		});


		name_column = new Gtk.ColumnViewColumn(_("Name"), name_factory);
		name_column.expand = true;
		name_column.resizable = true;

		// ── Text column ──
		var text_factory = new Gtk.SignalListItemFactory();
		text_factory.setup.connect((obj) => {
			var list_item =(Gtk.ListItem) obj;

			var label = new Gtk.Label("");
			label.halign = Gtk.Align.FILL;
			label.valign = Gtk.Align.FILL;
			label.xalign = 0.0f;
			label.ellipsize = Pango.EllipsizeMode.MIDDLE;
			label.hexpand = true;
			label.add_css_class("caption");
			label.add_css_class("dimmed");
			label.set_margin_top(8);
			label.set_margin_bottom(8);
			label.set_margin_start(16);
			label.set_margin_end(16);
			list_item.child = label;
		});
		text_factory.bind.connect((obj) => {
			var list_item =(Gtk.ListItem) obj;
			var entry = list_item.item as ImageEntry;
			if(entry == null) return;
			var label = list_item.child as Gtk.Label;
			string snippet =(entry.text_content ?? _("No text found")).make_valid(-1);
			// Highlight the searched phrase when there is an active query.
			if(current_query.length > 0) {
				label.set_markup(highlight_query(snippet, current_query, current_match_case, current_whole_words));
			} else {
				label.label = snippet;
			}
		});

		text_column = new Gtk.ColumnViewColumn(_("Text"), text_factory);
		text_column.resizable = true;

		// ── Date column ──
		var date_factory = new Gtk.SignalListItemFactory();
		date_factory.setup.connect((obj) => {
			var list_item =(Gtk.ListItem) obj;

			var label = new Gtk.Label("");
			label.halign = Gtk.Align.FILL;
			label.valign = Gtk.Align.FILL;
			label.xalign = 0.0f;
			label.ellipsize = Pango.EllipsizeMode.END;
			label.hexpand = true;
			label.add_css_class("caption");
			label.add_css_class("dimmed");
			label.set_margin_top(8);
			label.set_margin_bottom(8);
			label.set_margin_start(16);
			label.set_margin_end(16);
			list_item.child = label;
		});
		date_factory.bind.connect((obj) => {
			var list_item =(Gtk.ListItem) obj;
			var entry = list_item.item as ImageEntry;
			if(entry == null) return;
			var label = list_item.child as Gtk.Label;
			if(entry.file_created_at > 0) {
				var dt = new DateTime.from_unix_local(entry.file_created_at);
				label.label = dt.format("%x %X");
			} else {
				label.label = "";
			}
		});

		date_column = new Gtk.ColumnViewColumn(_("Date"), date_factory);
		date_column.resizable = true;

		// ── Path column ──
		var path_factory = new Gtk.SignalListItemFactory();
		path_factory.setup.connect((obj) => {
			var list_item =(Gtk.ListItem) obj;

			var label = new Gtk.Label("");
			label.halign = Gtk.Align.FILL;
			label.valign = Gtk.Align.FILL;
			label.xalign = 0.0f;
			label.ellipsize = Pango.EllipsizeMode.START;
			label.hexpand = true;
			label.add_css_class("caption");
			label.add_css_class("dimmed");
			label.set_margin_top(8);
			label.set_margin_bottom(8);
			label.set_margin_start(16);
			label.set_margin_end(16);
			list_item.child = label;
		});
		path_factory.bind.connect((obj) => {
			var list_item =(Gtk.ListItem) obj;
			var entry = list_item.item as ImageEntry;
			if(entry == null) return;
			var label = list_item.child as Gtk.Label;
			label.label = Path.get_dirname(entry.path).make_valid(-1);
		});

		var path_column = new Gtk.ColumnViewColumn(_("Path"), path_factory);
		path_column.resizable = true;

		column_view.append_column(name_column);
		column_view.append_column(text_column);
		column_view.append_column(date_column);
		column_view.append_column(path_column);

		selection_model.selection_changed.connect((position, n_items) => {
			var entry = selection_model.selected_item as ImageEntry;
			if(entry != null) {
				image_selected(entry);
			}
		});

		// Double-click / Enter to open
		column_view.activate.connect((position) => {
			var entry = list_model.get_item(position) as ImageEntry;
			if(entry != null) {
				open_image(entry.path);
			}
		});

		// Overlay for empty state
		overlay = new Gtk.Overlay();
		
		// Scroller
		scroller = new Gtk.ScrolledWindow();
		scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
		scroller.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
		scroller.hexpand = true;
		scroller.vexpand = true;
		scroller.child = column_view;

		overlay.child = scroller;

		// Empty state overlay
		no_results_page = new Adw.StatusPage();
		no_results_page.icon_name = "system-search-symbolic";
		no_results_page.title = _("No results found");
		no_results_page.description = _("Try adjusting your search or filters");
		no_results_page.set_vexpand(true);
		no_results_page.set_hexpand(true);
		no_results_page.set_valign(Gtk.Align.CENTER);
		no_results_page.set_halign(Gtk.Align.CENTER);
		no_results_page.visible = false;
		overlay.add_overlay(no_results_page);

		append(overlay);

		column_view.add_css_class("results-list");

		// Single right-click gesture on the whole column_view — estimates the
		// row from click coordinates and scroll offset. Row height is ~48px.
		var column_right_click = new Gtk.GestureClick();
		column_right_click.button = 3;
		column_right_click.pressed.connect((n_press, x, y) => {
				double scroll_y = scroller.vadjustment.value;
				int row_height = 48;
				int header_height = 36;
				uint position = (uint)(double.max(0.0, scroll_y + y - header_height) / row_height);
				if(position < list_model.get_n_items()) {
						var entry = list_model.get_item(position) as ImageEntry;
						if(entry != null) {
								context_menu_requested(entry, column_view, x, y);
						}
				}
		});
		column_view.add_controller(column_right_click);
	}
	private void load_thumbnail_async(string path, Gtk.Image thumb) {
		if(thumbnail_service == null) return;
		thumb.set_data<string>("thumbnail-path", path);
		thumbnail_service.request_thumbnail(path, ThumbnailService.SIZE_LIST,(tex) => {
			var current_path = thumb.get_data<string>("thumbnail-path");
			if(tex != null && current_path == path) {
				thumb.set_from_paintable(tex);
			}
		});
	}

	private void open_image(string path) {
		var file = File.new_for_path(path);
		try {
			AppInfo? app = AppInfo.get_default_for_type("image/*", false);
			if(app == null) {
				app = AppInfo.get_default_for_uri_scheme("file");
			}
			if(app != null) {
				var uri_list = new List<string>();
				uri_list.append(file.get_uri());
				app.launch_uris(uri_list, null);
			}
		} catch(Error e) {
			warning("Failed to open file: %s", e.message);
		}
	}

	// Load ALL matching images from the database into the list model.
	// GTK ColumnView virtualizes rendering — only visible rows get widgets.
	// Thousands of items in the model is fine; GTK handles it like Nautilus.
	public void search(string query, bool match_case = false, bool whole_words = false,
											SortCriteria sort_criteria = SortCriteria.DATE, SortDirection sort_direction = SortDirection.DESCENDING,
											int64 date_from = 0, int64 date_to = 0) {
		current_query = query;
		current_match_case = match_case;
		current_whole_words = whole_words;
		current_sort_criteria = sort_criteria;
		current_sort_direction = sort_direction;
		current_date_from = date_from;
		current_date_to = date_to;

		list_model.clear();
		displayed_paths.remove_all();

		var results = db.search_images(query, match_case, whole_words,
																	 sort_criteria, sort_direction,
																	 date_from, date_to);
		if(results == null || results.length == 0) {
			no_results_page.visible = true;
			return;
		}

		no_results_page.visible = false;
		list_model.append_entries(results);
		foreach(unowned var entry in results) {
			displayed_paths.insert(entry.path, true);
		}
	}

	public void clear() {
		search("");
	}

// Return the current vertical scroll position of the results list.
	public double get_scroll_position() {
		return scroller.vadjustment.value;
	}

// Restore the vertical scroll position of the results list.
	public void set_scroll_position(double value) {
		scroller.vadjustment.value = value;
	}

	public void select_entry(ImageEntry? entry) {
		if(entry == null) {
			selection_model.selected = Gtk.INVALID_LIST_POSITION;
			return;
		}

		for(uint i = 0; i < list_model.get_n_items(); i++) {
			var e = list_model.get_item(i) as ImageEntry;
			if(e != null && e.path == entry.path) {
				selection_model.selected = i;
				return;
			}
		}
	}

// Add a single entry for live-updating during scan.
// Uses HashSet for O(1) duplicate detection instead of O(n) linear scan.
// Limits display to MAX_DISPLAY_DURING_SCAN during active scanning to
// prevent GTK layout floods with thousands of rows.
	public void add_entry(ImageEntry entry) {
		// O(1) duplicate check via hash table
		if(displayed_paths.contains(entry.path)) {
			return;
		}
		int pos = find_sorted_insert_position(entry);
		list_model.insert_entry(entry, pos);
		displayed_paths.insert(entry.path, true);
		no_results_page.visible = false;
	}

// Remove the entry with the given path from the visible results.
	public void remove_entry_by_path(string path) {
		if(!displayed_paths.contains(path)) {
			return;
		}
		displayed_paths.remove(path);

		uint n = list_model.get_n_items();
		for(uint i = 0; i < n; i++) {
			var entry = list_model.get_item(i) as ImageEntry;
			if(entry != null && entry.path == path) {
				list_model.remove_at(i);
				break;
			}
		}

		if(list_model.get_n_items() == 0) {
			no_results_page.visible = true;
		}
	}

// Compare two entries according to the current sort criteria/direction.
	private int compare_entries(ImageEntry a, ImageEntry b) {
		int cmp;
		switch(current_sort_criteria) {
			case SortCriteria.NAME:
				cmp = a.path.collate(b.path);
				break;
			case SortCriteria.DATE:
			default:
				cmp =(int)(a.file_created_at - b.file_created_at);
				break;
		}
		return current_sort_direction == SortDirection.ASCENDING ? cmp : -cmp;
	}

// Find the position where @entry should be inserted to keep the list sorted.
	private int find_sorted_insert_position(ImageEntry entry) {
		uint n = list_model.get_n_items();
		for(uint i = 0; i < n; i++) {
			var existing = list_model.get_item(i) as ImageEntry;
			if(existing != null && compare_entries(entry, existing) <= 0) {
				return(int) i;
			}
		}
		return(int) n;
	}

// Free model memory — called when the window is hidden in background mode.
// Clears the list model and dedup set so GObject references can be collected.
	public void free_memory() {
		list_model.clear();
		displayed_paths.remove_all();
	}

// Whether this view currently holds any results.
	public bool has_results() {
		return list_model.get_n_items() > 0;
	}

// Highlight the first matching occurrence of the query in @text using Pango markup.
	private string highlight_query(string text, string query, bool match_case, bool whole_words) {
		if(query.length == 0) {
			return Markup.escape_text(text);
		}

		string q = match_case ? query : query.down();
		string t = match_case ? text : text.down();

		int match_start = -1;
		int match_end = -1;

		if(whole_words) {
			// Find the first whole-word occurrence.
			int idx = t.index_of(q);
			while(idx >= 0) {
				int end = idx + q.length;
				bool left_boundary = idx == 0 || !t[idx - 1].isalnum();
				bool right_boundary = end == t.length || !t[end].isalnum();
				if(left_boundary && right_boundary) {
					match_start = idx;
					match_end = end;
					break;
				}
				idx = t.index_of(q, idx + 1);
			}
		} else {
			// Substring match(always the base behavior, like browser find)
			match_start = t.index_of(q);
			if(match_start >= 0) {
				match_end = match_start + q.length;
			}
		}

		if(match_start < 0) {
			return Markup.escape_text(text);
		}

		string before = text.substring(0, match_start);
		string match = text.substring(match_start, match_end - match_start);
		string after = text.substring(match_end);

		return "%s<b>%s</b>%s".printf(
			Markup.escape_text(before),
			Markup.escape_text(match),
			Markup.escape_text(after)
		);
	}
}

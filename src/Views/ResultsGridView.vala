// ResultsGridView displays search results as a responsive grid of square tiles.
// Uses Gtk.GridView which automatically adds columns as the window widens.
public class ResultsGridView : Gtk.Box {
		public DatabaseService db { get; construct set; }
		public ThumbnailService thumbnail_service { get; construct set; }

		private Gtk.ScrolledWindow scroller;
		private Gtk.GridView grid_view;
		private GLib.ListStore list_store;

	private string current_query = "";
	private SortCriteria current_sort_criteria = SortCriteria.DATE;
	private SortDirection current_sort_direction = SortDirection.DESCENDING;
	private int64 current_date_from = 0;
	private int64 current_date_to = 0;
	private uint selected_position = Gtk.INVALID_LIST_POSITION;
	private HashTable<string, bool> displayed_paths = new HashTable<string, bool>(str_hash, str_equal);
	private Gtk.Overlay overlay;
	private Adw.StatusPage no_results_page;

		public signal void image_selected(ImageEntry entry);
	public signal void context_menu_requested(ImageEntry entry, Gtk.Widget anchor, double x, double y);

		public ResultsGridView(DatabaseService database, ThumbnailService thumbnail_service) {
				Object(db: database, thumbnail_service: thumbnail_service);
		}

		construct {
				orientation = Gtk.Orientation.VERTICAL;
				spacing = 0;
				hexpand = true;
				vexpand = true;
				margin_start = 8;
				margin_end = 8;

				list_store = new GLib.ListStore(typeof(ImageEntry));

				// NoSelection model — hovering over items does NOT change selection.
				// Selection only happens when the user clicks(via activate signal).
				// This prevents the sidebar from updating on hover.
				var selection = new Gtk.NoSelection(list_store);

				var factory = new Gtk.SignalListItemFactory();
				factory.setup.connect(on_factory_setup);
				factory.bind.connect(on_factory_bind);
				factory.unbind.connect(on_factory_unbind);

				// Gtk.GridView with VERTICAL orientation lays out columns left-to-right,
				// wrapping to the next row — exactly like a responsive grid.
				// Column count = floor(available_width / tile_width), automatic on resize.
				grid_view = new Gtk.GridView(selection, factory);
				grid_view.orientation = Gtk.Orientation.VERTICAL;
				grid_view.hexpand = true;
				grid_view.vexpand = true;
				grid_view.add_css_class("results-grid");
				grid_view.single_click_activate = true;
				grid_view.activate.connect(on_item_activated);

				scroller = new Gtk.ScrolledWindow();
				scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
				scroller.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
				scroller.hexpand = true;
				scroller.vexpand = true;
				scroller.child = grid_view;

				no_results_page = new Adw.StatusPage();
				no_results_page.icon_name = "system-search-symbolic";
				no_results_page.title = _("No results found");
				no_results_page.description = _("Try adjusting your search or filters");
				no_results_page.set_vexpand(true);
				no_results_page.set_hexpand(true);
				no_results_page.set_valign(Gtk.Align.CENTER);
				no_results_page.set_halign(Gtk.Align.CENTER);
				no_results_page.visible = false;

				overlay = new Gtk.Overlay();
				overlay.child = scroller;
				overlay.add_overlay(no_results_page);

				append(overlay);

				// Single right-click gesture on the whole grid_view — estimates
				// the tile position from click coordinates and scroll offset.
				var grid_right_click = new Gtk.GestureClick();
				grid_right_click.button = 3;
				grid_right_click.pressed.connect((n_press, x, y) => {
						int view_height = grid_view.get_height();
						int view_width = grid_view.get_width();
						if(view_width <= 0 || view_height <= 0) return;
						double scroll_y = scroller.vadjustment.value;
						int tile_size = 200;
						int spacing = 6;
						int stride = tile_size + spacing;
						int n_columns = (int) double.max(1.0, (double) view_width / stride);
						if(n_columns == 0) return;
						int row = (int)((scroll_y + y) / stride);
						int col = (int)(x / stride);
						uint position = (uint)(row * n_columns + col);
						if(position < list_store.n_items) {
								var entry = list_store.get_item(position) as ImageEntry;
								if(entry != null) {
										context_menu_requested(entry, grid_view, x, y);
								}
						}
				});
				grid_view.add_controller(grid_right_click);

				// Model is attached directly at construct time.
		}

		// --- Factory callbacks ---

		private void on_factory_setup(Object item) {
				var list_item = item as Gtk.ListItem;
				if(list_item == null) return;

				// Fixed square size — GridView uses width to calculate column count.
				// ContentFit.COVER zooms/crops the image to fill the square without stretching.
				var picture = new Gtk.Picture();
				picture.content_fit = Gtk.ContentFit.COVER;
				picture.width_request = 200;
				picture.height_request = 200;
				picture.add_css_class("tile-image");

				list_item.child = picture;
				list_item.activatable = true;
				list_item.selectable = false; // No native selection — we track manually
		}

		private void on_factory_bind(Object item) {
				var list_item = item as Gtk.ListItem;
				if(list_item == null) return;

				var entry = list_item.item as ImageEntry;
				if(entry == null) return;

				var picture = list_item.child as Gtk.Picture;
				if(picture == null) return;

				// Accessible label for screen readers(on the ListItem, since 4.12)
				list_item.accessible_label = entry.get_filename();
				list_item.accessible_description = entry.get_accessible_text_summary();

				// Store path for stale-load cancellation
				picture.set_data<string>("path", entry.path);

				// Load thumbnail async
				load_thumbnail_async(picture, entry.path);
		}

		private void on_factory_unbind(Object item) {
				var list_item = item as Gtk.ListItem;
				if(list_item == null) return;

				var picture = list_item.child as Gtk.Picture;
				if(picture != null) {
						picture.paintable = null;
						picture.set_data<string>("path",(string?) null);
				}
		}

// Load a thumbnail via the bounded, deduplicating ThumbnailService pool.
// Spawning a thread per bind blew up memory when thousands of items bound
// during a scan; routing through the shared pool bounds concurrency.
		private void load_thumbnail_async(Gtk.Picture picture, string path) {
				if(thumbnail_service == null) return;
				thumbnail_service.request_thumbnail(path, ThumbnailService.SIZE_GRID,(tex) => {
						// Only apply if this picture is still bound to the same path
						//(it may have been rebound to a different item by now).
						string? check_path = picture.get_data<string>("path");
						if(tex != null && check_path == path) {
								picture.paintable = tex;
						}
				});
		}

		// --- Selection(click only, no hover) ---

		private void on_item_activated(uint position) {
				selected_position = position;

				// Apply .tile-selected to the clicked item's widget and remove from others.
				// Walk visible children to update CSS classes.
				uint idx = 0;
				var child = grid_view.get_first_child();
				while(child != null) {
						var list_item = child as Gtk.ListItem;
						if(list_item != null) {
								if(list_item.child != null) {
										if(idx == position) {
												list_item.child.add_css_class("tile-selected");
										} else {
												list_item.child.remove_css_class("tile-selected");
										}
								}
								idx++;
						}
						child = child.get_next_sibling();
				}

				var entry = list_store.get_item(position) as ImageEntry;
				if(entry != null) {
						image_selected(entry);
				}
		}

		// Load ALL matching images from the database into the list store.
		// GTK GridView virtualizes rendering — only visible tiles get widgets.
		public void search(string query, bool match_case = false, bool whole_words = false,
												SortCriteria sort_criteria = SortCriteria.DATE, SortDirection sort_direction = SortDirection.DESCENDING,
												int64 date_from = 0, int64 date_to = 0) {
				current_query = query;
				current_sort_criteria = sort_criteria;
				current_sort_direction = sort_direction;
				current_date_from = date_from;
				current_date_to = date_to;

				list_store.remove_all();
				displayed_paths.remove_all();
				no_results_page.visible = false;

				var results = db.search_images(query, match_case, whole_words,
																			 sort_criteria, sort_direction,
																			 date_from, date_to);
				if(results == null || results.length == 0) {
						no_results_page.visible = true;
						return;
				}

				foreach(unowned var entry in results) {
						list_store.append(entry);
						displayed_paths.insert(entry.path, true);
				}
		}

		public void select_entry(ImageEntry? entry) {
				if(entry == null) {
						selected_position = Gtk.INVALID_LIST_POSITION;

						var child = grid_view.get_first_child();
						while(child != null) {
								var list_item = child as Gtk.ListItem;
								if(list_item != null && list_item.child != null) {
										list_item.child.remove_css_class("tile-selected");
								}
								child = child.get_next_sibling();
						}
						return;
				}

				uint n = list_store.n_items;
				for(uint i = 0; i < n; i++) {
						var e = list_store.get_item(i) as ImageEntry;
						if(e != null && e.path == entry.path) {
								on_item_activated(i);
								return;
						}
				}
		}

		public void add_entry(ImageEntry entry) {
				if(displayed_paths.contains(entry.path)) {
						return;
				}

				uint pos = find_sorted_insert_position(entry);
				list_store.insert(pos, entry);
				displayed_paths.insert(entry.path, true);
				no_results_page.visible = false;
		}

// Remove the entry with the given path from the visible grid.
		public void remove_entry_by_path(string path) {
				if(!displayed_paths.contains(path)) {
						return;
				}
				displayed_paths.remove(path);

				uint n = list_store.n_items;
				for(uint i = 0; i < n; i++) {
						var entry = list_store.get_item(i) as ImageEntry;
						if(entry != null && entry.path == path) {
								list_store.remove(i);
								break;
						}
				}

				if(list_store.n_items == 0) {
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

// Find the position where @entry should be inserted to keep the grid sorted.
		private uint find_sorted_insert_position(ImageEntry entry) {
				uint n = list_store.n_items;
				for(uint i = 0; i < n; i++) {
						var existing = list_store.get_item(i) as ImageEntry;
						if(existing != null && compare_entries(entry, existing) <= 0) {
								return i;
						}
				}
				return n;
		}

// Free model memory — called when the window is hidden in background mode.
// Clears the list store and dedup set so GObject references can be collected.
		public void free_memory() {
				list_store.remove_all();
				displayed_paths.remove_all();
		}

// Whether this view currently holds any results.
		public bool has_results() {
				return list_store.get_n_items() > 0;
		}

		public void clear() {
				search("");
		}

// Return the current vertical scroll position as a fraction of the total
// scrollable height. The grid's content height changes when the window
// width changes(more/less columns), so a relative position survives
// sidebar open/close better than a raw pixel value.
		public double get_scroll_position() {
				var adj = scroller.vadjustment;
				double max = adj.upper - adj.page_size;
				return max > 0.0 ? adj.value / max : 0.0;
		}

// Restore the vertical scroll position from a fraction of the current
// scrollable height.
		public void set_scroll_position(double value) {
				var adj = scroller.vadjustment;
				double max = adj.upper - adj.page_size;
				if(max > 0.0) {
						adj.value = value * max;
				}
		}
}
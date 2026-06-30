// ScanPopover — popover showing per-folder scan progress during OCR scanning.
// Contains per-folder progress bars, status labels, and stop buttons.
// Attached to the pie_click button in MainWindow.
public class ScanPopover : Gtk.Popover {
		// Emitted when the user clicks the stop button for a folder
		public signal void stop_folder(string folder_path);

		private Gtk.Box folders_box;

		// Per-folder widget tracking
		private HashTable<string, Gtk.Label> folder_title_labels = new HashTable<string, Gtk.Label>(str_hash, str_equal);
		private HashTable<string, Gtk.Label> folder_status_labels = new HashTable<string, Gtk.Label>(str_hash, str_equal);
		private HashTable<string, Gtk.ProgressBar> folder_progress_bars = new HashTable<string, Gtk.ProgressBar>(str_hash, str_equal);
		private HashTable<string, Gtk.Button> folder_stop_buttons = new HashTable<string, Gtk.Button>(str_hash, str_equal);

		construct {
				has_arrow = true;

				var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
				box.set_margin_start(12);
				box.set_margin_end(12);
				box.set_margin_top(8);
				box.set_margin_bottom(8);

				folders_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 10);
				folders_box.hexpand = true;
				folders_box.set_size_request(320, -1);
				box.append(folders_box);

				child = box;
		}

		// Add a new folder progress row.
		public void add_folder(string folder_path, int file_count) {
				var basename = Path.get_basename(folder_path).make_valid(-1);

				var title_label = new Gtk.Label(_("Scanning '%s'").printf(basename));
				title_label.set_halign(Gtk.Align.START);
				title_label.hexpand = true;
				title_label.add_css_class("title-4");
				title_label.set_ellipsize(Pango.EllipsizeMode.END);
				title_label.tooltip_text = folder_path;

				var progress_bar = new Gtk.ProgressBar();
				progress_bar.hexpand = true;
				progress_bar.valign = Gtk.Align.CENTER;
				progress_bar.set_fraction(file_count > 0 ? 0.0 : 1.0);
				progress_bar.set_show_text(false);

				var stop_btn = new Gtk.Button.from_icon_name("window-close-symbolic");
				stop_btn.add_css_class("circular");
				stop_btn.tooltip_text = _("Stop scanning");
				stop_btn.valign = Gtk.Align.CENTER;
				stop_btn.margin_start = 6;
				if(file_count == 0) {
						stop_btn.sensitive = false;
				}
				stop_btn.clicked.connect(() => {
						stop_folder(folder_path);
						stop_btn.sensitive = false;
				});

				var progress_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 4);
				progress_row.hexpand = true;
				progress_row.append(progress_bar);
				progress_row.append(stop_btn);

				var status_label = new Gtk.Label("0 / %d".printf(file_count));
				status_label.set_halign(Gtk.Align.START);
				status_label.add_css_class("caption");
				status_label.add_css_class("dim-label");

				var row_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
				row_box.set_margin_top(4);
				row_box.set_margin_bottom(4);
				row_box.append(title_label);
				row_box.append(progress_row);
				row_box.append(status_label);

				folders_box.append(row_box);
				folder_title_labels.insert(folder_path, title_label);
				folder_status_labels.insert(folder_path, status_label);
				folder_progress_bars.insert(folder_path, progress_bar);
				folder_stop_buttons.insert(folder_path, stop_btn);
		}

		// Update a folder's progress bar and status label.
		public void update_folder(string folder_path, int current, int total) {
				var status_label = folder_status_labels.lookup(folder_path);
				var progress_bar = folder_progress_bars.lookup(folder_path);
				if(status_label != null) {
						status_label.set_text("%d / %d".printf(current, total));
				}
				if(progress_bar != null) {
						progress_bar.set_fraction(total > 0 ? (double) current / total : 0.0);
				}
		}

		// Mark a folder as complete — replace stop button with checkmark.
		public void complete_folder(string folder_path, int scanned, int total) {
				var stop_btn = folder_stop_buttons.lookup(folder_path);
				if(stop_btn != null) {
						stop_btn.set_child(new Gtk.Image.from_icon_name("object-select-symbolic"));
						stop_btn.sensitive = false;
						stop_btn.tooltip_text = _("Done");
				}
				update_folder(folder_path, scanned, total);
		}

		// Remove all folder progress rows.
		public void clear_folders() {
				var child = folders_box.get_first_child();
				while(child != null) {
						var next = child.get_next_sibling();
						folders_box.remove(child);
						child = next;
				}
				folder_title_labels.remove_all();
				folder_status_labels.remove_all();
				folder_progress_bars.remove_all();
				folder_stop_buttons.remove_all();
		}
}

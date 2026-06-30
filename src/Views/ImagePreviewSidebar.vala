// ImagePreviewSidebar displays selected image preview and OCR text.
// Content is wrapped in a Gtk.ScrolledWindow so it scrolls when
// available height is smaller than the preview + text + properties.
public class ImagePreviewSidebar : Gtk.Box {
		private ThumbnailService thumbnail_service;
		private DatabaseService? database;
		private ImageEntry? current_entry = null;
		private Gtk.Image preview_image;
		private Gtk.TextView ocr_text_view;
		private Gtk.TextBuffer buffer;
		private Gtk.Label scanned_at_label;
		private Gtk.Label accuracy_label;
		private Gtk.Label filename_label;
		private Gtk.Label path_label;
		private Gtk.ScrolledWindow scrolled_window;

		public signal void close_preview();

		public ImagePreviewSidebar(ThumbnailService thumbnail_service) {
				Object();
				this.thumbnail_service = thumbnail_service;
		}

// Set the database service reference so the sidebar can lazily load
// full OCR text that was truncated in list/grid results.
		public void set_database(DatabaseService db) {
				this.database = db;
		}

		construct {
				orientation = Gtk.Orientation.VERTICAL;
				spacing = 0;
				hexpand = false;
				vexpand = true;
				valign = Gtk.Align.FILL;
				add_css_class("image-preview-sidebar");
				set_size_request(350, -1);

				var content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
				content_box.hexpand = true;
				content_box.vexpand = false;

				scrolled_window = new Gtk.ScrolledWindow();
				scrolled_window.child = content_box;
				scrolled_window.hscrollbar_policy = Gtk.PolicyType.NEVER;
				scrolled_window.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
				scrolled_window.hexpand = true;
				scrolled_window.vexpand = true;
				append(scrolled_window);

// Header: filename only (close button lives in the header bar)
			var header_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
			header_box.hexpand = true;

			filename_label = new Gtk.Label("");
			filename_label.halign = Gtk.Align.START;
			filename_label.hexpand = true;
			filename_label.ellipsize = Pango.EllipsizeMode.END;
			filename_label.add_css_class("heading");
			filename_label.add_css_class("title-4");
			header_box.append(filename_label);

				content_box.append(header_box);

				// Path
				path_label = new Gtk.Label("");
				path_label.halign = Gtk.Align.START;
				path_label.add_css_class("caption");
				path_label.add_css_class("dimmed");
				path_label.ellipsize = Pango.EllipsizeMode.END;
				content_box.append(path_label);

				// Preview image
				preview_image = new Gtk.Image();
				preview_image.pixel_size = 250;
				preview_image.halign = Gtk.Align.CENTER;
				preview_image.valign = Gtk.Align.START;
				preview_image.add_css_class("preview-image");
				content_box.append(preview_image);

				// OCR Text section
				var ocr_label = new Gtk.Label(_("Scanned text:"));
				ocr_label.halign = Gtk.Align.START;
				ocr_label.add_css_class("heading");
				content_box.append(ocr_label);

				buffer = new Gtk.TextBuffer(null);
				ocr_text_view = new Gtk.TextView.with_buffer(buffer);
				ocr_text_view.editable = false;
				ocr_text_view.cursor_visible = false;
				ocr_text_view.wrap_mode = Gtk.WrapMode.WORD_CHAR;
				ocr_text_view.add_css_class("text-view");
				ocr_text_view.add_css_class("view");

				var ocr_scroller = new Gtk.ScrolledWindow();
				ocr_scroller.child = ocr_text_view;
				ocr_scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
				ocr_scroller.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
				ocr_scroller.vexpand = true;
				ocr_scroller.set_size_request(-1, 120);
				content_box.append(ocr_scroller);

				// Properties section
				var properties_label = new Gtk.Label(_("Properties:"));
				properties_label.halign = Gtk.Align.START;
				properties_label.add_css_class("heading");
				content_box.append(properties_label);

				// Scanned date
				scanned_at_label = new Gtk.Label("");
				scanned_at_label.halign = Gtk.Align.START;
				scanned_at_label.add_css_class("body");
				content_box.append(scanned_at_label);

				// OCR model(language + accuracy)
				accuracy_label = new Gtk.Label("");
				accuracy_label.halign = Gtk.Align.START;
				accuracy_label.add_css_class("body");
				content_box.append(accuracy_label);
		}

		public void set_entry(ImageEntry? entry) {
				current_entry = entry;

				if(entry == null) {
						clear();
						return;
				}

				// Set filename
				filename_label.label = entry.get_filename().make_valid(-1);

				// Set path
				string folder_path = Path.get_dirname(entry.path).make_valid(-1);
				path_label.label = folder_path;

				// Set preview image - load with Glycin for real thumbnails
				load_preview_image_async(entry.path);

				// Set OCR text — load full content from DB if available(the list/grid
				// views truncate text_content to a snippet for memory efficiency).
				string? full_text = null;
				if(database != null) {
						full_text = database.get_full_text_content(entry.id);
				}
				if(full_text != null && full_text.length > 0) {
						buffer.set_text(full_text);
				} else if(entry.text_content != null && entry.text_content.length > 0) {
						buffer.set_text(entry.text_content.make_valid(-1));
				} else {
						buffer.set_text(_("No text found in this image"));
				}

				// Set scanned date
				var scanned_dt = new DateTime.from_unix_local(entry.scanned_at);
scanned_at_label.label = _("Scanned: %s").printf(scanned_dt.format("%Y-%m-%d %H:%M"));

				// Set OCR model info — load per-language model entries from the database
				string[] model_names = {};
				string[] model_accuracies = {};
				if(database != null) {
						database.get_ocr_models(entry.id, out model_names, out model_accuracies);
				}
				debug("[Sidebar] get_ocr_models returned %d models for image %lld(path=%s)",
							 model_names.length, entry.id, entry.path);
				if(model_names.length > 0) {
						// Build a comma-separated list of models
						string[] parts = new string[model_names.length];
						for(int i = 0; i < model_names.length; i++) {
								parts[i] = "%s(%s)".printf(model_names[i], model_accuracies[i]);
						}
						accuracy_label.label = _("Models: %s").printf(string.joinv(", ", parts));
				} else {
						// Fallback for older scans without model table entries
						string lang =(entry.ocr_language ?? "eng").make_valid(-1);
						string acc =(entry.accuracy_level ?? "balanced").make_valid(-1);
						accuracy_label.label = _("Models: %s (%s)").printf(lang, acc);
				}
		}

// Focus the OCR text view for keyboard scrolling/navigation.
		public void focus_ocr_text() {
				ocr_text_view.grab_focus();
		}

		public void clear() {
				current_entry = null;
				filename_label.label = "";
				path_label.label = "";
				preview_image.clear();
				if(buffer != null) {
						buffer.set_text("");
				}
				scanned_at_label.label = "";
				accuracy_label.label = "";
		}



// Load a preview image in a background thread to avoid blocking the main thread.
// Uses ThumbnailService to cache scaled thumbnails on disk.
		private void load_preview_image_async(string path) {
				preview_image.set_data<string>("sidebar-path", path);
				try {
						new Thread<void*>.try("preview-load",() => {
								Gdk.Texture? tex = null;
								if(thumbnail_service != null) {
										tex = thumbnail_service.generate_thumbnail(path, ThumbnailService.SIZE_PREVIEW);
								}
								// Apply texture on the main thread
								if(tex != null) {
										Idle.add(() => {
												var current_path = preview_image.get_data<string>("sidebar-path");
												if(current_path == path && tex != null) {
														preview_image.set_from_paintable(tex);
												}
												return Source.REMOVE;
										});
								}
								return null;
						});
				} catch(Error e) {
						warning("Failed to create preview load thread: %s", e.message);
				}
		}
}

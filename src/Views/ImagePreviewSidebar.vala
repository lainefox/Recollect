// ImagePreviewSidebar displays selected image preview and OCR text.
// Content is wrapped in a Gtk.ScrolledWindow so it scrolls when
// available height is smaller than the preview + text + properties.
public class ImagePreviewSidebar : Gtk.Box {
		private ThumbnailService thumbnail_service;
		private DatabaseService? database;
		private ImageEntry? current_entry = null;
		private AspectImage preview_image;
		private Gtk.Label filename_label;
		private Gtk.Label path_label;
		private Gtk.ScrolledWindow scrolled_window;
		private Adw.PreferencesGroup ocr_group;
		private Adw.ActionRow ocr_row;
		private Adw.PreferencesGroup properties_group;
		private Gtk.Label scanned_at_value;
		private Adw.WrapBox models_flowbox;

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
				content_box.margin_start = 12;
				content_box.margin_end = 12;
				content_box.margin_top = 12;
				content_box.margin_bottom = 12;

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

				// Preview image — wrapped in a black, padding-free container
				// so the image sits flush against a dark backdrop. The image
				// fills the container's width and grows vertically as needed,
				// expanding the black background.
				//
				// We use a custom AspectImage widget instead of Gtk.Picture:
				// Gtk.Picture reports its natural size as the paintable's
				// intrinsic size, which fights the vertical box layout and lets
				// the other sidebar content squeeze the image narrow. AspectImage
				// overrides measure() so its height is always proportional to its
				// width, so it fills the container width and pushes the content
				// below it down (making the sidebar scroll) instead of being
				// squished.
				var preview_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
				preview_container.hexpand = true;
				preview_container.add_css_class("preview-container");
				preview_image = new AspectImage();
				preview_image.hexpand = true;
				preview_image.halign = Gtk.Align.FILL;
				preview_image.valign = Gtk.Align.START;
				preview_image.add_css_class("preview-image");
				preview_container.append(preview_image);
				content_box.append(preview_container);

				// OCR Text section
				ocr_group = new Adw.PreferencesGroup();
				ocr_group.title = _("Scanned text");
				content_box.append(ocr_group);

				ocr_row = new Adw.ActionRow();
				ocr_row.activatable = false;
				ocr_row.selectable = false;
				ocr_row.subtitle_selectable = true;
				ocr_row.subtitle_lines = 0;
				ocr_row.use_markup = false;
				ocr_group.add(ocr_row);

				// Properties section
				properties_group = new Adw.PreferencesGroup();
				properties_group.title = _("Properties");
				content_box.append(properties_group);

				// Scanned date
				scanned_at_value = new Gtk.Label("");
				scanned_at_value.halign = Gtk.Align.START;
				scanned_at_value.add_css_class("body");
				properties_group.add(create_property_row(_("Date"), scanned_at_value));

				// OCR model(language + accuracy) — shown as chips
				// Uses Adw.WrapBox + the "tag" style class, matching the
				// adwaita wrap-box demo page (Gtk.FlowBox would add hover/active
				// rounded-square boxes to its children).
				models_flowbox = new Adw.WrapBox();
				models_flowbox.halign = Gtk.Align.START;
				models_flowbox.child_spacing = 6;
				models_flowbox.line_spacing = 6;
				properties_group.add(create_property_row(_("Models"), models_flowbox));
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
						ocr_row.use_markup = false;
						ocr_row.subtitle_selectable = true;
						ocr_row.subtitle = full_text.make_valid(-1);
				} else if(entry.text_content != null && entry.text_content.length > 0) {
						ocr_row.use_markup = false;
						ocr_row.subtitle_selectable = true;
						ocr_row.subtitle = entry.text_content.make_valid(-1);
				} else {
						// No text — show an italic, non-selectable placeholder.
						ocr_row.use_markup = true;
						ocr_row.subtitle_selectable = false;
						ocr_row.subtitle = "<i>%s</i>".printf(Markup.escape_text(_("No text found in this image")));
				}

				// Set scanned date
				var scanned_dt = new DateTime.from_unix_local(entry.scanned_at);
				scanned_at_value.label = scanned_dt.format("%Y-%m-%d %H:%M");

				// Set OCR model info — load per-language model entries from the database
				string[] model_names = {};
				string[] model_accuracies = {};
				if(database != null) {
						database.get_ocr_models(entry.id, out model_names, out model_accuracies);
				}
				debug("[Sidebar] get_ocr_models returned %d models for image %ld(path=%s)",
							 model_names.length, (long) entry.id, entry.path);
				clear_models_chips();
				if(model_names.length > 0) {
						// One chip per model
						for(int i = 0; i < model_names.length; i++) {
								add_model_chip("%s (%s)".printf(
										PreferencesDialog.get_language_display_name(model_names[i]),
										PreferencesDialog.variant_display_name(model_accuracies[i])));
						}
				} else {
						// Fallback for older scans without model table entries
						string lang =(entry.ocr_language ?? "eng").make_valid(-1);
						string acc =(entry.accuracy_level ?? "balanced").make_valid(-1);
						add_model_chip("%s (%s)".printf(
								PreferencesDialog.get_language_display_name(lang),
								PreferencesDialog.variant_display_name(acc)));
				}
		}

// Focus the OCR text for keyboard scrolling/navigation.
		public void focus_ocr_text() {
				ocr_row.grab_focus();
		}

		public void clear() {
				current_entry = null;
				filename_label.label = "";
				path_label.label = "";
				preview_image.set_texture(null);
				ocr_row.use_markup = false;
				ocr_row.subtitle_selectable = true;
				ocr_row.subtitle = "";
				scanned_at_value.label = "";
				clear_models_chips();
		}



// Build a custom property row: property name on top (dimmed, small) and
// the value below in prominent body text. Adw.ActionRow can't express this
// layout (its title is always the prominent top label), so we use a plain
// Gtk.ListBoxRow with a vertical box.
		private Gtk.ListBoxRow create_property_row(string name, Gtk.Widget value_widget) {
				var row = new Gtk.ListBoxRow();
				row.activatable = false;
				row.selectable = false;

				var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
				box.margin_start = 12;
				box.margin_end = 12;
				box.margin_top = 8;
				box.margin_bottom = 8;

				var name_label = new Gtk.Label(name);
				name_label.halign = Gtk.Align.START;
				name_label.add_css_class("caption");
				name_label.add_css_class("dimmed");
				box.append(name_label);

				value_widget.halign = Gtk.Align.START;
				box.append(value_widget);

				row.child = box;
				return row;
		}

// Add a single model chip to the models wrap box.
// Mirrors the adwaita wrap-box demo page's "tag" widget: a Gtk.Box with the
// "tag" CSS class containing a label. Chips are read-only and not clickable.
		private void add_model_chip(string text) {
				var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
				box.add_css_class("tag");
				box.hexpand = false;
				box.valign = Gtk.Align.CENTER;
				box.cursor = new Gdk.Cursor.from_name("default", null);

				var label = new Gtk.Label(text);
				label.xalign = 0;
				label.ellipsize = Pango.EllipsizeMode.END;
				label.hexpand = true;
				label.valign = Gtk.Align.CENTER;
				label.selectable = false;
				box.append(label);

				models_flowbox.append(box);
		}

// Remove all model chips from the wrap box.
		private void clear_models_chips() {
				models_flowbox.remove_all();
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
														preview_image.set_texture(tex);
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

// A widget that displays a Gdk.Texture scaled to fill its width while
// maintaining the texture's aspect ratio. Its height is always derived from
// its width, so it fills the container width and grows vertically as needed,
// pushing sibling content down (and making the sidebar scroll) instead of
// being squeezed narrow by other widgets.
//
// Gtk.Picture can't do this: it reports its natural size as the paintable's
// intrinsic size, which fights the vertical box layout. AspectImage overrides
// measure() so the natural height is proportional to the given width, and
// snapshot() draws the texture scaled to the widget's allocation.
private class AspectImage : Gtk.Widget {
		private Gdk.Texture? _texture = null;

		public AspectImage() {
				Object();
		}

		public void set_texture(Gdk.Texture? tex) {
				_texture = tex;
				queue_resize();
		}

		public override void measure(Gtk.Orientation orientation, int for_size,
				out int minimum, out int natural,
				out int minimum_baseline, out int natural_baseline) {
				minimum_baseline = -1;
				natural_baseline = -1;
				if(_texture == null) {
						minimum = 0;
						natural = 0;
						return;
				}
				if(orientation == Gtk.Orientation.HORIZONTAL) {
						// Fill the available width; no intrinsic width preference.
						minimum = 0;
						natural = 0;
				} else {
						// Height is proportional to the given width. When no width
						// is known (for_size == -1), use the widget's current
						// allocated width — it's already laid out before a texture
						// is set, so this matches the real width. Only fall back
						// to the sidebar width if never allocated yet.
						int w = for_size > 0 ? for_size : (get_width() > 0 ? get_width() : 350);
						int h =(int)((double)w * _texture.height / _texture.width);
						minimum = h;
						natural = h;
				}
		}

		public override void snapshot(Gtk.Snapshot snapshot) {
				if(_texture == null) return;
				int w = get_width();
				int h = get_height();
				if(w <= 0 || h <= 0) return;

				// Draw the texture to fill the allocation. measure() returns the
				// proportional height for the actual width, so the allocation
				// matches the texture's aspect ratio and filling it neither
				// stretches the image nor leaves black bars.
				var rect = Graphene.Rect();
				rect.init(0, 0, w, h);
				var rounded = Gsk.RoundedRect();
				rounded.init_from_rect(rect, 8);
				snapshot.push_rounded_clip(rounded);
				_texture.snapshot(snapshot, w, h);
				snapshot.pop();
		}
}

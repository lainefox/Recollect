// ProgressPie — reusable Nautilus-style filled circular progress indicator.
//
// Draws a filled pie wedge using the theme accent color. The progress value
// ranges from 0.0(empty background circle) to 1.0(full circle).
public class ProgressPie : Gtk.DrawingArea {
		public double progress { get; set; }
		public bool draw_empty_circle { get; set; default = true; }

		public ProgressPie(int size = 24) {
				Object(progress: 0.0);
				set_content_width(size);
				set_content_height(size);
				set_draw_func(draw);

				// Make the custom drawing area accessible as a progress indicator
((Gtk.Accessible) this).accessible_role = Gtk.AccessibleRole.PROGRESS_BAR;
				set_accessible_label(_("Scan progress: 0%"));

				notify["progress"].connect(() => {
						queue_draw();
						update_accessible_progress();
				});
				notify["draw-empty-circle"].connect(queue_draw);
		}

		private void update_accessible_progress() {
				int percent =(int)(progress * 100);
				set_accessible_label(_("Scan progress: %d%%").printf(percent));
		}

		// Vala bindings don't expose accessible_label as a property on generic
		// widgets, so we use update_property_value with an array workaround.
		private void set_accessible_label(string label) {
				Gtk.AccessibleProperty[] props = { Gtk.AccessibleProperty.LABEL };
				var val = GLib.Value(typeof(string));
				val.set_string(label);
				GLib.Value[] vals = { val };
((Gtk.Accessible) this).update_property_value(props, vals);
		}

		private void draw(Gtk.DrawingArea area, Cairo.Context cr, int width, int height) {
				double cx = width / 2.0;
				double cy = height / 2.0;
				double radius =(width / 2.0) - 2.0;

				// Look up the accent color from the theme.
				// StyleContext.lookup_color is deprecated in GTK 4.10 but still the
				// most reliable way to get theme colors in Vala.
				Gdk.RGBA accent = { 0.35f, 0.55f, 0.87f, 0.9f }; // fallback blue
				var style_context = get_style_context();
				if(!style_context.lookup_color("accent_bg_color", out accent)) {
						style_context.lookup_color("accent_color", out accent);
				}

				if(draw_empty_circle) {
						// Full background circle(light gray) — filled
						cr.set_source_rgba(0.85, 0.85, 0.85, 0.3);
						cr.new_path();
						cr.arc(cx, cy, radius, 0, 2 * Math.PI);
						cr.fill();
				}

				if(progress > 0) {
						// Progress wedge using accent color — filled
						double angle = progress * 2 * Math.PI;

						cr.set_source_rgba(accent.red, accent.green, accent.blue, accent.alpha);
						cr.new_path();
						cr.move_to(cx, cy);
						cr.arc(cx, cy, radius, -Math.PI / 2, -Math.PI / 2 + angle);
						cr.close_path();
						cr.fill();
				}
		}
}

// SortPopover — popover with sort criteria (name/date) and direction (ascending/descending) controls.
// Designed to be used as the popover of a Gtk.MenuButton in the main window header bar.
public class SortPopover : Gtk.Popover {
		// Emitted when the user changes sort criteria or direction
		public signal void changed(SortCriteria criteria, SortDirection direction);

		private SortCriteria _criteria = SortCriteria.DATE;
		private SortDirection _direction = SortDirection.DESCENDING;

		// Current sort state — read by MainWindow to pass to search
		public SortCriteria sort_criteria { get { return _criteria; } }
		public SortDirection sort_direction { get { return _direction; } }

		private Gtk.CheckButton name_radio;
		private Gtk.CheckButton date_radio;
		private Gtk.CheckButton desc_radio;
		private Gtk.CheckButton asc_radio;

		construct {
				var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
				box.set_margin_start(12);
				box.set_margin_end(12);
				box.set_margin_top(8);
				box.set_margin_bottom(8);

				name_radio = new Gtk.CheckButton.with_label(SortCriteria.NAME.to_display_string());
				date_radio = new Gtk.CheckButton.with_label(SortCriteria.DATE.to_display_string());
				date_radio.group = name_radio;

				desc_radio = new Gtk.CheckButton.with_label(SortDirection.DESCENDING.to_display_string());
				asc_radio = new Gtk.CheckButton.with_label(SortDirection.ASCENDING.to_display_string());
				asc_radio.group = desc_radio;

				date_radio.active = true;
				desc_radio.active = true;

				box.append(name_radio);
				box.append(date_radio);
				box.append(new Gtk.Separator(Gtk.Orientation.HORIZONTAL));
				box.append(desc_radio);
				box.append(asc_radio);

				child = box;

				name_radio.toggled.connect(() => {
						if(name_radio.active) {
								_criteria = SortCriteria.NAME;
								changed(_criteria, _direction);
						}
				});
				date_radio.toggled.connect(() => {
						if(date_radio.active) {
								_criteria = SortCriteria.DATE;
								changed(_criteria, _direction);
						}
				});
				desc_radio.toggled.connect(() => {
						if(desc_radio.active) {
								_direction = SortDirection.DESCENDING;
								changed(_criteria, _direction);
						}
				});
				asc_radio.toggled.connect(() => {
						if(asc_radio.active) {
								_direction = SortDirection.ASCENDING;
								changed(_criteria, _direction);
						}
				});
		}
}

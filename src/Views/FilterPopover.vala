// FilterPopover — popover with text search filters (match case, match diacritics, whole words)
// and a date range selector with sliding calendar page.
public class FilterPopover : Gtk.Popover {
		public SettingsService settings { get; construct; }

		// Emitted when any filter value changes (checkboxes or date range).
		// MainWindow reads the current properties and re-searches.
		public signal void filters_changed();

		// ── Read-only filter state for MainWindow ──
		public bool match_case { get; private set; default = false; }
		public bool whole_words { get; private set; default = false; }
		public int64 date_from { get; private set; default = 0; }
		public int64 date_to { get; private set; default = 0; }

		// ── Widgets ──
		private Gtk.CheckButton case_check;
		private Gtk.CheckButton diacritics_check;
		private Gtk.CheckButton whole_words_check;
		private Gtk.Stack filter_stack;
		private Gtk.Calendar date_calendar;
		private Gtk.Button before_date_button;
		private Gtk.Button after_date_button;
		private Gtk.Button before_clear_btn;
		private Gtk.Button after_clear_btn;
		private Gtk.Label cal_header_title;
		private bool calendar_editing_before = true;

		// Internal timestamp state for the date selector UI
		private int64 before_date_timestamp = 0;
		private int64 after_date_timestamp = 0;

		public FilterPopover(SettingsService settings) {
				Object(settings: settings);
		}

		construct {
				// ── Main filter page ──
				var filter_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
				filter_box.set_margin_start(12);
				filter_box.set_margin_end(12);
				filter_box.set_margin_top(8);
				filter_box.set_margin_bottom(8);

				case_check = new Gtk.CheckButton.with_label(_("Match case"));
				case_check.active = settings.get_match_case();
				case_check.tooltip_text = _("Distinguish between upper and lower case");
				filter_box.append(case_check);

				diacritics_check = new Gtk.CheckButton.with_label(_("Match diacritics"));
				diacritics_check.active = settings.get_match_diacritics();
				diacritics_check.tooltip_text = _("Distinguish between accented and unaccented characters");
				filter_box.append(diacritics_check);

				whole_words_check = new Gtk.CheckButton.with_label(_("Whole words"));
				whole_words_check.active = settings.get_whole_words();
				whole_words_check.tooltip_text = _("Only match whole words, not substrings");
				filter_box.append(whole_words_check);

				// ── Date range filter ──
				filter_box.append(new Gtk.Separator(Gtk.Orientation.HORIZONTAL));

				var main_page = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);

				var before_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
				before_box.hexpand = true;
				var before_lbl = new Gtk.Label(_("Before:"));
				before_date_button = new Gtk.Button.with_label(_("Not set"));
				before_date_button.hexpand = true;
				before_date_button.set_halign(Gtk.Align.FILL);
				before_date_button.add_css_class("flat");
				before_date_button.tooltip_text = _("Show images created before this date");
				before_box.append(before_lbl);
				before_box.append(before_date_button);

				before_clear_btn = new Gtk.Button.from_icon_name("window-close-symbolic");
				before_clear_btn.add_css_class("circular");
				before_clear_btn.add_css_class("flat");
				before_clear_btn.tooltip_text = _("Clear before date");
				before_clear_btn.visible = false;
				before_box.append(before_clear_btn);
				main_page.append(before_box);

				var after_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
				after_box.hexpand = true;
				var after_lbl = new Gtk.Label(_("After:"));
				after_date_button = new Gtk.Button.with_label(_("Not set"));
				after_date_button.hexpand = true;
				after_date_button.set_halign(Gtk.Align.FILL);
				after_date_button.add_css_class("flat");
				after_date_button.tooltip_text = _("Show images created after this date");
				after_box.append(after_lbl);
				after_box.append(after_date_button);

				after_clear_btn = new Gtk.Button.from_icon_name("window-close-symbolic");
				after_clear_btn.add_css_class("circular");
				after_clear_btn.add_css_class("flat");
				after_clear_btn.tooltip_text = _("Clear after date");
				after_clear_btn.visible = false;
				after_box.append(after_clear_btn);
				main_page.append(after_box);

				// ── Calendar page: back + confirm + calendar ──
				var cal_page = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);

				var cal_header = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
				var back_btn = new Gtk.Button.with_label(_("Back"));
				back_btn.add_css_class("flat");
				back_btn.set_halign(Gtk.Align.START);
				cal_header.append(back_btn);

				cal_header_title = new Gtk.Label(_("Select date"));
				cal_header_title.add_css_class("heading");
				cal_header_title.set_halign(Gtk.Align.CENTER);
				cal_header_title.hexpand = true;
				cal_header.append(cal_header_title);

				var select_btn = new Gtk.Button.with_label(_("Select"));
				select_btn.add_css_class("suggested-action");
				select_btn.set_halign(Gtk.Align.END);
				cal_header.append(select_btn);

				cal_page.append(cal_header);

				date_calendar = new Gtk.Calendar();
				date_calendar.hexpand = true;
				cal_page.append(date_calendar);

				// Stack with slide transition — non-homogeneous so popover resizes
				filter_stack = new Gtk.Stack();
				filter_stack.transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT;
				filter_stack.hhomogeneous = false;
				filter_stack.vhomogeneous = false;
				filter_stack.add_named(main_page, "main");
				filter_stack.add_named(cal_page, "calendar");
				filter_box.append(filter_stack);

				child = filter_box;

				// ── Signal wiring ──

				// From main to calendar — click a date button → slide to calendar page
				before_date_button.clicked.connect(() => {
						calendar_editing_before = true;
						cal_header_title.set_label(_("Before date"));
						if(before_date_timestamp > 0) {
								date_calendar.set_date(new DateTime.from_unix_local(before_date_timestamp));
						}
						filter_stack.visible_child_name = "calendar";
				});

				after_date_button.clicked.connect(() => {
						calendar_editing_before = false;
						cal_header_title.set_label(_("After date"));
						if(after_date_timestamp > 0) {
								date_calendar.set_date(new DateTime.from_unix_local(after_date_timestamp));
						}
						filter_stack.visible_child_name = "calendar";
				});

				// Back from calendar to main — does NOT apply the date
				back_btn.clicked.connect(() => {
						filter_stack.visible_child_name = "main";
				});

				// Select button applies the currently highlighted calendar date
				select_btn.clicked.connect(() => {
						var selected_dt = date_calendar.get_date();
						int year = selected_dt.get_year();
						int month = selected_dt.get_month();
						int day = selected_dt.get_day_of_month();
						int64 ts = selected_dt.to_unix();

						if(calendar_editing_before) {
								before_date_timestamp = ts;
								before_date_button.set_label("%d-%02d-%02d".printf(year, month, day));
								before_clear_btn.visible = true;
						} else {
								after_date_timestamp = ts;
								after_date_button.set_label("%d-%02d-%02d".printf(year, month, day));
								after_clear_btn.visible = true;
						}
						filter_stack.visible_child_name = "main";
						apply_date_filter();
				});

				after_clear_btn.clicked.connect(() => {
						after_date_timestamp = 0;
						after_date_button.set_label(_("Not set"));
						after_clear_btn.visible = false;
						apply_date_filter();
				});

				before_clear_btn.clicked.connect(() => {
						before_date_timestamp = 0;
						before_date_button.set_label(_("Not set"));
						before_clear_btn.visible = false;
						apply_date_filter();
				});

				// Reset to main page when popover opens
				show.connect(() => {
						filter_stack.visible_child_name = "main";
				});

				// Save filter settings and emit signal when toggled
				case_check.toggled.connect(() => {
						match_case = case_check.active;
						settings.set_match_case(match_case);
						filters_changed();
				});
				diacritics_check.toggled.connect(() => {
						settings.set_match_diacritics(diacritics_check.active);
						filters_changed();
				});
				whole_words_check.toggled.connect(() => {
						whole_words = whole_words_check.active;
						settings.set_whole_words(whole_words);
						filters_changed();
				});
		}

		// Clear all date selections and reset to "Not set" labels.
		public void reset_dates() {
				after_date_timestamp = 0;
				before_date_timestamp = 0;
				after_date_button.set_label(_("Not set"));
				before_date_button.set_label(_("Not set"));
				after_clear_btn.visible = false;
				before_clear_btn.visible = false;
				apply_date_filter();
		}

		// Recompute date_from / date_to from before/after timestamps and emit changed.
		private void apply_date_filter() {
				if(after_date_timestamp > 0) {
						date_from = after_date_timestamp;
				} else {
						date_from = 0;
				}

				if(before_date_timestamp > 0) {
						// Include the full selected day (end of day = start + 86399 seconds)
						date_to = before_date_timestamp + 86399;
				} else {
						date_to = 0;
				}

				filters_changed();
		}
}

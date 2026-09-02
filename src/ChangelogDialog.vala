// ChangelogDialog shows the release notes for an available update in a modal
// popup, with a Cancel button and a Download button in the header bar (akin to
// the OnboardingDialog). The Download button opens the GitHub release page.
public class ChangelogDialog : Adw.Dialog {
		private string release_url;

		public ChangelogDialog(string version, string release_notes, string release_url) {
				Object(title: _("What's New in v%s").printf(version));
				this.release_url = release_url;

				content_width = 520;
				content_height = 480;

				var toolbar_view = new Adw.ToolbarView();
				toolbar_view.hexpand = true;
				toolbar_view.vexpand = true;

				// Header bar with Cancel (start) and Download (end) buttons.
				var header = new Adw.HeaderBar();
				header.show_start_title_buttons = false;
				header.show_end_title_buttons = false;

				var cancel_btn = new Gtk.Button.with_label(_("Cancel"));
				cancel_btn.add_css_class("flat");
				cancel_btn.clicked.connect(() => {
						force_close();
				});
				header.pack_start(cancel_btn);

				var download_btn = new Gtk.Button.with_label(_("Download"));
				download_btn.add_css_class("suggested-action");
				download_btn.clicked.connect(() => {
						open_release_page();
						force_close();
				});
				header.pack_end(download_btn);

				toolbar_view.add_top_bar(header);

				// Changelog content — wrapped, selectable text in a scrollable area.
				var notes_label = new Gtk.Label(release_notes);
				notes_label.wrap = true;
				notes_label.xalign = 0.0f;
				notes_label.selectable = true;
				notes_label.margin_top = 12;
				notes_label.margin_bottom = 12;
				notes_label.margin_start = 16;
				notes_label.margin_end = 16;

				var scroller = new Gtk.ScrolledWindow();
				scroller.hexpand = true;
				scroller.vexpand = true;
				scroller.child = notes_label;

				toolbar_view.set_content(scroller);

				child = toolbar_view;
		}

		// Open the GitHub release page in the default browser.
		private void open_release_page() {
				if(release_url == "") return;
				try {
						AppInfo.launch_default_for_uri(release_url, null);
				} catch(Error e) {
						warning("Could not open release URL: %s", e.message);
				}
		}
}

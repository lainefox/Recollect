// UpdateService checks the GitHub Releases API for a newer version of the app.
//
// Since Recollect is distributed as a self-contained .flatpak bundle (no remote),
// there is no built-in update mechanism. This service queries the GitHub Releases
// API for the latest release tag and compares it against the running version.
//
// The network pattern mirrors TesseractModelService: a background thread performs
// the blocking HTTP request, and results are marshalled back to the main thread
// via Idle.add.
public class UpdateService : Object {
		// Signal emitted when the check completes.
		//   update_available: true if a newer version exists
		//   latest_version:   the latest version string (e.g. "0.2.0"), or "" if none
		//   release_url:      URL to the latest release page, or "" if none
		//   release_notes:    the changelog/body of the latest release, or "" if none
		//   error_message:    non-null if the check failed (network, rate limit, etc.)
		public signal void check_completed(bool update_available, string latest_version, string release_url, string release_notes, string? error_message);

		// The GitHub repo to query for the latest release.
		private const string REPO = "lainefox/Recollect";
		private const string RELEASES_API_URL = "https://api.github.com/repos/" + REPO + "/releases/latest";
		private const string RELEASES_PAGE_URL = "https://github.com/" + REPO + "/releases/latest";

		private SettingsService settings_service;

		private bool checking = false;

		// Last completed check result, so UI can query it even if the check
		// finished before a dialog/view connected to the signal.
		private bool has_result = false;
		private bool last_update_available = false;
		private string last_latest_version = "";
		private string last_release_url = "";
		private string last_release_notes = "";
		private string? last_error_message = null;

		public UpdateService(SettingsService settings_service) {
				this.settings_service = settings_service;
		}

		public bool is_checking() {
				return checking;
		}

		// Returns true if a check has completed at least once.
		public bool has_check_result() {
				return has_result;
		}

		// Returns the last completed check result. Only meaningful if has_result() is true.
		public void get_last_result(out bool update_available, out string latest_version, out string release_url, out string release_notes, out string? error_message) {
				update_available = last_update_available;
				latest_version = last_latest_version;
				release_url = last_release_url;
				release_notes = last_release_notes;
				error_message = last_error_message;
		}

		// Kick off an update check. Safe to call multiple times; concurrent
		// checks are ignored while one is already in flight. No-op if update
		// checking is disabled in settings.
		public void check_for_updates() {
				if(!settings_service.get_check_for_updates()) return;
				if(checking) return;
				checking = true;

				if(!NetworkMonitor.get_default().get_network_available()) {
						checking = false;
						store_and_emit(false, "", "", "", _("No Internet Connection"));
						return;
				}

				try {
						new Thread<void*>.try("check-updates",() => {
								string? latest_tag = null;
								string? release_notes = null;
								string? error_message = null;

								try {
										var session = new Soup.Session();
										var release = fetch_latest_release(session);
										latest_tag = release.tag_name;
										release_notes = release.body;
								} catch(Error err) {
										error_message = err.message;
								}

								Idle.add(() => {
										checking = false;
										if(error_message != null) {
												store_and_emit(false, "", "", "", error_message);
												return Source.REMOVE;
										}

										string latest_version = normalize_version((!) latest_tag);
										bool update_available = is_newer(latest_version, Config.VERSION);
										store_and_emit(update_available, latest_version, RELEASES_PAGE_URL, (!) release_notes, null);
										return Source.REMOVE;
								});
								return null;
						});
				} catch(Error err) {
						// Thread creation failed.
						checking = false;
						store_and_emit(false, "", "", "", err.message);
				}
		}

		// Store the result and emit the check_completed signal.
		private void store_and_emit(bool update_available, string latest_version, string release_url, string release_notes, string? error_message) {
				has_result = true;
				last_update_available = update_available;
				last_latest_version = latest_version;
				last_release_url = release_url;
				last_release_notes = release_notes;
				last_error_message = error_message;
				check_completed(update_available, latest_version, release_url, release_notes, error_message);
		}

		// Holds the parsed fields of a GitHub release we care about.
		private class ReleaseInfo {
				public string tag_name;
				public string body;

				public ReleaseInfo(string tag_name, string body) {
						this.tag_name = tag_name;
						this.body = body;
				}
		}

		// Fetch the tag_name and body (changelog) of the latest release from the GitHub API.
		private ReleaseInfo fetch_latest_release(Soup.Session session) throws Error {
				var message = new Soup.Message("GET", RELEASES_API_URL);
				message.request_headers.append("User-Agent", "Recollect/" + Config.VERSION);
				message.request_headers.append("Accept", "application/vnd.github+json");

				Bytes bytes = session.send_and_read(message, null);

				if(message.status_code != 200) {
						string detail;
						if(message.status_code == 403) {
								detail = _("GitHub API rate limit reached. Please wait a while before trying again.");
						} else if(message.status_code == 404) {
								detail = _("No releases found for this project.");
						} else {
								detail = "HTTP %u %s".printf(message.status_code, message.reason_phrase);
						}
						throw new IOError.FAILED(detail);
				}

				string body = (string) bytes.get_data();
				return parse_release(body);
		}

		// Extract the "tag_name" and "body" fields from a GitHub release JSON response.
		private ReleaseInfo parse_release(string json) throws Error {
				var parser = new Json.Parser();
				parser.load_from_data(json);
				var root = parser.get_root();
				if(root == null || root.get_node_type() != Json.NodeType.OBJECT) {
						throw new IOError.FAILED(_("Unexpected response from GitHub."));
				}
				var obj = root.get_object();
				if(!obj.has_member("tag_name")) {
						throw new IOError.FAILED(_("Unexpected response from GitHub."));
				}
				string tag_name = obj.get_string_member("tag_name");
				string body = obj.has_member("body") ? obj.get_string_member("body") : "";
				return new ReleaseInfo(tag_name, body);
		}

		// Strip a leading "v" from a version tag (e.g. "v0.2.0" -> "0.2.0").
		private string normalize_version(string tag) {
				if(tag.length > 1 && tag[0] == 'v') {
						return tag.substring(1);
				}
				return tag;
		}

		// Compare two dotted version strings (e.g. "0.2.0" vs "0.1.0").
		// Returns true if candidate is strictly newer than current.
		private bool is_newer(string candidate, string current) {
				int[] c = parse_version(candidate);
				int[] cur = parse_version(current);
				int max = int.max(c.length, cur.length);
				for(int i = 0; i < max; i++) {
						int cv = i < c.length ? c[i] : 0;
						int curv = i < cur.length ? cur[i] : 0;
						if(cv > curv) return true;
						if(cv < curv) return false;
				}
				return false;
		}

		// Split a dotted version string into integer components.
		private int[] parse_version(string version) {
				int[] parts = {};
				foreach(string part in version.split(".")) {
						int val = 0;
						try {
								val = int.parse(part);
						} catch(Error e) {
								val = 0;
						}
						parts += val;
				}
				return parts;
		}
}

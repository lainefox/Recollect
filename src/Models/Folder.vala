// Gom model representing a configured folder to scan
public class Folder : Gom.Resource {
		public int64 id { get; set; default = 0; }

		// Unique constraint enforced by Gom
		public string path { get; set; default = null; }

		public bool enabled { get; set; default = true; }
		public int64 added_at { get; set; default = 0; }
		public int64 last_scan_time { get; set; default = 0; }
		public int image_count { get; set; default = 0; }
		public string? display_name { get; set; default = null; }

		static construct {
				set_table("folder");
				set_primary_key("id");
				set_unique("path");
		}
}

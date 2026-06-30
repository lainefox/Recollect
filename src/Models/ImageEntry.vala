// ImageEntry represents a scanned image in the database
public class ImageEntry : Gom.Resource {
		public int64 id { get; set; default = 0; }

		// Unique constraint enforced by Gom
		public string path { get; set; default = null; }

		public string? text_content { get; set; default = null; }
		public int64 scanned_at { get; set; default = 0; }
		public int64 file_created_at { get; set; default = 0; }
		public int64 folder_id { get; set; default = 0; }
		public string accuracy_level { get; set; default = null; }
		public string ocr_language { get; set; default = null; }

		public string get_filename() {
				return Path.get_basename(this.path);
		}

		public int64 file_size { get; set; default = 0; }
		public string mime_type { get; set; default = null; }

		// Short text summary for screen readers (first 120 chars)
		public string get_accessible_text_summary() {
				if(text_content == null || text_content.length == 0) {
						return "No text content";
				}
				string cleaned = Utils.collapse_whitespace(text_content.make_valid(-1));
				if(cleaned.char_count() > 120) {
						int byte_offset = cleaned.index_of_nth_char(120);
						return cleaned.substring(0, byte_offset) + "…";
				}
				return cleaned;
		}

		static construct {
				set_table("image_entry");
				set_primary_key("id");
				set_unique("path");
		}
}

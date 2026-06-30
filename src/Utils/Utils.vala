// Utility functions for Recollect.
// Contains shared helpers for MIME type detection, file classification, etc.
public class Utils : Object {

// Supported image file extensions (lowercase, no dot).
		public const string[] SUPPORTED_IMAGE_EXTENSIONS = {
				"png", "jpg", "jpeg", "tiff", "tif", "bmp", "webp", "gif",
				"avif", "heic", "heif", "jxl", "svg"
		};

		public static bool is_supported_image_path(string path) {
				string name = path.down();
				foreach(unowned string ext in SUPPORTED_IMAGE_EXTENSIONS) {
						if(name.has_suffix(".%s".printf(ext))) {
								return true;
						}
				}
				return false;
		}

		public static string guess_mime_type(string path) {
				string ext = path.down();
				if(ext.has_suffix(".png")) return "image/png";
				if(ext.has_suffix(".jpg") || ext.has_suffix(".jpeg")) return "image/jpeg";
				if(ext.has_suffix(".tiff") || ext.has_suffix(".tif")) return "image/tiff";
				if(ext.has_suffix(".bmp")) return "image/bmp";
				if(ext.has_suffix(".webp")) return "image/webp";
				if(ext.has_suffix(".gif")) return "image/gif";
				if(ext.has_suffix(".avif")) return "image/avif";
				if(ext.has_suffix(".heic") || ext.has_suffix(".heif")) return "image/heic";
				if(ext.has_suffix(".jxl")) return "image/jxl";
				if(ext.has_suffix(".svg")) return "image/svg+xml";
				return "application/octet-stream";
		}

		public static string mime_type_display_name(string mime_type) {
				switch(mime_type) {
						case "image/png": return _("PNG");
						case "image/jpeg": return _("JPEG");
						case "image/tiff": return _("TIFF");
						case "image/bmp": return _("BMP");
						case "image/webp": return _("WebP");
						case "image/gif": return _("GIF");
						case "image/avif": return _("AVIF");
						case "image/heic": return _("HEIC");
						case "image/jxl": return _("JPEG XL");
						case "image/svg+xml": return _("SVG");
						default: return mime_type;
				}
		}

		public static string format_file_size(int64 size) {
				if(size < 1024) {
						return _("%lld bytes").printf(size);
				} else if(size < 1048576) {
						return _("%.1f KB").printf((double) size / 1024.0);
				} else if(size < 1073741824) {
						return _("%.1f MB").printf((double) size / 1048576.0);
				} else {
						return _("%.1f GB").printf((double) size / 1073741824.0);
				}
		}

// Normalize whitespace: collapse newlines, tabs, and runs of spaces
// into single spaces. Uses a manual uint8 buffer instead of Vala's
// StringBuilder to avoid heap corruption from builder.str.strip().
		public static string collapse_whitespace(string raw) {
				if(raw == null || raw.length == 0) return "";
				// Pre-allocate output buffer(worst case: same size as input)
				uint8[] buf = new uint8[raw.length];
				int j = 0;
				bool in_space = false;
				unichar c;
				for(int i = 0; raw.get_next_char(ref i, out c);) {
						if(c == '\r' || c == '\n' || c.isspace()) {
								if(!in_space && j > 0) {
										buf[j++] =(uint8) ' ';
										in_space = true;
								}
						} else {
								// Encode unichar as UTF-8 into the buffer
								if(c < 0x80) {
										buf[j++] =(uint8) c;
								} else if(c < 0x800) {
										buf[j++] =(uint8)(0xC0 |(c >> 6));
										buf[j++] =(uint8)(0x80 |(c & 0x3F));
								} else if(c < 0x10000) {
										buf[j++] =(uint8)(0xE0 |(c >> 12));
										buf[j++] =(uint8)(0x80 |((c >> 6) & 0x3F));
										buf[j++] =(uint8)(0x80 |(c & 0x3F));
								} else {
										buf[j++] =(uint8)(0xF0 |(c >> 18));
										buf[j++] =(uint8)(0x80 |((c >> 12) & 0x3F));
										buf[j++] =(uint8)(0x80 |((c >> 6) & 0x3F));
										buf[j++] =(uint8)(0x80 |(c & 0x3F));
								}
								in_space = false;
						}
				}
				// Trim leading space
				int start = 0;
				if(j > 0 && buf[0] == ' ') start = 1;
				// Trim trailing space
				int len = j - start;
				if(len > 0 && buf[start + len - 1] == ' ') len--;
				// Null-terminate in buffer
				if(start + len < buf.length) buf[start + len] = 0;
				return(string) buf[start:start + len + 1];
		}
}
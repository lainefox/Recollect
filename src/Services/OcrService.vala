// OcrService — Tesseract OCR via the C API.
// One persistent BaseAPI per language/accuracy pair, reused across
// all calls. GdkPixbuf loads images; no Leptonica dependency.
public class OcrService : Object {
		private Tesseract.BaseAPI? api = null;
		private Mutex ocr_mutex = Mutex();
		private string current_language = "eng";
		private string current_accuracy = "balanced";

		public OcrService() {
		}

		// Tesseract can emit invalid UTF-8 in edge cases (binary artifacts, etc.)
		private string sanitize_utf8(string raw) {
				return raw.make_valid(-1);
		}

		// Collapse newlines and multiple spaces into single space for stored text
		private string normalize_whitespace(string raw) {
				return Utils.collapse_whitespace(raw);
		}

		// Resolve the tessdata directory containing .traineddata files.
		// Tries user-downloaded models, TESSDATA_PREFIX env var,
		// system path, then falls back to Tesseract's compiled-in default.
		private string? resolve_tessdata_path() {
				// 1. User-downloaded models (check base path and tessdata/ subdir)
				string user_models = Path.build_filename(
						Environment.get_user_data_dir(),
						Config.APPLICATION_ID,
						"models"
				);
				string user_tessdata = Path.build_filename(user_models, "tessdata");
				if(FileUtils.test(user_tessdata, FileTest.IS_DIR)) {
						return user_tessdata;
				}
				if(FileUtils.test(user_models, FileTest.IS_DIR)) {
						return user_models;
				}

				// 2. TESSDATA_PREFIX environment variable
				string? env_prefix = Environment.get_variable("TESSDATA_PREFIX");
				if(env_prefix != null && FileUtils.test(env_prefix, FileTest.IS_DIR)) {
						return env_prefix;
				}

				// 3. System tessdata (Arch Linux and most distros)
				if(FileUtils.test("/usr/share/tessdata", FileTest.IS_DIR)) {
						return "/usr/share/tessdata";
				}

				// 4. Let Tesseract use its compiled-in default
				return null;
		}

		public bool initialize(string language, string accuracy) {
				current_language = language;
				current_accuracy = accuracy;

		// Clean up previous instance if re-initializing.
				// api is [Compact] with free_function=TessBaseAPIDelete,
				// so api = null calls delete() automatically. Explicit
				// api.delete() followed by api = null would double-free.
				if(api != null) {
						api.end();
						api = null;
				}

				api = Tesseract.BaseAPI.create();
				if(api == null) {
						warning("[OCR] Failed to create Tesseract BaseAPI");
						return false;
				}

				string? datapath = resolve_tessdata_path();
				int rc = api.init(datapath, language);
				if(rc != 0) {
						warning("[OCR] Tesseract init failed for language '%s' with datapath '%s'", language, datapath ?? "(null)");
						api = null;
						return false;
				}

				// Set PSM based on accuracy setting
				Tesseract.PageSegMode psm = Tesseract.PageSegMode.AUTO;
				switch(accuracy) {
						case "fast":
								psm = Tesseract.PageSegMode.SINGLE_BLOCK;
								break;
						case "balanced":
						case "best":
						default:
								psm = Tesseract.PageSegMode.AUTO;
								break;
				}
				api.set_page_seg_mode(psm);

				// Suppress Tesseract's internal debug output (resolution
				// estimation, diacritic counts, etc.) from going to stderr.
				api.set_variable("debug_file", "/dev/null");

				return true;
		}

		// Extract text from an image file using the Tesseract C API.
		// Loads the image via GdkPixbuf, passes raw pixel data to Tesseract,
		// and returns the recognized text. Thread-safe via internal Mutex.
		// Redirects stderr to /dev/null during Tesseract calls to suppress
		// Leptonica internal diagnostics (boxClipToRectangle, etc.).
		public string extract_text(string filepath) {
				if(api == null) {
						return "";
				}

				var file = File.new_for_path(filepath);
				if(!file.query_exists()) {
						return "";
				}

				// Load image via GdkPixbuf (handles PNG, JPEG, TIFF, BMP, GIF, WebP)
				Gdk.Pixbuf? pixbuf = null;
				try {
						pixbuf = new Gdk.Pixbuf.from_file(filepath);
				} catch(Error e) {
						return "";
				}
				if(pixbuf == null) {
						return "";
				}

				int width = pixbuf.get_width();
				int height = pixbuf.get_height();
				int rowstride = pixbuf.get_rowstride();
				int n_channels = pixbuf.get_n_channels();
				unowned uint8[] pixels = pixbuf.get_pixels();

				// Serialize access to the shared BaseAPI instance
				ocr_mutex.lock();

				// Redirect stderr → /dev/null to suppress Tesseract/Leptonica
				// diagnostic noise (boxClipToRectangle, pixScanForForeground, etc.)
				int saved_stderr = Posix.dup(2);
				int devnull = Posix.open("/dev/null", Posix.O_WRONLY);
				Posix.dup2(devnull, 2);
				Posix.close(devnull);

				api.set_image(pixels, width, height, n_channels, rowstride);

				int rc = api.recognize();

				string result = "";
				if(rc == 0) {
						// get_utf8_text() returns newly allocated memory — caller must
						// free via TessDeleteText(). Copy into Vala-managed string first.
						unowned string? raw = api.get_utf8_text();
						string copy = (raw != null) ? (!) raw : "";
						if(raw != null) {
								Tesseract.delete_text(raw);
						}
						result = normalize_whitespace(sanitize_utf8(copy.strip()));
				}

				api.clear();

				// Restore stderr before releasing the lock
				Posix.dup2(saved_stderr, 2);
				Posix.close(saved_stderr);

				ocr_mutex.unlock();

				return result;
		}

		public void cleanup() {
				if(api != null) {
						api.end();
						api = null;
				}
		}

		~OcrService() {
				cleanup();
		}
}

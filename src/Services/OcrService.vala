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
		// Prefers a datapath that contains ALL requested languages so a
		// language like chi_sim (system-only) isn't silently dropped when
		// the user models dir only has eng.
		private string? resolve_tessdata_path(string language) {
				string[] candidates = {};

				// 1. User-downloaded models — variant subdirs first, then the
				//    base dir (legacy direct placement).
				string user_models = Path.build_filename(
						Environment.get_user_data_dir(),
						Config.APPLICATION_ID,
						"models"
				);
				string[] variant_dirs = { "tessdata", "tessdata_fast", "tessdata_best" };
				foreach(unowned string variant in variant_dirs) {
						string p = Path.build_filename(user_models, variant);
						if(FileUtils.test(p, FileTest.IS_DIR)) {
								candidates += p;
						}
				}
				if(FileUtils.test(user_models, FileTest.IS_DIR)) {
						candidates += user_models;
				}

				// 2. TESSDATA_PREFIX environment variable
				string? env_prefix = Environment.get_variable("TESSDATA_PREFIX");
				if(env_prefix != null && FileUtils.test(env_prefix, FileTest.IS_DIR)) {
						candidates += env_prefix;
				}

				// 3. System tessdata (Arch Linux and most distros) — unless
				//    --no-system-models was passed.
				bool no_system_models = Environment.get_variable("RECOLLECT_NO_SYSTEM_MODELS") == "1";
				if(!no_system_models && FileUtils.test("/usr/share/tessdata", FileTest.IS_DIR)) {
						candidates += "/usr/share/tessdata";
				}

				// Prefer the first candidate that has every requested language.
				// This keeps e.g. chi_sim+eng working when the user models dir
				// only contains eng but the system dir has both.
				foreach(unowned string candidate in candidates) {
						if(datapath_has_languages(candidate, language)) {
								return candidate;
						}
				}

				// Fall back to the first candidate (best effort).
				return candidates.length > 0 ? candidates[0] : null;
		}

		// True if the datapath contains a .traineddata file for every language
		// in the "+"-separated language list.
		private bool datapath_has_languages(string datapath, string language) {
				foreach(unowned string lang in language.split("+")) {
						string trimmed = lang.strip();
						if(trimmed.length == 0) continue;
						string traineddata = Path.build_filename(datapath, trimmed + ".traineddata");
						if(!FileUtils.test(traineddata, FileTest.EXISTS)) {
								return false;
						}
				}
				return true;
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

				string? datapath = resolve_tessdata_path(language);

				// Suppress Tesseract's stderr noise during init. When a language
				// in the list is missing from the datapath, Tesseract prints
				// "Error opening data file ... / Failed loading language '...'"
				// but still falls back to the languages it can load — so the
				// message is misleading. Real failures are logged below.
				int saved_stderr = Posix.dup(2);
				int devnull = Posix.open("/dev/null", Posix.O_WRONLY);
				Posix.dup2(devnull, 2);
				Posix.close(devnull);

				int rc = api.init(datapath, language);

				Posix.dup2(saved_stderr, 2);
				Posix.close(saved_stderr);

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

// TesseractModelService — manages downloadable Tesseract OCR models.
// Fetches model metadata from the tesseract-ocr GitHub repositories,
// downloads quality variants, deletes user-installed models, and tracks
// which variants are currently installed in the user's data directory.
public class TesseractModelService : Object {
		public signal void models_loaded(GenericArray<TesseractModel> language_models, GenericArray<TesseractModel> script_models);
		public signal void load_failed(string error);
		public signal void download_started(string code, string variant);
		public signal void download_progress(string code, string variant, double progress);
		public signal void download_completed(string code, string variant);
		public signal void download_failed(string code, string variant, string error);
		public signal void model_deleted(string code);

		private GenericArray<TesseractModel> language_models = new GenericArray<TesseractModel>();
		private GenericArray<TesseractModel> script_models = new GenericArray<TesseractModel>();
		private HashTable<string, bool> downloading_codes = new HashTable<string, bool>(str_hash, str_equal);

		private const string API_BASE = "https://api.github.com/repos/tesseract-ocr";
		private const string[] MODEL_VARIANTS = { "fast", "balanced", "best" };

		public TesseractModelService() {
		}

		public GenericArray<TesseractModel> get_language_models() {
				return language_models;
		}

		public GenericArray<TesseractModel> get_script_models() {
				return script_models;
		}

		public bool is_downloading(string code) {
				return downloading_codes.contains(code);
		}

		public string? get_installed_variant(string code) {
				string base_dir = get_user_models_dir();
				foreach(string variant in MODEL_VARIANTS) {
						string path = Path.build_filename(base_dir, variant_subdir_name(variant), code + ".traineddata");
						if(FileUtils.test(path, FileTest.EXISTS)) {
								return variant;
						}
				}
				return null;
		}

		public TesseractModel? find_model(string code) {
				for(uint i = 0; i < language_models.length; i++) {
						if(language_models.get(i).code == code) return language_models.get(i);
				}
				for(uint i = 0; i < script_models.length; i++) {
						if(script_models.get(i).code == code) return script_models.get(i);
				}
				return null;
		}

		public TesseractModelVariant? find_variant(TesseractModel model, string variant_name) {
				for(uint i = 0; i < model.variants.length; i++) {
						TesseractModelVariant v = model.variants.get(i);
						if(v.name == variant_name) return v;
				}
				return null;
		}

		// ---- Static model list cache(avoids hitting GitHub API rate limit) ----
		private static GenericArray<TesseractModel> cached_language_models = new GenericArray<TesseractModel>();
		private static GenericArray<TesseractModel> cached_script_models = new GenericArray<TesseractModel>();
		private static int64 cache_load_time = 0;
		private const int64 CACHE_TTL_SEC = 3600; // 1 hour

// Return cached models if still fresh, or null to force a network fetch.
		private bool use_cached_models() {
				int64 now = get_real_time() / 1000000L;
				return(cache_load_time > 0 && now - cache_load_time < CACHE_TTL_SEC
								&& cached_language_models.length > 0);
		}

// Fetch model lists from GitHub in a background thread and emit models_loaded.
		public void load_models() {
				// If we already have fresh in-memory cached data, emit it immediately.
				if(use_cached_models()) {
						copy_cache_to_local();
						Idle.add(() => {
								models_loaded(language_models, script_models);
								return Source.REMOVE;
						});
						return;
				}

				// Try the on-disk cache first — it survives app restarts.
				if(try_serve_disk_cache()) return;

				if(!NetworkMonitor.get_default().get_network_available()) {
						Idle.add(() => {
								load_failed(_("No Internet Connection"));
								return Source.REMOVE;
						});
						return;
				}

				string?[] fetch_results = new string?[MODEL_VARIANTS.length * 2];
				string? fetch_error = null;

				try {
						new Thread<void*>.try("fetch-models",() => {
								try {
										var session = new Soup.Session();
										int idx = 0;
										foreach(string variant in MODEL_VARIANTS) {
												fetch_results[idx++] = fetch_url_sync(session, api_url(variant, false));
										}
										foreach(string variant in MODEL_VARIANTS) {
												fetch_results[idx++] = fetch_url_sync(session, api_url(variant, true));
										}
								} catch(Error err) {
										fetch_error = err.message;
								}

								Idle.add(() => {
										if(fetch_error != null) {
												// Try in-memory cache first, then disk cache.
												if(use_cached_models()) {
														copy_cache_to_local();
														models_loaded(language_models, script_models);
												} else if(try_serve_disk_cache()) {
														// served by try_serve_disk_cache
												} else {
														load_failed((!) fetch_error);
												}
										} else {
												try {
														parse_models(
																fetch_results[0], fetch_results[1], fetch_results[2],
																fetch_results[3], fetch_results[4], fetch_results[5]
														);
														// Update static cache and persist to disk.
														update_cache_from_local();
														save_disk_cache(fetch_results);
														models_loaded(language_models, script_models);
												} catch(Error err) {
														// Parsing failed — serve stale cache if available.
														if(use_cached_models() || try_serve_disk_cache()) {
																// already served by try_serve_disk_cache
														} else {
																load_failed(err.message);
														}
												}
										}
										return Source.REMOVE;
								});
								return null;
						});
				} catch(Error err) {
						// Thread creation failed — serve cache if available.
						if(use_cached_models()) {
								copy_cache_to_local();
								models_loaded(language_models, script_models);
						} else if(try_serve_disk_cache()) {
								// served by try_serve_disk_cache
						} else {
								load_failed(err.message);
						}
				}
		}

		private void copy_cache_to_local() {
				language_models = new GenericArray<TesseractModel>();
				for(uint i = 0; i < cached_language_models.length; i++) {
						var model = cached_language_models.get(i);
						model.installed_variant = get_installed_variant(model.code);
						language_models.add(model);
				}
				script_models = new GenericArray<TesseractModel>();
				for(uint i = 0; i < cached_script_models.length; i++) {
						var model = cached_script_models.get(i);
						model.installed_variant = get_installed_variant(model.code);
						script_models.add(model);
				}
		}

		private void update_cache_from_local() {
				cached_language_models = new GenericArray<TesseractModel>();
				for(uint i = 0; i < language_models.length; i++) {
						cached_language_models.add(language_models.get(i));
				}
				cached_script_models = new GenericArray<TesseractModel>();
				for(uint i = 0; i < script_models.length; i++) {
						cached_script_models.add(script_models.get(i));
				}
				cache_load_time = get_real_time() / 1000000L;
		}

// Download a specific variant for a model.
		public void download_model(string code, string variant_name) {
				if(downloading_codes.contains(code)) return;

				TesseractModel? model = find_model(code);
				if(model == null) return;

				TesseractModelVariant? variant = find_variant(model, variant_name);
				if(variant == null) return;

				downloading_codes.insert(code, true);
				download_started(code, variant_name);

				string base_dir = get_user_models_dir();
				string data_path = Path.build_filename(base_dir, variant_subdir_name(variant_name), code + ".traineddata");
				string data_dir = Path.get_dirname(data_path);

				try {
						if(DirUtils.create_with_parents(data_dir, 0755) != 0) {
								throw new FileError.FAILED("Failed to create directory: %s", data_dir);
						}
				} catch(FileError e) {
						downloading_codes.remove(code);
						download_failed(code, variant_name, e.message);
						return;
				}

				try {
						new Thread<void*>.try("download-model",() => {
								try {
										download_variant_sync(code, variant_name, variant.download_url, data_path);

										Idle.add(() => {
												downloading_codes.remove(code);
												download_completed(code, variant_name);
												return Source.REMOVE;
										});
								} catch(Error err) {
										string error_message = err.message;
										Idle.add(() => {
												downloading_codes.remove(code);
												download_failed(code, variant_name, error_message);
												return Source.REMOVE;
										});
								}
								return null;
						});
				} catch(Error err) {
						downloading_codes.remove(code);
						download_failed(code, variant_name, err.message);
				}
		}

// Delete a user-installed model.
		public void delete_model(string code) {
				string base_dir = get_user_models_dir();
				try {
						foreach(string variant in MODEL_VARIANTS) {
								string path = Path.build_filename(base_dir, variant_subdir_name(variant), code + ".traineddata");
								var file = File.new_for_path(path);
								if(file.query_exists()) {
										file.delete();
								}
						}
				} catch(Error e) {
						warning("Failed to delete model %s: %s", code, e.message);
						return;
				}

				model_deleted(code);
		}

		private void download_variant_sync(
				string code,
				string variant_name,
				string download_url,
				string data_path
		) throws Error {
				var session = new Soup.Session();
				var message = new Soup.Message("GET", download_url);
				message.request_headers.append("User-Agent", "Recollect/0.1");

				InputStream stream = session.send(message, null);

				if(message.status_code != 200) {
						string detail;
						if(message.status_code == 403) {
								detail = _("Download denied(403). The model file may not be available.");
						} else if(message.status_code == 404) {
								detail = _("Model file not found(404). It may have been removed.");
						} else {
								detail = "HTTP %u %s".printf(message.status_code, message.reason_phrase);
						}
						throw new IOError.FAILED(detail);
				}

				int64 content_length = message.response_headers.get_content_length();

				string tmp_path = data_path + ".part";
				var tmp_file = File.new_for_path(tmp_path);
				var output_stream = tmp_file.replace(null, false, FileCreateFlags.REPLACE_DESTINATION, null);

				uint8[] buffer = new uint8[8192];
				ssize_t bytes_read;
				int64 total_read = 0;
				int last_percent = -1;

				while((bytes_read = stream.read(buffer, null)) > 0) {
						output_stream.write(buffer[0:bytes_read], null);
						total_read += bytes_read;

						int percent = content_length > 0 ?(int)(total_read * 100 / content_length) : 0;
						if(percent != last_percent) {
								last_percent = percent;
								Idle.add(() => {
										download_progress(code, variant_name, percent / 100.0);
										return Source.REMOVE;
								});
						}
				}

				output_stream.close(null);
				stream.close(null);

				var dest_file = File.new_for_path(data_path);
				tmp_file.move(dest_file, FileCopyFlags.OVERWRITE, null, null);
		}

		private string fetch_url_sync(Soup.Session session, string url) throws Error {
				var message = new Soup.Message("GET", url);
				message.request_headers.append("User-Agent", "Recollect/0.1");
				message.request_headers.append("Accept", "application/vnd.github+json");

				Bytes bytes = session.send_and_read(message, null);

				if(message.status_code != 200) {
						string detail;
						if(message.status_code == 403) {
								detail = _("GitHub API rate limit reached. Please wait a while before trying again.");
						} else if(message.status_code == 301 || message.status_code == 302) {
								detail = _("Redirect not followed.");
						} else {
								detail = "HTTP %u %s".printf(message.status_code, message.reason_phrase);
						}
						throw new IOError.FAILED(detail);
				}

				return(string) bytes.get_data();
		}

		private void parse_models(
				string lang_fast_json,
				string lang_balanced_json,
				string lang_best_json,
				string script_fast_json,
				string script_balanced_json,
				string script_best_json
		) throws Error {
				var lang_table = new HashTable<string, TesseractModel>(str_hash, str_equal);
				var script_table = new HashTable<string, TesseractModel>(str_hash, str_equal);

				parse_model_array(lang_fast_json, false, "fast", lang_table);
				parse_model_array(lang_balanced_json, false, "balanced", lang_table);
				parse_model_array(lang_best_json, false, "best", lang_table);

				parse_model_array(script_fast_json, true, "fast", script_table);
				parse_model_array(script_balanced_json, true, "balanced", script_table);
				parse_model_array(script_best_json, true, "best", script_table);

				language_models = hash_table_to_array(lang_table);
				script_models = hash_table_to_array(script_table);

				language_models.sort((CompareFunc) compare_model);
				script_models.sort((CompareFunc) compare_model);
		}

		private void parse_model_array(
				string json,
				bool is_script_dir,
				string variant_name,
				HashTable<string, TesseractModel> table
		) throws Error {
				var parser = new Json.Parser();
				parser.load_from_data(json);

				var root = parser.get_root();
				if(root == null || root.get_node_type() != Json.NodeType.ARRAY) {
						throw new IOError.FAILED(_("Invalid response from GitHub API"));
				}

				var array = root.get_array();
				foreach(var element in array.get_elements()) {
						var obj = element.get_object();
						string type = obj.get_string_member("type");
						string name = obj.get_string_member("name");

						if(type != "file" || !name.has_suffix(".traineddata")) continue;

						string base_name = name.substring(0, name.length - ".traineddata".length);
						string code = is_script_dir ? "script/" + base_name : base_name;
						int64 size = obj.get_int_member("size");

						// Skip utility models in the language directory
						if(!is_script_dir &&(code == "osd" || code == "equ")) continue;

						if(!obj.has_member("download_url")) continue;
						unowned string download_url = obj.get_string_member("download_url");
						if(download_url == null || download_url == "") continue;

						TesseractModel? existing = table.lookup(code);
						if(existing == null) {
								var model = new TesseractModel(
										code,
										PreferencesDialog.get_language_display_name(code)
								);
								model.installed_variant = get_installed_variant(code);
								model.add_variant(new TesseractModelVariant(variant_name, size, download_url));
								table.insert(code, model);
						} else {
								existing.add_variant(new TesseractModelVariant(variant_name, size, download_url));
						}
				}
		}

		private static int compare_model(TesseractModel a, TesseractModel b) {
				return strcmp(a.code, b.code);
		}

		private GenericArray<TesseractModel> hash_table_to_array(HashTable<string, TesseractModel> table) {
				var array = new GenericArray<TesseractModel>();
				var iter = HashTableIter<string, TesseractModel>(table);
				string? key = null;
				TesseractModel? value = null;
				while(iter.next(out key, out value)) {
						if(value != null) {
								array.add(value);
						}
				}
				return array;
		}

		private string variant_repo_name(string variant_name) {
				switch(variant_name) {
						case "fast": return "tessdata_fast";
						case "best": return "tessdata_best";
						case "balanced":
						default: return "tessdata";
				}
		}

		private string api_url(string variant_name, bool script) {
				string url = API_BASE + "/" + variant_repo_name(variant_name) + "/contents";
				if(script) url += "/script";
				return url;
		}

		private string get_user_models_dir() {
				return Path.build_filename(Environment.get_user_data_dir(), Config.APPLICATION_ID, "models");
		}

		private string get_cache_dir() {
				return Path.build_filename(Environment.get_user_cache_dir(), Config.APPLICATION_ID);
		}

		private string get_disk_cache_path() {
				return Path.build_filename(get_cache_dir(), "models-cache.json");
		}

// Try to serve models from the on-disk cache. Returns true if cached
// data was successfully loaded and emitted.
		private bool try_serve_disk_cache() {
				string cache_path = get_disk_cache_path();
				if(!FileUtils.test(cache_path, FileTest.EXISTS)) return false;

				try {
						string content;
						FileUtils.get_contents(cache_path, out content);

						var parser = new Json.Parser();
						parser.load_from_data(content);

						var root = parser.get_root();
						if(root == null || root.get_node_type() != Json.NodeType.OBJECT) return false;

						var obj = root.get_object();
						int64 timestamp = obj.get_int_member("timestamp");
						int64 now = get_real_time() / 1000000L;

						// Cache valid for 1 hour.
						if(now - timestamp > CACHE_TTL_SEC) return false;

						string? lang_fast = obj.get_string_member("lang_fast");
						string? lang_balanced = obj.get_string_member("lang_balanced");
						string? lang_best = obj.get_string_member("lang_best");
						string? script_fast = obj.get_string_member("script_fast");
						string? script_balanced = obj.get_string_member("script_balanced");
						string? script_best = obj.get_string_member("script_best");

						if(lang_fast == null || lang_balanced == null || lang_best == null ||
								script_fast == null || script_balanced == null || script_best == null) {
								return false;
						}

						parse_models(lang_fast, lang_balanced, lang_best,
													script_fast, script_balanced, script_best);
						update_cache_from_local();

						Idle.add(() => {
								models_loaded(language_models, script_models);
								return Source.REMOVE;
						});
						return true;
				} catch(Error e) {
						warning("Failed to load disk model cache: %s", e.message);
						return false;
				}
		}

// Persist the raw API responses to disk so they survive app restarts.
		private void save_disk_cache(string?[] fetch_results) {
				try {
						DirUtils.create_with_parents(get_cache_dir(), 0755);
				} catch(FileError e) {
						warning("Failed to create cache directory: %s", e.message);
						return;
				}

				var builder = new Json.Builder();
				builder.begin_object();

				builder.set_member_name("timestamp");
				builder.add_int_value(get_real_time() / 1000000L);

				string[] names = { "lang_fast", "lang_balanced", "lang_best",
													 "script_fast", "script_balanced", "script_best" };
				for(int i = 0; i < names.length && i < fetch_results.length; i++) {
						builder.set_member_name(names[i]);
						if(fetch_results[i] != null) {
								builder.add_string_value((!) fetch_results[i]);
						} else {
								builder.add_string_value("");
						}
				}

				builder.end_object();

				var generator = new Json.Generator();
				generator.set_root(builder.get_root());
				try {
						string cache_path = get_disk_cache_path();
						FileUtils.set_contents(cache_path, generator.to_data(null));
				} catch(FileError e) {
						warning("Failed to write model cache: %s", e.message);
				}
		}

		private static string variant_subdir_name(string variant_name) {
				switch(variant_name) {
						case "fast": return "tessdata_fast";
						case "best": return "tessdata_best";
						case "balanced":
						default: return "tessdata";
				}
		}
}

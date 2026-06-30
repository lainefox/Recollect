public class DatabaseService : Object {
		private Gom.Repository repository;
		private Gom.Adapter adapter;
		private File db_file;

		public signal void database_ready();
		public signal void error_occurred(string message);
		public signal void folders_changed();

		public DatabaseService() {
				var cache_dir = Path.build_filename(Environment.get_user_cache_dir(), Config.APPLICATION_ID);
				db_file = File.new_for_path(Path.build_filename(cache_dir, "recollect.db"));

				if(!db_file.get_parent().query_exists()) {
						try {
								db_file.get_parent().make_directory_with_parents();
						} catch(Error e) {
								error_occurred("Failed to create database directory: %s".printf(e.message));
						}
				}
		}

// Initialize the database, create tables from models.
// Uses Gom.Adapter.open_sync() and automatic_migrate_sync().
		public void init_sync() {
				try {
						adapter = new Gom.Adapter();
						adapter.open_sync(db_file.get_path());

						repository = new Gom.Repository(adapter);

						// Verify the repository was created correctly
						if(repository == null) {
								error_occurred("Database initialization failed: repository is null after creation");
								return;
						}

						var types = new GLib.List<GLib.Type>();
						types.append(typeof(ImageEntry));
						types.append(typeof(Folder));

						if(!repository.automatic_migrate_sync(1,(owned) types)) {
								error_occurred("Database migration failed");
								repository = null;
								return;
						}

						database_ready();

						// Open separate SQLite handle for deletes — Gom's GTask
						// machinery has a use-after-free bug (SIGSEGV) when
						// delete_sync is called from a file-monitor callback.
						open_raw_sqlite();

						// Purge entries with invalid paths that could have been
						// saved by previous versions with file-monitor races.
						// Without this, garbled entries persist in search results.
						cleanup_invalid_paths();
				} catch(GLib.Error e) {
						error_occurred("Database initialization failed: %s".printf(e.message));
				}
		}

		public unowned Gom.Repository? get_repository() {
				return repository;
		}

		public ImageEntry? get_image_by_id(int64 id) {
				if(repository == null) return null;
				try {
						var dummy = new ImageEntry();
						return repository.find_one_sync(dummy.get_type(), null) as ImageEntry;
				} catch(GLib.Error e) {
						warning("Error getting image by id: %s", e.message);
						return null;
				}
		}

		// Search images with optional text query, sort, pagination, and date filter.
// All queries now use raw SQLite — this avoids Gom's ResourceGroup caching
// inconsistencies when writes happen through the separate raw SQL connection,
// and prevents OOM/stack-overflow crashes from loading all results into memory.
		// Load ALL matching images (no pagination). GTK ColumnView/GridView
		// virtualize rendering — only visible rows create widgets. Loading
		// thousands of items into the model is O(1) from GTK's perspective.
		public ImageEntry[]? search_images(string query, bool match_case = false,
																				bool whole_words = false,
																				SortCriteria sort_criteria = SortCriteria.DATE,
																				SortDirection sort_direction = SortDirection.DESCENDING,
																				int64 date_from = 0, int64 date_to = 0) {
		if(raw_db ==(void*) null) return null;
				// limit=0 means "no limit" — returns all matching rows
				if(query.length == 0) {
						return query_raw_batch(0, 0, sort_criteria, sort_direction,
																	 date_from, date_to);
				} else {
						return query_text_batch(query, 0, 0, match_case, whole_words,
																		sort_criteria, sort_direction,
																		date_from, date_to);
				}
		}

// Query a text-filtered batch of images using raw SQL with LIKE/GLOB,
// ORDER BY, and LIMIT/OFFSET.  Does NOT load all results into memory —
// only the requested batch is fetched from SQLite.  This avoids the OOM
// and stack-overflow crashes that the old Gom-based "load all + quicksort"
// approach caused with thousands of images.
		private ImageEntry[]? query_text_batch(string query, int offset, int limit,
																					 bool match_case, bool whole_words,
																					 SortCriteria sort_criteria,
																					 SortDirection sort_direction,
																					 int64 date_from, int64 date_to) {
				if(raw_db ==(void*) null) return null;
				if(query.length == 0) return null;

				string escaped = query.replace("'", "''");
				string where_clause = "";
				if(whole_words) {
						if(match_case) {
								where_clause = "(\"text-content\" GLOB '* %s *' OR \"text-content\" GLOB '%s *' OR \"text-content\" GLOB '* %s' OR \"text-content\" = '%s')".printf(
										escaped, escaped, escaped, escaped);
						} else {
								string ql = escaped.down();
								where_clause = "(\"text-content\" LIKE '%% %s %%' OR \"text-content\" LIKE '%s %%' OR \"text-content\" LIKE '%% %s' OR \"text-content\" = '%s')".printf(
										ql, ql, ql, ql);
						}
				} else if(match_case) {
						where_clause = "\"text-content\" GLOB '*%s*'".printf(escaped);
				} else {
						where_clause = "\"text-content\" LIKE '%%%s%%'".printf(escaped.down());
				}

				if(date_from > 0 && date_to > 0) {
						where_clause += " AND \"file-created-at\" >= %s AND \"file-created-at\" <= %s".printf(
								date_from.to_string(), date_to.to_string());
				} else if(date_from > 0) {
						where_clause += " AND \"file-created-at\" >= %s".printf(date_from.to_string());
				} else if(date_to > 0) {
						where_clause += " AND \"file-created-at\" <= %s".printf(date_to.to_string());
				}

				string order_col = sort_criteria == SortCriteria.NAME
						? "\"path\""
						: "\"file-created-at\"";
				string order_dir = sort_direction == SortDirection.ASCENDING ? "ASC" : "DESC";

				// Get total count first
				string count_sql = "SELECT COUNT(*) FROM \"image_entry\" WHERE %s".printf(where_clause);
				void* stmt = null;
				int rc = sqlite3_prepare_v2(raw_db, count_sql, -1, out stmt, null);
				if(rc != 0) return null;
				int64 total = 0;
				if(sqlite3_step(stmt) == SQLITE_ROW) {
						total = sqlite3_column_int64(stmt, 0);
				}
				sqlite3_finalize(stmt);
				if(total == 0) return null;
				if(offset >=(int) total) return null;

				int fetch_count = limit > 0 ? int.min(limit,(int) total - offset) :(int) total - offset;

				string query_sql = "SELECT \"id\",\"path\",\"text-content\",\"scanned-at\","
						+ "\"file-created-at\",\"folder-id\",\"accuracy-level\",\"ocr-language\","
						+ "\"file-size\",\"mime-type\""
						+ " FROM \"image_entry\" WHERE %s ORDER BY %s %s LIMIT %d OFFSET %d".printf(
								where_clause, order_col, order_dir, fetch_count, offset);

				stmt = null;
				rc = sqlite3_prepare_v2(raw_db, query_sql, -1, out stmt, null);
				if(rc != 0) return null;

				var batch = new ImageEntry[fetch_count];
				int idx = 0;
				while(sqlite3_step(stmt) == SQLITE_ROW) {
						if(idx >= fetch_count) break;
						var entry = new ImageEntry();
						entry.id = sqlite3_column_int64(stmt, 0);
						entry.path =(sqlite3_column_text(stmt, 1) ?? "").make_valid(-1);
						entry.text_content =(sqlite3_column_text(stmt, 2) ?? "").make_valid(-1);
						entry.scanned_at = sqlite3_column_int64(stmt, 3);
						entry.file_created_at = sqlite3_column_int64(stmt, 4);
						entry.folder_id = sqlite3_column_int64(stmt, 5);
						entry.accuracy_level =(sqlite3_column_text(stmt, 6) ?? "").make_valid(-1);
						entry.ocr_language =(sqlite3_column_text(stmt, 7) ?? "").make_valid(-1);
						entry.file_size = sqlite3_column_int64(stmt, 8);
						entry.mime_type =(sqlite3_column_text(stmt, 9) ?? "").make_valid(-1);
						truncate_text_content(entry);
						batch[idx++] = entry;
				}
				sqlite3_finalize(stmt);

				if(idx < fetch_count) {
						batch.resize(idx);
				}
				return batch;
		}

// Truncate text_content to a short snippet to keep memory usage low.
// The full text is retrieved on demand via get_full_text_content().
		private void truncate_text_content(ImageEntry entry) {
				if(entry.text_content != null && entry.text_content.length > 200) {
						entry.text_content = entry.text_content.substring(0, 200) + "…";
				}
		}

// Retrieve an image's database ID by its file path.
// Uses raw SQLite on the separate connection.
// Returns -1 if not found.
		public int64 get_image_id_by_path(string path) {
				if(raw_db ==(void*) null) return -1;
				string safe_path = path.make_valid(-1).replace("'", "''");
				void* stmt = null;
				string sql = "SELECT \"id\" FROM \"image_entry\" WHERE \"path\" = '%s'".printf(safe_path);
				int rc = sqlite3_prepare_v2(raw_db, sql, -1, out stmt, null);
				if(rc != 0) return -1;
				int64 id = -1;
				if(sqlite3_step(stmt) == SQLITE_ROW) {
						id = sqlite3_column_int64(stmt, 0);
				}
				sqlite3_finalize(stmt);
				return id;
		}

// Retrieve the full OCR text for an image by its database ID.
// Uses raw SQLite on the separate connection — bypasses Gom entirely
// so it doesn't interfere with any active ResourceGroup cursors.
		public string? get_full_text_content(int64 id) {
				if(raw_db ==(void*) null) return null;
				void* stmt = null;
				string sql = "SELECT \"text-content\" FROM \"image_entry\" WHERE id = %s".printf(id.to_string());
				int rc = sqlite3_prepare_v2(raw_db, sql, -1, out stmt, null);
				if(rc != 0) {
						warning("get_full_text_content: prepare failed(rc=%d)", rc);
						return null;
				}
				string? result = null;
				if(sqlite3_step(stmt) == SQLITE_ROW) {
						result = sqlite3_column_text(stmt, 0);
				}
				sqlite3_finalize(stmt);
				return result != null ? result.make_valid(-1) : null;
		}

// Drop all in-memory caches to reduce background memory usage.
// When `upsert` is true and the image has no ID, uses a raw SQL upsert
//(INSERT … ON CONFLICT) that bypasses Gom entirely. This avoids data
// corruption from Gom's stale state after raw_db writes(deletions).
// Full scans should pass `upsert=false` because they pre-filter paths.
		public void save_image(ImageEntry image, bool upsert = false) {
				if(repository == null) return;
				// Sanitize all string fields before saving.
				if(image.text_content != null) {
						image.text_content = image.text_content.make_valid(-1);
				}
				if(image.path != null) {
						image.path = image.path.make_valid(-1);
				}
				if(image.accuracy_level != null) {
						image.accuracy_level = image.accuracy_level.make_valid(-1);
				}
				if(image.ocr_language != null) {
						image.ocr_language = image.ocr_language.make_valid(-1);
				}
				if(image.mime_type != null) {
						image.mime_type = image.mime_type.make_valid(-1);
				}

				if(image.path == null) return;

				// Reject paths that look invalid — no directory separator, or
				// too short to be a real file path. These would display as
				// garbled in the UI (filename looks wrong, path shows ".").
				if(!image.path.contains("/") || image.path.length < 10) {
						warning("[DatabaseService] Rejecting save with invalid path: '%s' (len=%d, has_slash=%s)",
										image.path, image.path.length, image.path.contains("/").to_string());
						return;
				}

				// Always use raw SQL — this keeps writes and subsequent reads on the
				// same connection, avoiding cross-connection visibility issues and
				// Gom's GTask use-after-free bug.
				save_image_raw_sync(image);
		}

// Insert or update an image using raw SQL(INSERT … ON CONFLICT).
// Avoids Gom's stale ResourceGroup state after raw_db writes.
		private void save_image_raw_sync(ImageEntry image) {
				if(raw_db ==(void*) null) return;
				string p =(image.path ?? "").replace("'", "''");
				string t =(image.text_content ?? "").replace("'", "''");
				string a =(image.accuracy_level ?? "").replace("'", "''");
				string o =(image.ocr_language ?? "").replace("'", "''");
				string m =(image.mime_type ?? "").replace("'", "''");
				string sql = "INSERT INTO \"image_entry\" "
						+ "(\"path\",\"text-content\",\"scanned-at\",\"file-created-at\","
						+ "\"folder-id\",\"accuracy-level\",\"ocr-language\",\"file-size\",\"mime-type\") "
						+ "VALUES('" + p + "','" + t + "',"
						+ image.scanned_at.to_string() + ","
						+ image.file_created_at.to_string() + ","
						+ image.folder_id.to_string() + ",'"
						+ a + "','" + o + "',"
						+ image.file_size.to_string() + ",'" + m + "') "
						+ "ON CONFLICT(\"path\") DO UPDATE SET "
						+ "\"text-content\"=excluded.\"text-content\","
						+ "\"scanned-at\"=excluded.\"scanned-at\","
						+ "\"file-created-at\"=excluded.\"file-created-at\","
						+ "\"folder-id\"=excluded.\"folder-id\","
						+ "\"accuracy-level\"=excluded.\"accuracy-level\","
						+ "\"ocr-language\"=excluded.\"ocr-language\","
						+ "\"file-size\"=excluded.\"file-size\","
						+ "\"mime-type\"=excluded.\"mime-type\"";
				string? errmsg = null;
				int rc = sqlite3_exec(raw_db, sql, null, null, out errmsg);
				if(rc != 0) {
						warning("Error saving image via raw SQL: %s(rc=%d)", errmsg ?? "unknown", rc);
						if(errmsg != null) sqlite3_free((void*) errmsg);
						return;
				}
				// Retrieve the auto-assigned rowid so callers can reference this image
				image.id = sqlite3_last_insert_rowid(raw_db);
		}

// Create the ocr_model_used table if it doesn't exist.
// Each row records one OCR model(language) used on one image.
		private void ensure_ocr_model_table() {
				string sql = "CREATE TABLE IF NOT EXISTS \"ocr_model_used\"("
						+ "\"id\" INTEGER PRIMARY KEY AUTOINCREMENT,"
						+ "\"image-id\" INTEGER NOT NULL,"
						+ "\"model-name\" TEXT NOT NULL,"
						+ "\"accuracy-level\" TEXT NOT NULL,"
						+ "FOREIGN KEY(\"image-id\") REFERENCES \"image_entry\"(\"id\") ON DELETE CASCADE"
						+ ")";
				string? errmsg = null;
				int rc = sqlite3_exec(raw_db, sql, null, null, out errmsg);
				if(rc != 0) {
						warning("Failed to create ocr_model_used table: %s(rc=%d)", errmsg ?? "unknown", rc);
						if(errmsg != null) sqlite3_free((void*) errmsg);
				}
		}

// Save OCR model entries for an image. Splits the language string by "+"
// and creates one row per language + accuracy combination.
		public void save_ocr_models(int64 image_id, string language_string, string accuracy) {
				if(raw_db ==(void*) null) return;
				string[] langs = language_string.split("+");
				string safe_accuracy = accuracy.make_valid(-1).replace("'", "''");
				debug("[DatabaseService] save_ocr_models: image_id=%lld langs=%s acc=%s",
							 image_id, language_string, accuracy);
				foreach(string lang in langs) {
						string safe_lang = lang.make_valid(-1).replace("'", "''");
						string sql = "INSERT INTO \"ocr_model_used\" "
								+ "(\"image-id\",\"model-name\",\"accuracy-level\") "
								+ "VALUES(%s,'%s','%s')"
								.printf(image_id.to_string(), safe_lang, safe_accuracy);
						string? errmsg = null;
						int rc = sqlite3_exec(raw_db, sql, null, null, out errmsg);
						if(rc != 0) {
								warning("Failed to save OCR model '%s': %s(rc=%d)", safe_lang, errmsg ?? "unknown", rc);
								if(errmsg != null) sqlite3_free((void*) errmsg);
						}
				}
		}

// Retrieve OCR model entries for an image. Returns arrays of model names
// and accuracy levels, parallel arrays(same length).
		public void get_ocr_models(int64 image_id, out string[] names, out string[] accuracies) {
				names = new string[0];
				accuracies = new string[0];
				if(raw_db ==(void*) null) return;

				debug("[DatabaseService] get_ocr_models: image_id=%lld", image_id);

				void* stmt = null;
				string sql = "SELECT \"model-name\",\"accuracy-level\" FROM \"ocr_model_used\" "
						+ "WHERE \"image-id\" = %s ORDER BY \"id\"".printf(image_id.to_string());
				int rc = sqlite3_prepare_v2(raw_db, sql, -1, out stmt, null);
				if(rc != 0) return;

				var n = new List<string>();
				var a = new List<string>();
				while(sqlite3_step(stmt) == SQLITE_ROW) {
						string? nm = sqlite3_column_text(stmt, 0);
						string? ac = sqlite3_column_text(stmt, 1);
						n.append(nm != null ? nm.make_valid(-1) : "");
						a.append(ac != null ? ac.make_valid(-1) : "");
				}
				sqlite3_finalize(stmt);

				names = new string[n.length()];
				accuracies = new string[a.length()];
				int i = 0;
				foreach(unowned string name in n) {
						names[i++] = name;
				}
				i = 0;
				foreach(unowned string acc in a) {
						accuracies[i++] = acc;
				}
		}

// Load an existing ImageEntry by its unique path.
		private ImageEntry? find_image_by_path(string path) {
				if(repository == null) return null;
				try {
						var group = repository.find_sync(typeof(ImageEntry), null);
						if(group == null || group.get_count() == 0) return null;

						group.fetch_sync(0, group.get_count());
						for(uint i = 0; i < group.get_count(); i++) {
								var res = group.get(i);
								if(res == null) continue;
								var img = res as ImageEntry;
								if(img != null && img.path == path) {
										return img;
								}
						}
				} catch(GLib.Error e) {
						warning("Error finding image by path: %s", e.message);
				}
				return null;
		}

// Copy all mutable fields from one ImageEntry to another.
		private void copy_image_fields(ImageEntry src, ImageEntry dest) {
				dest.path = src.path;
				dest.text_content = src.text_content;
				dest.scanned_at = src.scanned_at;
				dest.file_created_at = src.file_created_at;
				dest.folder_id = src.folder_id;
				dest.accuracy_level = src.accuracy_level;
				dest.ocr_language = src.ocr_language;
				dest.file_size = src.file_size;
				dest.mime_type = src.mime_type;
		}

// Find the database ID for a configured folder path.
// Returns -1 if the folder is not found.
		public int64 get_folder_id(string folder_path) {
				refresh_folder_cache();
				if(cached_folders == null) return -1;
				foreach(var folder in cached_folders) {
						if(folder != null && folder.path == folder_path) {
								return folder.id;
						}
				}
				return -1;
		}

		// Direct SQLite C API declarations — used for a separate main-thread
		// connection that bypasses Gom's GTask machinery entirely, avoiding
		// the use-after-free bug(SIGSEGV in g_task_finalize) that strikes
		// when deleting from a file-monitor callback.
		[CCode(cname = "sqlite3_open_v2", cheader_filename = "sqlite3.h")]
		private static extern int sqlite3_open_v2(string filename, [CCode(type = "sqlite3 **")] out void* db, int flags, string? vfs);

		[CCode(cname = "sqlite3_exec", cheader_filename = "sqlite3.h")]
		private static extern int sqlite3_exec(void* db, string sql, void* callback, void* arg, out string? errmsg);

		[CCode(cname = "sqlite3_free", cheader_filename = "sqlite3.h")]
		private static extern void sqlite3_free(void* ptr);

		[CCode(cname = "sqlite3_prepare_v2", cheader_filename = "sqlite3.h")]
		private static extern int sqlite3_prepare_v2(void* db, string sql, int n_bytes, out void* stmt, void* tail);

		[CCode(cname = "sqlite3_step", cheader_filename = "sqlite3.h")]
		private static extern int sqlite3_step(void* stmt);

		[CCode(cname = "sqlite3_column_text", cheader_filename = "sqlite3.h")]
		private static extern unowned string sqlite3_column_text(void* stmt, int i_col);

		[CCode(cname = "sqlite3_column_int", cheader_filename = "sqlite3.h")]
		private static extern int sqlite3_column_int(void* stmt, int i_col);

		[CCode(cname = "sqlite3_column_int64", cheader_filename = "sqlite3.h")]
		private static extern int64 sqlite3_column_int64(void* stmt, int i_col);

		[CCode(cname = "sqlite3_last_insert_rowid", cheader_filename = "sqlite3.h")]
		private static extern int64 sqlite3_last_insert_rowid(void* db);

		[CCode(cname = "sqlite3_finalize", cheader_filename = "sqlite3.h")]
		private static extern int sqlite3_finalize(void* stmt);

		private const int SQLITE_OPEN_READWRITE = 0x00000002;
		private const int SQLITE_ROW = 100;
		private const int SQLITE_DONE = 101;

		private void* raw_db =(void*) null; // separate SQLite connection for deletes

// Open a separate raw SQLite connection for fast, GTask-free deletes.
// Also creates auxiliary tables(ocr_model_used) that don't use Gom.
// Must be called after the Gom adapter opens the database file.
		public void open_raw_sqlite() {
				if(db_file == null) return;
				int rc = sqlite3_open_v2(db_file.get_path(), out raw_db, SQLITE_OPEN_READWRITE, null);
				if(rc != 0) {
						warning("Failed to open raw SQLite connection(rc=%d)", rc);
						raw_db =(void*) null;
						return;
				}
				ensure_ocr_model_table();
		}

// Delete any entries whose path lacks a directory separator or is too
// short — these were saved by buggy versions and would display as
// "garbled filename + path = '.'" in the UI.
		private void cleanup_invalid_paths() {
				if(raw_db ==(void*) null) return;
				// Find entries where path doesn't contain '/' or is too short
				string sql = "DELETE FROM \"image_entry\""
						+ " WHERE \"path\" NOT LIKE '%/%' OR length(\"path\") < 10";
				string? errmsg = null;
				int rc = sqlite3_exec(raw_db, sql, null, null, out errmsg);
				if(rc != 0) {
						warning("[DatabaseService] Failed to cleanup invalid paths: %s(rc=%d)",
										errmsg ?? "unknown", rc);
						if(errmsg != null) sqlite3_free((void*) errmsg);
				}
		}

// Delete an image by its database ID using the raw SQLite connection.
// This completely bypasses Gom's GTask machinery, avoiding the
// use-after-free bug that triggers SIGSEGV when an image is deleted
// from a file-monitor callback.
		private void delete_image_by_id(int64 id) {
				if(raw_db ==(void*) null) {
						warning("Cannot delete image: raw SQLite handle not available");
						return;
				}
				string sql = "DELETE FROM \"image_entry\" WHERE id = %s".printf(id.to_string());
				string? errmsg = null;
				int rc = sqlite3_exec(raw_db, sql, null, null, out errmsg);
				if(rc != 0) {
						warning("Error deleting image id %" + int64.FORMAT + ": %s(rc=%d)",
										 id, errmsg ?? "unknown", rc);
						if(errmsg != null) sqlite3_free((void*) errmsg);
				}
		}

// Public wrapper that takes an existing ImageEntry and deletes it by ID.
		public void delete_image(ImageEntry image) {
				delete_image_by_id(image.id);
		}

// Delete the image with the given file path from the database.
// Uses raw SQLite entirely — Gom's GTask machinery crashes(SIGSEGV
// in g_task_finalize) when invoked from within a file-monitor callback.
		public void delete_image_by_path(string path) {
				if(raw_db ==(void*) null || path == null) return;
				// Escape single quotes for SQL safety(path is a file path from the FS).
				string safe_path = path.replace("'", "''");
				string sql = "DELETE FROM \"image_entry\" WHERE \"path\" = '%s'".printf(safe_path);
				string? errmsg = null;
				int rc = sqlite3_exec(raw_db, sql, null, null, out errmsg);
				if(rc != 0) {
						warning("Error deleting image by path '%s': %s(rc=%d)", path, errmsg ?? "unknown", rc);
						if(errmsg != null) sqlite3_free((void*) errmsg);
				}
		}

// Return every indexed image path — uses raw SQLite on the separate
// connection so this works from any thread without Gom's worker-thread
// assertion, and streams row-by-row with no count-based pre-allocation.
		public string[] get_all_image_paths() {
				var paths = new string[0];
				if(raw_db ==(void*) null) return paths;
				void* stmt = null;
				int rc = sqlite3_prepare_v2(raw_db, "SELECT \"path\" FROM \"image_entry\"", -1, out stmt, null);
				if(rc != 0) {
						warning("get_all_image_paths: prepare failed(rc=%d)", rc);
						return paths;
				}
				while((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
						string path = sqlite3_column_text(stmt, 0);
						if(path != null) {
								paths += path;
						}
				}
				sqlite3_finalize(stmt);
				return paths;
		}

// Get total count of all images — raw SQLite COUNT query.
		public uint get_all_images_count() {
				if(raw_db ==(void*) null) return 0;
				void* stmt = null;
				int rc = sqlite3_prepare_v2(raw_db, "SELECT COUNT(*) FROM \"image_entry\"", -1, out stmt, null);
				if(rc != 0) {
						warning("get_all_images_count: prepare failed(rc=%d)", rc);
						return 0;
				}
				uint result = 0;
				if(sqlite3_step(stmt) == SQLITE_ROW) {
						result =(uint) sqlite3_column_int(stmt, 0);
				}
				sqlite3_finalize(stmt);
				return result;
		}

// Fetch all known image paths — raw SQLite streaming, no Gom.
		public GLib.HashTable<string, bool> get_known_paths_set() {
				var paths = new GLib.HashTable<string, bool>(str_hash, str_equal);
				if(raw_db ==(void*) null) return paths;
				void* stmt = null;
				int rc = sqlite3_prepare_v2(raw_db, "SELECT \"path\" FROM \"image_entry\"", -1, out stmt, null);
				if(rc != 0) {
						warning("get_known_paths_set: prepare failed(rc=%d)", rc);
						return paths;
				}
				while(sqlite3_step(stmt) == SQLITE_ROW) {
						string path = sqlite3_column_text(stmt, 0);
						if(path != null) {
								paths.insert(path, true);
						}
				}
				sqlite3_finalize(stmt);
				return paths;
		}

// Query image entries using raw SQLite — bypasses Gom entirely.
// Used for the "show all results"(empty query) path to avoid Gom's
// ResourceGroup caching issues after raw-SQL writes.
// Returns a batch of ImageEntry objects matching the given sort/page params.
		private ImageEntry[]? query_raw_batch(int offset, int limit,
																					 SortCriteria sort_criteria,
																					 SortDirection sort_direction,
																					 int64 date_from, int64 date_to) {
				if(raw_db ==(void*) null) return null;

				// Build SQL
				string order_col = sort_criteria == SortCriteria.NAME
						? "\"path\""
						: "\"file-created-at\"";
				string order_dir = sort_direction == SortDirection.ASCENDING ? "ASC" : "DESC";

				string date_clause = "";
				if(date_from > 0 && date_to > 0) {
						date_clause = " WHERE \"file-created-at\" >= %s AND \"file-created-at\" <= %s".printf(
								date_from.to_string(), date_to.to_string());
				} else if(date_from > 0) {
						date_clause = " WHERE \"file-created-at\" >= %s".printf(date_from.to_string());
				} else if(date_to > 0) {
						date_clause = " WHERE \"file-created-at\" <= %s".printf(date_to.to_string());
				}

				// Get total count first
				string count_sql = "SELECT COUNT(*) FROM \"image_entry\"%s".printf(date_clause);
				void* stmt = null;
				int rc = sqlite3_prepare_v2(raw_db, count_sql, -1, out stmt, null);
				if(rc != 0) return null;
				int64 total = 0;
				if(sqlite3_step(stmt) == SQLITE_ROW) {
						total = sqlite3_column_int64(stmt, 0);
				}
				sqlite3_finalize(stmt);
				if(total == 0) return null;
				if(offset >=(int) total) return null;

				int fetch_count = limit > 0 ? int.min(limit,(int) total - offset) :(int) total - offset;

				string query_sql = "SELECT \"id\",\"path\",\"text-content\",\"scanned-at\","
						+ "\"file-created-at\",\"folder-id\",\"accuracy-level\",\"ocr-language\","
						+ "\"file-size\",\"mime-type\""
						+ " FROM \"image_entry\"%s ORDER BY %s %s LIMIT %d OFFSET %d".printf(
								date_clause, order_col, order_dir, fetch_count, offset);

				stmt = null;
				rc = sqlite3_prepare_v2(raw_db, query_sql, -1, out stmt, null);
				if(rc != 0) return null;

				var batch = new ImageEntry[fetch_count];
				int idx = 0;
				while(sqlite3_step(stmt) == SQLITE_ROW) {
						if(idx >= fetch_count) break;
						var entry = new ImageEntry();
						entry.id = sqlite3_column_int64(stmt, 0);
						entry.path =(sqlite3_column_text(stmt, 1) ?? "").make_valid(-1);
						entry.text_content =(sqlite3_column_text(stmt, 2) ?? "").make_valid(-1);
						entry.scanned_at = sqlite3_column_int64(stmt, 3);
						entry.file_created_at = sqlite3_column_int64(stmt, 4);
						entry.folder_id = sqlite3_column_int64(stmt, 5);
						entry.accuracy_level =(sqlite3_column_text(stmt, 6) ?? "").make_valid(-1);
						entry.ocr_language =(sqlite3_column_text(stmt, 7) ?? "").make_valid(-1);
						entry.file_size = sqlite3_column_int64(stmt, 8);
						entry.mime_type =(sqlite3_column_text(stmt, 9) ?? "").make_valid(-1);
						truncate_text_content(entry);
						batch[idx++] = entry;
				}
				sqlite3_finalize(stmt);

				if(idx < fetch_count) {
						batch.resize(idx);
				}
				return batch;
		}

		private Folder[]? cached_folders;
		private bool folder_cache_valid = false;

// Refresh the cached folder list using raw SQLite(avoids Gom caching issues).
// Gom's ResourceGroup can return stale data after raw-SQL writes(purge,
// save_image_raw_sync), so we bypass Gom entirely for this read.
		private void refresh_folder_cache() {
				if(folder_cache_valid && cached_folders != null) return;

				cached_folders = null;
				folder_cache_valid = false;
				if(raw_db ==(void*) null) return;

				void* stmt = null;
				int rc = sqlite3_prepare_v2(raw_db,
						"SELECT \"id\",\"path\",\"enabled\",\"added-at\","
						+ "\"last-scan-time\",\"image-count\",\"display-name\""
						+ " FROM \"folder\"",
						-1, out stmt, null);
				if(rc != 0) {
						warning("refresh_folder_cache: prepare failed(rc=%d)", rc);
						return;
				}

				var folder_list = new List<Folder>();
				while(sqlite3_step(stmt) == SQLITE_ROW) {
						var copy = new Folder();
						copy.id = sqlite3_column_int64(stmt, 0);
						string? p = sqlite3_column_text(stmt, 1);
						copy.path = p != null ? p.make_valid(-1) : "";
						copy.enabled = sqlite3_column_int(stmt, 2) != 0;
						copy.added_at = sqlite3_column_int64(stmt, 3);
						copy.last_scan_time = sqlite3_column_int64(stmt, 4);
						copy.image_count = sqlite3_column_int(stmt, 5);
						string? dn = sqlite3_column_text(stmt, 6);
						copy.display_name = dn != null ? dn.make_valid(-1) : null;
						folder_list.append(copy);
				}
				sqlite3_finalize(stmt);

				Folder[] folders = {};
				foreach(unowned var f in folder_list) {
						folders += f;
						debug("[DatabaseService] refresh_folder_cache: cached folder '%s'(id=%lld)",
									 f.path ?? "(null)", f.id);
				}
				debug("[DatabaseService] refresh_folder_cache: %d folders total", folders.length);
				cached_folders = folders;
				folder_cache_valid = true;
		}

// Synchronize the database folder rows with the GSettings folder paths.
// GSettings is the source of truth for which folders exist. This method:
//   1. Creates DB Folder rows for any GSettings paths that don't have one yet
//   2. Deletes DB Folder rows(and their images) for paths no longer in GSettings
// Call this at startup and after any GSettings folder change.
		public void sync_folders_from_settings(string[] folder_paths) {
				if(repository == null) return;

				invalidate_folder_cache();
				refresh_folder_cache();

				// Build a set of GSettings paths for O(1) lookup
				var gsettings_set = new GLib.HashTable<string, bool>(str_hash, str_equal);
				foreach(string path in folder_paths) {
						gsettings_set.insert(path, true);
				}

				// 1. Delete DB folders not in GSettings
				if(cached_folders != null) {
						foreach(var folder in cached_folders) {
								if(folder != null && folder.path != null && !(gsettings_set.contains(folder.path))) {
										delete_folder_and_images(folder.path);
								}
						}
				}

				// 2. Create DB folders for GSettings paths that don't have a row yet
				foreach(string path in folder_paths) {
						bool found = false;
						if(cached_folders != null) {
								foreach(var folder in cached_folders) {
										if(folder != null && folder.path == path) {
												found = true;
												break;
										}
								}
						}
						if(!found) {
								debug("[DatabaseService] sync: creating DB folder for GSettings path: %s", path);
								var folder = new Folder();
								folder.path = path;
								folder.enabled = true;
								folder.added_at = new DateTime.now_local().to_unix();
								folder.display_name = Path.get_basename(path);
								save_folder(folder);
						}
				}

				// Refresh cache after modifications
				invalidate_folder_cache();
		}

// Invalidate the folder cache — call after any modification
		public void invalidate_folder_cache() {
				folder_cache_valid = false;
		}

// Drop all in-memory caches to reduce background memory usage.
// Called when the window is hidden(background mode). All data is
// reloaded on demand from SQLite when the window is reshown.
		public void clear_caches() {
				cached_folders = null;
				folder_cache_valid = false;
		}

		public uint get_all_folders_count() {
				refresh_folder_cache();
				return cached_folders != null ? cached_folders.length : 0;
		}

		public unowned Folder? get_folder(uint index) {
				if(cached_folders == null || index >= cached_folders.length) return null;
				return cached_folders[index];
		}

		public void save_folder(Folder folder) {
				// Sanitize string fields — folder paths may contain non-UTF-8 bytes
				string path =(folder.path ?? "").make_valid(-1).replace("'", "''");
				string display =(folder.display_name ?? "").make_valid(-1).replace("'", "''");
				int64 added = folder.added_at > 0 ? folder.added_at : new DateTime.now_local().to_unix();
				int enabled = folder.enabled ? 1 : 0;

				if(raw_db ==(void*) null) {
						warning("Cannot save folder: raw SQLite handle not available");
						return;
				}
				string sql_format = "INSERT INTO \"folder\"(\"path\",\"enabled\",\"added-at\",\"display-name\") "
						+ "VALUES('%s',%d,%s,'%s') "
						+ "ON CONFLICT(\"path\") DO UPDATE SET "
						+ "\"enabled\"=excluded.\"enabled\","
						+ "\"added-at\"=excluded.\"added-at\","
						+ "\"display-name\"=excluded.\"display-name\"";
				string sql = sql_format.printf(path, enabled, added.to_string(), display);
				string? errmsg = null;
				int rc = sqlite3_exec(raw_db, sql, null, null, out errmsg);
				if(rc != 0) {
						warning("Error saving folder: %s(rc=%d)", errmsg ?? "unknown", rc);
						if(errmsg != null) sqlite3_free((void*) errmsg);
						return;
				}
				// Notify UI that folders have changed
				invalidate_folder_cache();
				folders_changed();
		}

// Delete a folder by its database ID using the raw SQLite connection.
// Bypasses Gom entirely to avoid the same use-after-free bug.
		private void delete_folder_by_id(int64 id) {
				if(raw_db ==(void*) null) {
						warning("Cannot delete folder: raw SQLite handle not available");
						return;
				}
				string sql = "DELETE FROM \"folder\" WHERE id = %s".printf(id.to_string());
				string? errmsg = null;
				int rc = sqlite3_exec(raw_db, sql, null, null, out errmsg);
				if(rc != 0) {
						warning("Error deleting folder id %" + int64.FORMAT + ": %s(rc=%d)",
										 id, errmsg ?? "unknown", rc);
						if(errmsg != null) sqlite3_free((void*) errmsg);
				}
		}

// Delete a folder by ID(public convenience).
		public void delete_folder(Folder folder) {
				delete_folder_by_id(folder.id);
		}

// Delete a folder and all its images from the database
		public void delete_folder_and_images(string path) {
				if(repository == null) {
						warning("delete_folder_and_images: repository is null");
						return;
				}
				try {
						debug("Looking for folder with path: '%s'", path);
						
						// Clear cached folder data so we get fresh data
						invalidate_folder_cache();
						
						// Find the folder by iterating through all folders
						var group = repository.find_sync(typeof(Folder), null);
						if(group == null) {
								warning("find_sync returned null group");
								return;
						}

						uint count = group.get_count();
						debug("Found %u folders total", count);
						
						if(count > 0) {
								group.fetch_sync(0, count);
								debug("fetch_sync completed");
						}

						int64 folder_id = -1;
						for(uint i = 0; i < count; i++) {
								var res = group.get(i);
								if(res == null) {
										debug("  folder[%u] is null", i);
										continue;
								}
								var folder = res as Folder;
								if(folder == null) {
										debug("  folder[%u] cast to Folder failed", i);
										continue;
								}
								debug("  folder[%u]: id=%" + int64.FORMAT + " path='%s'", i, folder.id, folder.path);
								if(folder.path == path) {
										folder_id = folder.id;
										debug("  -> MATCH FOUND!");
										break;
								}
						}

						if(folder_id < 0) {
								warning("Folder not found for deletion: %s", path);
								return;
						}

						debug("Deleting folder id=%" + int64.FORMAT + " path=%s", folder_id, path);

						// Find and delete all images for this folder
						var img_group = repository.find_sync(typeof(ImageEntry), null);
						uint image_count = 0;
						if(img_group != null && img_group.get_count() > 0) {
								img_group.fetch_sync(0, img_group.get_count());

								// Collect IDs first to avoid reference issues
								var ids = new GLib.List<int64?>();
								for(uint i = 0; i < img_group.get_count(); i++) {
										var img_res = img_group.get(i);
										if(img_res == null) continue;
										var img = img_res as ImageEntry;
										if(img != null && img.folder_id == folder_id) {
												ids.append(img.id);
										}
								}

								// Delete images using raw SQL(avoid Gom delete_sync bug)
								foreach(int64? img_id in ids) {
										delete_image_by_id((int64) img_id);
										image_count++;
								}
						}
						debug("Deleted %u images for folder %s", image_count, path);

						// Delete the folder itself using raw SQL
						delete_folder_by_id(folder_id);
						debug("Deleted folder %s(id=%" + int64.FORMAT + ")", path, folder_id);
						
						// Clear the cache and notify listeners
						invalidate_folder_cache();
						debug("Emitting folders_changed signal...");
						folders_changed();
						debug("folders_changed signal emitted");
				} catch(GLib.Error e) {
						warning("Error deleting folder and images: %s", e.message);
				}
		}

// Get the number of images indexed for a specific folder path
		public uint get_image_count_for_folder(string folder_path) {
				if(repository == null) return 0;
				try {
						// First find the folder to get its ID
						int64 folder_id = -1;
						var folder_group = repository.find_sync(typeof(Folder), null);
						if(folder_group != null && folder_group.get_count() > 0) {
								uint fcount = folder_group.get_count();
								if(fcount > 500000) {
										warning("get_image_count_for_folder: folder count %u exceeds sanity limit, returning 0", fcount);
										return 0;
								}
								folder_group.fetch_sync(0, fcount);
								for(uint i = 0; i < folder_group.get_count(); i++) {
										var res = folder_group.get(i);
										if(res != null) {
												var folder = res as Folder;
												if(folder != null && folder.path == folder_path) {
														folder_id = folder.id;
														break;
												}
										}
								}
						}
						if(folder_id < 0) return 0;

						// Count images with this folder_id
						var img_group = repository.find_sync(typeof(ImageEntry), null);
						if(img_group == null) return 0;
						uint count = 0;
						if(img_group.get_count() > 0) {
								img_group.fetch_sync(0, img_group.get_count());
								for(uint i = 0; i < img_group.get_count(); i++) {
										var res = img_group.get(i);
										if(res != null) {
												var img = res as ImageEntry;
												if(img != null && img.folder_id == folder_id) {
														count++;
												}
										}
								}
						}
						return count;
				} catch(GLib.Error e) {
						warning("Error counting images for folder: %s", e.message);
						return 0;
				}
		}

// Get all configured folder paths(for overlap/subfolder checking)
		public string[] get_all_folder_paths() {
				refresh_folder_cache();
				if(cached_folders == null) return {};
				var paths = new string[cached_folders.length];
				for(int i = 0; i < cached_folders.length; i++) {
						paths[i] = cached_folders[i].path;
				}
				return paths;
		}

// Remove duplicate folders, keeping the one with the lowest ID.
// Uses raw SQL to avoid GOM GTask assertion from idle callback.
		public void deduplicate_folders() {
				if(raw_db ==(void*) null) return;

				var seen = new GLib.HashTable<string, int64?>(str_hash, str_equal);
				var duplicates = new GLib.List<int64?>();

				void* stmt = null;
				int rc = sqlite3_prepare_v2(raw_db,
						"SELECT id, path FROM folder ORDER BY id ASC",
						-1, out stmt, null);
				if(rc != 0) {
						warning("deduplicate_folders: prepare failed(rc=%d)", rc);
						return;
				}

				while(sqlite3_step(stmt) == SQLITE_ROW) {
						int64 id = sqlite3_column_int64(stmt, 0);
						string? p = sqlite3_column_text(stmt, 1);
						string path = p != null ? (!) p : "";

						if(path in seen) {
								duplicates.append(id);
						} else {
								seen[path] = id;
						}
				}
				sqlite3_finalize(stmt);

				foreach(int64? dup_id in duplicates) {
						delete_folder_by_id((int64) dup_id);
				}
		}

// Delete all images and folders from the database.
		public void purge_database() {
				if(raw_db ==(void*) null) return;
				string? errmsg = null;
				int rc = sqlite3_exec(raw_db, "DELETE FROM image_entry", null, null, out errmsg);
				if(rc != 0) warning("purge_database: DELETE image_entry failed(rc=%d): %s", rc, errmsg ?? "?");
				if(errmsg != null) sqlite3_free((void*) errmsg);
				errmsg = null;
				rc = sqlite3_exec(raw_db, "DELETE FROM folder", null, null, out errmsg);
				if(rc != 0) warning("purge_database: DELETE folder failed(rc=%d): %s", rc, errmsg ?? "?");
				if(errmsg != null) sqlite3_free((void*) errmsg);
				invalidate_folder_cache();
		}

		public void close() {
				if(adapter != null) {
						try {
								adapter.close_sync();
						} catch(GLib.Error e) {
								warning("Error closing database: %s", e.message);
						}
						adapter = null;
				}
				repository = null;
		}
}

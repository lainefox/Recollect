// ScannerService discovers and processes image files in configured folders.
// File discovery, pre-filtering, and OCR all run in a background thread.
// A thread-safe AsyncQueue communicates results to the main thread.
// A periodic Timeout drains the queue in batches, keeping UI responsive.
public class ScannerService : Object {
		private DatabaseService database;
		private OcrService ocr;
		private SettingsService settings;
		private GLib.Cancellable? cancellable;
		private bool scanning = false;
		private bool cleanup_mode = false; // true during stale-entry cleanup
		private int cleanup_total = 0;
		private int cleanup_processed = 0;
		private bool paused = false;
		private bool stopping = false; // true when stop_scan was requested
		private bool force_rescan = false;  // if true, re-process all files

		// Scan state
		private int scan_total = 0;
		private int scan_saved = 0;
		private int scan_skipped = 0;

		// Background thread reference
		private Thread<void*>? scan_thread = null;

		// Thread-safe result queue: background thread pushes, main thread drains
		private AsyncQueue<ScanEntryData?> result_queue = new AsyncQueue<ScanEntryData?>();
		private uint drain_timeout_id = 0;

		// Pause/resume: background thread sleeps on this cond when paused
		private Mutex pause_mutex = Mutex();
		private Cond pause_cond = Cond();

		// Per-folder cancellation: when a user presses the stop button for one
		// folder, only that folder is skipped — other folders continue scanning.
		private HashTable<string, bool> cancelled_folders = new HashTable<string, bool>(str_hash, str_equal);

		// Per-folder progress tracking: folder_path -> total files / current progress
		private HashTable<string, int> folder_file_counts = new HashTable<string, int>(str_hash, str_equal);
		private HashTable<string, int> folder_progress_counts = new HashTable<string, int>(str_hash, str_equal);
		private string? current_folder_path = null;

		// File monitoring(incremental updates)
		private HashTable<string, FileMonitor> folder_monitors = new HashTable<string, FileMonitor>(str_hash, str_equal);
		private bool monitoring = false;

		// Monitor coalescing: file events deduplicate into this hash table
		// and are drained periodically by a timer, instead of spawning one
		// tesseract process per event.
		private HashTable<string, int64?> pending_monitor_paths = new HashTable<string, int64?>(str_hash, str_equal);
		private HashTable<string, int64?> pending_monitor_sizes = new HashTable<string, int64?>(str_hash, str_equal);
		private uint coalesce_timer_id = 0;
		private int active_monitor_threads = 0;
		private bool monitor_burst_mode = false;
		private int monitor_queued_total = 0;
		private int monitor_processed_total = 0;
		private const int MONITOR_COALESCE_MS = 1500;
		private const int MONITOR_BURST_THRESHOLD = 5;
		private const int MAX_MONITOR_THREADS = 2;

		// How many queue entries to process per drain cycle
		private const int DRAIN_BATCH_SIZE = 5;

		public signal void scan_started(int total_files);
		public signal void scan_progress(int current, int total);
		public signal void scan_folder_started(string folder_path, int file_count);
		public signal void scan_folder_progress(string folder_path, int current, int total);
		public signal void scan_folder_completed(string folder_path, int scanned, int total);
		public signal void file_processed(string filepath);
		public signal void file_saved(ImageEntry entry);
		public signal void scan_completed(int scanned, int total);
		public signal void scan_error(string message);
		public signal void scan_paused();
		public signal void scan_resumed();
		public signal void file_deleted(string path);
		public signal void no_models_available();

		public ScannerService(DatabaseService database, OcrService ocr, SettingsService settings) {
				this.database = database;
				this.ocr = ocr;
				this.settings = settings;
		}

// Delegate to Utils for file classification
		private static bool is_supported_image_path(string path) {
				return Utils.is_supported_image_path(path);
		}

// Start a full scan of all configured folders.
// Minimal work on the main thread: read folders + known paths from DB,
// then spawn a background thread that discovers files, pre-filters,
// and runs OCR. The thread pushes results to AsyncQueue for the
// main thread to drain in batches.
// @param force  If true, re-scans all files even if already indexed
		public void start_scan(bool force = false) {
				if(scanning || cleanup_mode) {
						warning("Scan or cleanup already in progress, ignoring start_scan request");
						return;
				}

				// Refuse to scan if no OCR models are installed anywhere.
				if(settings != null && !settings.has_any_model_available()) {
						no_models_available();
						return;
				}

				// If resuming from pause, just unpause
				if(paused) {
						resume_scan();
						return;
				}

				cancellable = new GLib.Cancellable();
				cancelled_folders.remove_all();
				scanning = true;
				stopping = false;
				scan_saved = 0;
				scan_skipped = 0;
				scan_total = 0;

				// Reset per-folder progress tracking(fresh for this scan)
				folder_file_counts = new HashTable<string, int>(str_hash, str_equal);
				folder_progress_counts = new HashTable<string, int>(str_hash, str_equal);
				current_folder_path = null;

				uint folder_count = database.get_all_folders_count();
				if(folder_count == 0) {
						scanning = false;
						scan_completed(0, 0);
						return;
				}

				// Collect enabled folder paths on main thread(fast DB query)
				string[] folder_paths = new string[0];
				for(uint i = 0; i < folder_count; i++) {
						Folder? folder = database.get_folder(i);
						if(folder != null && folder.enabled) {
								folder_paths += folder.path;
						}
				}

				if(folder_paths.length == 0) {
						scanning = false;
						scan_completed(0, 0);
						return;
				}

				force_rescan = force;

				// Get known paths from DB in one fast query(avoids N per-file queries).
				// If force=true, pass empty set so all files are reprocessed.
				GLib.HashTable<string, bool> known_paths;
				if(force) {
						known_paths = new GLib.HashTable<string, bool>(str_hash, str_equal);
				} else {
						known_paths = database.get_known_paths_set();
				}

				// Read OCR settings on the main thread(SettingsService is not thread-safe)
				string ocr_language = settings != null ? settings.get_ocr_language() : "eng";
				string ocr_accuracy = settings != null ? settings.get_ocr_accuracy() : "balanced";
				bool scan_hidden = settings != null ? settings.get_scan_hidden_folders() : false;

				// Initialize tesseract CLI(no-op for CLI approach, but keeps API consistent)
				ocr.initialize(ocr_language, ocr_accuracy);

				// Emit scan_started with 0 — real total will be sent once file collection
				// is done in the background thread
				debug("[ScannerService] start_scan: %d folders", folder_paths.length);
				foreach(unowned string fp in folder_paths) {
						debug("[ScannerService]   folder: %s", fp);
				}
				scan_started(0);

				// Spawn background thread for file discovery + pre-filtering + OCR
				try {
						scan_thread = new Thread<void*>.try("scanner",() => {
								run_scan_thread(folder_paths, known_paths, ocr_language, ocr_accuracy, scan_hidden);
								return null;
						});
				} catch(Error e) {
						warning("[ScannerService] Failed to create scan thread: %s", e.message);
						scanning = false;
						scan_error("Failed to start scan thread");
						return;
				}

				// Start periodic drain of the result queue on the main thread
				drain_timeout_id = Timeout.add(50,() => {
						return drain_result_queue();
				});
		}

// Background thread: discovers files, pre-filters against known paths,
// then runs tesseract OCR for each new file. Pushes results to the
// AsyncQueue for the main thread to drain. Supports pause/resume.
//
// Uses a two-phase approach:
//   Phase 1 — Quick counting pass: walk all folders, count new vs skipped
//              files, store only per-folder counts(no path storage).
//              This establishes the grand total so the progress pie never
//              jumps backward.
//   Phase 2 — Processing pass: for each folder, walk again collecting
//              file paths into a local list(freed after the folder is
//              done), filter against known_paths, run OCR.
		private void run_scan_thread(string[] folder_paths, GLib.HashTable<string, bool> known_paths,
																	 string ocr_language, string ocr_accuracy, bool scan_hidden) {
				// ── Phase 1: Quick count of all folders(no path storage) ──
				// This is fast — directory enumeration only, no OCR.
				int grand_total_new = 0;
				int grand_total_skipped = 0;
				// Store per-folder new-file counts so the main thread can display
				// per-folder progress bars.
				var folder_new_counts = new HashTable<string, int>(str_hash, str_equal);
				var folder_skipped_counts = new HashTable<string, int>(str_hash, str_equal);

				foreach(unowned string folder_path in folder_paths) {
						if(stopping ||(cancellable != null && cancellable.is_cancelled())) break;
						int new_count = 0;
						int skipped_count = 0;
						count_files_bg(folder_path, known_paths, ref new_count, ref skipped_count, scan_hidden);
						folder_new_counts.insert(folder_path, new_count);
						folder_skipped_counts.insert(folder_path, skipped_count);
						grand_total_new += new_count;
						grand_total_skipped += skipped_count;
				}

				// Push single collection-done entry with grand totals and per-folder counts
				debug("[ScannerService] run_scan_thread: building collection_done with %d folders",
							 folder_paths.length);
				var meta = new ScanEntryData();
				meta.is_collection_done = true;
				meta.scan_total = grand_total_new;
				meta.scan_skipped = grand_total_skipped;
				// Pack per-folder counts into parallel arrays so the main thread
				// can build folder_file_counts without iterating per-file paths.
				string[] fp_arr = new string[folder_paths.length];
				int[] fc_arr = new int[folder_paths.length];
				int f_idx = 0;
				foreach(unowned string fpath in folder_paths) {
						fp_arr[f_idx] = fpath;
						fc_arr[f_idx] = folder_new_counts.lookup(fpath);
						debug("[ScannerService]   folder_paths_arr[%d] = '%s'  count=%d",
									 f_idx, fpath ?? "(null)", fc_arr[f_idx]);
						f_idx++;
				}
				meta.folder_paths_arr = fp_arr;
				meta.folder_counts_arr = fc_arr;
				result_queue.push(meta);

				if(grand_total_new == 0) {
						// No new files to scan — push done sentinel immediately
						var done = new ScanEntryData();
						done.is_done = true;
						result_queue.push(done);
						return;
				}

				// ── Phase 2: OCR each folder's new files ──
				// Walk each folder again, this time collecting paths into a local
				// list(freed after the folder is processed). This avoids storing
				// all folders' paths in memory simultaneously.
				debug("[ScannerService] Phase 2: processing %d folders", folder_paths.length);
				foreach(unowned string folder_path in folder_paths) {
						if(stopping ||(cancellable != null && cancellable.is_cancelled())) break;

						// Check if this folder was cancelled by the user.
						// Must hold the mutex because cancelled_folders can be written
						// from the main thread via cancel_folder().
						pause_mutex.lock();
						bool folder_cancelled = cancelled_folders.contains(folder_path);
						pause_mutex.unlock();
						if(folder_cancelled) {
								debug("[ScannerService] Phase 2 folder '%s': cancelled, skipping", folder_path);
								continue;
						}

						int folder_new = folder_new_counts.lookup(folder_path);
						debug("[ScannerService] Phase 2 folder '%s': new=%d", folder_path, folder_new);
						if(folder_new == 0) continue;

						// Collect files for THIS folder only(local list, freed on loop exit)
						var folder_files = new List<string>();
						collect_files_bg(folder_path, ref folder_files, scan_hidden);

						// Pre-filter against known_paths and process each new file
						int local_idx = 0;
						foreach(string filepath in folder_files) {
								if(stopping ||(cancellable != null && cancellable.is_cancelled())) break;

								// Skip already-indexed files
								if(known_paths.contains(filepath)) continue;

								// Pause: sleep on cond until resumed.
								// Also check folder cancellation under the mutex to avoid
								// a data race with cancel_folder() on the main thread.
								pause_mutex.lock();
								while(paused && !stopping && !cancelled_folders.contains(folder_path)) {
										pause_cond.wait(pause_mutex);
								}
								bool cancelled = cancelled_folders.contains(folder_path);
								pause_mutex.unlock();
								if(cancelled) break;

								if(stopping ||(cancellable != null && cancellable.is_cancelled())) break;

								// Run tesseract OCR in this background thread(the slow part)
								string ocr_text = ocr.extract_text(filepath);

								var entry_data = new ScanEntryData();
								entry_data.path = filepath.make_valid(-1);
								entry_data.text_content = ocr_text.make_valid(-1);
								entry_data.accuracy_level = ocr_accuracy.make_valid(-1);
								entry_data.ocr_language = ocr_language.make_valid(-1);
								entry_data.scanned_at = new DateTime.now_local().to_unix();
								entry_data.file_created_at = get_file_created_time_bg(filepath);
								entry_data.file_size = get_file_size_bg(filepath);
								entry_data.mime_type = guess_mime_type(filepath);
								entry_data.folder_path = folder_path;

								result_queue.push(entry_data);
								local_idx++;

								Thread.usleep(1000);
						}
						// folder_files freed here — local List<string> goes out of scope
				}

				// Push a sentinel to signal completion
				var done = new ScanEntryData();
				done.is_done = true;
				result_queue.push(done);
		}

// Background-thread-safe file counter(no path storage, just counts).
// Walks the directory tree, incrementing new_count or skipped_count
// depending on whether the path is in known_paths.
		private void count_files_bg(string folder_path, GLib.HashTable<string, bool> known_paths,
																	ref int new_count, ref int skipped_count, bool scan_hidden) {
				try {
						var folder = File.new_for_path(folder_path);
						if(!folder.query_exists()) return;

						var enumerator = folder.enumerate_children(
								"standard::name,standard::type,standard::is-hidden",
								FileQueryInfoFlags.NONE,
								cancellable
						);

						FileInfo info;
						while((info = enumerator.next_file(cancellable)) != null) {
								if(cancellable != null && cancellable.is_cancelled()) return;

								if(info.get_file_type() == FileType.DIRECTORY) {
										if(!scan_hidden && info.get_attribute_boolean("standard::is-hidden")) continue;
										count_files_bg(
												Path.build_filename(folder_path, info.get_name()),
												known_paths,
												ref new_count,
												ref skipped_count,
												scan_hidden
										);
								} else if(info.get_file_type() == FileType.REGULAR) {
										if(!scan_hidden && info.get_attribute_boolean("standard::is-hidden")) continue;
										string filepath = Path.build_filename(folder_path, info.get_name());
										if(Utils.is_supported_image_path(filepath)) {
												if(known_paths.contains(filepath)) {
														skipped_count++;
												} else {
														new_count++;
												}
										}
								}
						}
				} catch(Error e) {
						warning("Error counting folder %s: %s", folder_path, e.message);
				}
		}

// Background-thread-safe file collection(uses GLib.File which is thread-safe).
// Appends matching image file paths to @all_files. Does NOT track per-file
// folder paths — the streaming scanner uses per-folder processing instead.
// Skips hidden(dot-prefixed) directories unless scan_hidden is true.
		private void collect_files_bg(string folder_path, ref List<string> all_files, bool scan_hidden) {
				try {
						var folder = File.new_for_path(folder_path);
						if(!folder.query_exists()) return;

						var enumerator = folder.enumerate_children(
								"standard::name,standard::type,standard::is-hidden",
								FileQueryInfoFlags.NONE,
								cancellable
						);

						FileInfo info;
						while((info = enumerator.next_file(cancellable)) != null) {
								if(cancellable != null && cancellable.is_cancelled()) return;

								if(info.get_file_type() == FileType.DIRECTORY) {
										// Skip hidden directories unless the user opted in
										if(!scan_hidden && info.get_attribute_boolean("standard::is-hidden")) continue;
										collect_files_bg(
												Path.build_filename(folder_path, info.get_name()),
												ref all_files,
												scan_hidden
										);
								} else if(info.get_file_type() == FileType.REGULAR) {
										// Skip hidden files unless scan_hidden is true
										if(!scan_hidden && info.get_attribute_boolean("standard::is-hidden")) continue;
										string filepath = Path.build_filename(folder_path, info.get_name());
										if(is_supported_image_path(filepath)) {
												all_files.append(filepath);
										}
								}
						}
				} catch(Error e) {
						warning("Error scanning folder %s: %s", folder_path, e.message);
				}
		}

// Drain the result queue on the main thread. Called every 50ms via Timeout.
// Processes up to DRAIN_BATCH_SIZE entries per call to avoid UI stalls.
// Handles two special entry types:
//   - is_collection_done: file discovery is complete, real totals now known
//   - is_done: scan is fully complete
// Returns Source.CONTINUE to keep running, Source.REMOVE when scan is done.
		private bool drain_result_queue() {
				if(cancellable != null && cancellable.is_cancelled()) {
						// Discard remaining entries and finish
						ScanEntryData? discard;
						while((discard = result_queue.try_pop()) != null) {}
						finish_scan();
						return Source.REMOVE;
				}

				int processed = 0;
				while(processed < DRAIN_BATCH_SIZE) {
						ScanEntryData? data_raw = result_queue.try_pop();
						if(data_raw == null) {
								break;
						}
						ScanEntryData data =(!) data_raw;

						// Cleanup progress update: just refresh the pie/popover
						if(data.is_cleanup_progress) {
								scan_progress(data.cleanup_current, data.cleanup_total);
								processed++;
								continue;
						}

						// Deleted file: drop from DB and UI
						if(data.is_deleted) {
								database.delete_image_by_path(data.path);
								file_deleted(data.path);
								file_processed(data.path);

								if(cleanup_mode) {
										cleanup_processed++;
										scan_progress(cleanup_processed, cleanup_total);
								}

								processed++;
								continue;
						}

						// Collection done: the background thread has finished the counting
						// pass and we now know the real totals. Both the grand total and
						// per-folder counts are provided, so we can emit folder signals
						// without iterating per-file path arrays.
						if(data.is_collection_done) {
								scan_total = data.scan_total;
								scan_skipped = data.scan_skipped;

								debug("[ScannerService] collection_done: total=%d skipped=%d",
											 scan_total, scan_skipped);

								int total_with_existing = scan_total + scan_skipped;

								// Re-emit scan_started with the real total
								scan_started(total_with_existing);

								// Set up per-folder counts from the parallel arrays
								folder_file_counts = new HashTable<string, int>(str_hash, str_equal);
								folder_progress_counts = new HashTable<string, int>(str_hash, str_equal);

								string[]? fp_arr = data.folder_paths_arr;
								int[]? fc_arr = data.folder_counts_arr;
								if(fp_arr != null && fc_arr != null) {
										int n = int.min(fp_arr.length, fc_arr.length);
										for(int i = 0; i < n; i++) {
												unowned string fpath = fp_arr[i];
												int count = fc_arr[i];
												debug("[ScannerService]   folder[%d]: %s -> %d new files",
															 i, fpath ?? "(null)", count);
												if(fpath != null && fpath.length > 0) {
														folder_file_counts.insert(fpath, count);
														folder_progress_counts.insert(fpath, 0);
														// Always emit scan_folder_started so the popover
														// shows ALL folders, even those with 0 new files
														//(already fully indexed). The UI can display
														// the count — 0 means "up to date".
														debug("[ScannerService]     -> emitting scan_folder_started: %s count=%d",
																	 fpath, count);
														scan_folder_started(fpath, count);
												}
										}
								}
								processed++;
								continue;
						}

						if(data.is_done) {
								// Sentinel reached — scan is complete
								finish_scan();
								return Source.REMOVE;
						}

						// Validate path — skip corrupted entries that don't look like
						// real file paths(too short, no directory separator, etc.)
						if(data.path == null || data.path.length < 10 || !data.path.contains("/")) {
								warning("[ScannerService] Skipping entry with invalid path: '%s'(len=%d)", 
												 data.path ?? "null", data.path != null ? data.path.length : 0);
								processed++;
								continue;
						}

						var image = new ImageEntry();
						image.path = data.path;
						image.text_content = data.text_content;
						image.scanned_at = data.scanned_at;
						image.file_created_at = data.file_created_at;
						image.accuracy_level = data.accuracy_level;
						image.ocr_language = data.ocr_language;
						image.file_size = data.file_size;
						image.mime_type = data.mime_type;

						// Set folder_id from folder_path
						if(data.folder_path != null) {
								int64 fid = database.get_folder_id(data.folder_path);
								if(fid >= 0) {
										image.folder_id = fid;
								}
						}

						database.save_image(image, force_rescan);
						scan_saved++;

						// Look up the image ID from the database to be certain we have the
						// correct id, regardless of which save path(Gom or raw SQL) was used.
						int64 saved_id = database.get_image_id_by_path(data.path);
						if(saved_id >= 0) {
								database.save_ocr_models(saved_id, data.ocr_language, data.accuracy_level);
						}

						file_saved(image);
						file_processed(data.path);

						// Skip entries from cancelled folders — they may still be in the
						// queue from before the cancellation was processed.
						if(data.folder_path != null && cancelled_folders.contains(data.folder_path)) {
								processed++;
								continue;
						}

						// Overall progress: use scan_saved(actual saved count) instead
						// of a background-thread file_index, which is robust across
						// streaming where files arrive per-folder rather than in one
						// global array.
						int current_progress = scan_saved + scan_skipped;
						int total_progress = scan_total + scan_skipped;
						scan_progress(current_progress, total_progress);

						// Per-folder progress
						if(data.folder_path != null && data.folder_path.length > 0) {
								int prev = folder_progress_counts.lookup(data.folder_path);
								folder_progress_counts.insert(data.folder_path, prev + 1);
								int folder_total = folder_file_counts.lookup(data.folder_path);
								if(folder_total > 0) {
										scan_folder_progress(data.folder_path, prev + 1, folder_total);
										// Emit folder completed when all files in this folder are done
										if(prev + 1 >= folder_total) {
												scan_folder_completed(data.folder_path, prev + 1, folder_total);
										}
								}
						}

						processed++;
				}

				// If no scan/cleanup is running and the queue is empty, stop the
				// timeout so it doesn't tick forever when only monitor deletions
				// were processed.
				if(!scanning && result_queue.length() == 0 && drain_timeout_id != 0) {
						Source.remove(drain_timeout_id);
						drain_timeout_id = 0;
						return Source.REMOVE;
				}

				return Source.CONTINUE;
		}

// Finish the scan or cleanup: update settings and emit completion signal.
// If a rescan was requested while scanning (e.g. a folder was added), starts
// a new scan immediately so the new folder is picked up.
		private void finish_scan() {
				if(!scanning) {
						return;
				}
				scanning = false;
				force_rescan = false;
				if(drain_timeout_id != 0) {
						Source.remove(drain_timeout_id);
						drain_timeout_id = 0;
				}

				// Free per-scan tracking tables to reduce background memory
				folder_file_counts = new HashTable<string, int>(str_hash, str_equal);
				folder_progress_counts = new HashTable<string, int>(str_hash, str_equal);
				cancelled_folders.remove_all();
				current_folder_path = null;
				if(cleanup_mode) {
						bool was_cleanup = cleanup_mode;
						int total = cleanup_total;
						int removed = cleanup_processed;
						cleanup_mode = false;
						cleanup_total = 0;
						cleanup_processed = 0;
						if(was_cleanup) {
								scan_completed(removed, total);
						}
				} else {
						if(settings != null) {
								settings.set_last_scan_time(new DateTime.now_local().to_unix());
						}
						int total = scan_total + scan_skipped;
						scan_completed(scan_saved + scan_skipped, total);
				}
				scan_thread = null;
		}

// Get file creation time(thread-safe for background thread)
		private int64 get_file_created_time_bg(string path) {
				try {
						var file = File.new_for_path(path);
						var info = file.query_info(
								"time::created,time::modified",
								FileQueryInfoFlags.NONE
						);
						var created = info.get_creation_date_time();
						if(created != null) {
								return created.to_unix();
						}
						var modified = info.get_modification_date_time();
						if(modified != null) {
								return modified.to_unix();
						}
				} catch(Error e) {
						// Ignore
				}
				return new DateTime.now_local().to_unix();
		}

// Get file size in bytes(thread-safe for background thread)
		private int64 get_file_size_bg(string path) {
				try {
						var file = File.new_for_path(path);
						var info = file.query_info("standard::size", FileQueryInfoFlags.NONE);
						return info.get_size();
				} catch(Error e) {
						return 0;
				}
		}

// Delegate MIME type guessing to Utils
		private string guess_mime_type(string path) {
				return Utils.guess_mime_type(path);
		}

// Get file size from the main thread.  Returns -1 if the file doesn't
// exist or can't be queried, 0 if it exists but is empty, >0 otherwise.
		private int64 get_file_size_main(string path) {
				try {
						var file = File.new_for_path(path);
						if(!file.query_exists()) return -1;
						var info = file.query_info("standard::size", FileQueryInfoFlags.NONE);
						return info.get_size();
				} catch(Error e) {
						return -1;
				}
		}

// Stop the scan entirely. Cancels the background thread, waits for
// it to finish, and cleans up. All already-saved entries are kept.
		public void stop_scan() {
				if(!scanning) return;

				stopping = true;

				// Wake the thread if it's paused so it can exit
				pause_mutex.lock();
				paused = false;
				pause_cond.signal();
				pause_mutex.unlock();

				if(cancellable != null) {
						cancellable.cancel();
				}

				// Drain remaining queue entries on main thread
				ScanEntryData? discard;
				while((discard = result_queue.try_pop()) != null) {}

				// Clean up the drain timeout
				if(drain_timeout_id != 0) {
						Source.remove(drain_timeout_id);
						drain_timeout_id = 0;
				}

				if(scan_thread != null) {
						scan_thread.join();
						scan_thread = null;
				}

				stopping = false;
				paused = false;
				cancelled_folders.remove_all();
				result_queue = new AsyncQueue<ScanEntryData?>(); // fresh queue for next scan

				bool was_cleanup = cleanup_mode;
				int cleanup_removed = cleanup_processed;
				int cleanup_total_count = cleanup_total;
				cleanup_mode = false;
				cleanup_total = 0;
				cleanup_processed = 0;

				// Emit scan_completed so UI can update(hide pie, clear popover rows)
				if(was_cleanup) {
						scanning = false;
						scan_completed(cleanup_removed, cleanup_total_count);
				} else {
						if(settings != null) {
								settings.set_last_scan_time(new DateTime.now_local().to_unix());
						}
						scanning = false;
						scan_completed(scan_saved + scan_skipped, scan_total + scan_skipped);
				}
		}

// Pause the scan. The background thread will block until resumed.
		public void pause_scan() {
				if(!scanning || paused || cleanup_mode) return;
				paused = true;
				scan_paused();
		}

// Resume a paused scan.
		public void resume_scan() {
				if(!scanning || !paused || cleanup_mode) return;
				paused = false;
				pause_mutex.lock();
				pause_cond.signal();
				pause_mutex.unlock();
				scan_resumed();
		}

// Start a cleanup scan that checks every indexed path against disk and
// removes stale database entries. Reuses the same progress popover as a
// normal scan so the user can see it working on large libraries.
		public void start_cleanup() {
				if(scanning || cleanup_mode) {
						warning("Scan or cleanup already in progress, ignoring start_cleanup request");
						return;
				}

				cleanup_mode = true;
				scanning = true; // reuse scanning flag so UI shows progress
				stopping = false;
				paused = false;
				cleanup_processed = 0;

				// Get all indexed paths on the main thread(Gom is not thread-safe)
				string[] all_paths = database.get_all_image_paths();
				cleanup_total = all_paths.length;

				if(cleanup_total == 0) {
						cleanup_mode = false;
						scanning = false;
						scan_completed(0, 0);
						return;
				}

				// Reset per-folder progress tracking
				folder_file_counts = new HashTable<string, int>(str_hash, str_equal);
				folder_progress_counts = new HashTable<string, int>(str_hash, str_equal);
				current_folder_path = null;

				scan_started(cleanup_total);
				scan_progress(0, cleanup_total);

				cancellable = new GLib.Cancellable();

				try {
						scan_thread = new Thread<void*>.try("cleanup",() => {
								run_cleanup_thread(all_paths);
								return null;
						});
				} catch(Error e) {
						warning("[ScannerService] Failed to create cleanup thread: %s", e.message);
						cleanup_mode = false;
						scanning = false;
						scan_error("Failed to start cleanup thread");
						return;
				}

				drain_timeout_id = Timeout.add(50,() => {
						return drain_result_queue();
				});
		}

		private void run_cleanup_thread(string[] all_paths) {
				int total = all_paths.length;
				int checked = 0;

				foreach(string path in all_paths) {
						if(stopping ||(cancellable != null && cancellable.is_cancelled())) break;

						checked++;
						var file = File.new_for_path(path);
						if(!file.query_exists()) {
								var entry = new ScanEntryData();
								entry.is_deleted = true;
								entry.path = path.make_valid(-1);
								result_queue.push(entry);
						}

						// Throttle progress updates: every 50 files or on the last one
						if(checked % 50 == 0 || checked == total) {
								var progress = new ScanEntryData();
								progress.is_cleanup_progress = true;
								progress.cleanup_current = checked;
								progress.cleanup_total = total;
								result_queue.push(progress);
						}

						Thread.usleep(100); // tiny yield to keep CPU usage reasonable
				}

				var done = new ScanEntryData();
				done.is_done = true;
				result_queue.push(done);
		}

// Cancel scanning for a specific folder. Other folders continue.
// Already-indexed files for this folder are kept in the database.
		public void cancel_folder(string folder_path) {
				cancelled_folders.insert(folder_path, true);
				// Wake the background thread if it's paused — the pause loop now
				// checks cancelled_folders, so the thread will see the cancellation
				// and skip this folder.
				pause_mutex.lock();
				pause_cond.signal();
				pause_mutex.unlock();
				debug("[ScannerService] Cancelled folder: %s", folder_path);
		}

// Request a rescan that picks up any newly added folders.
// If a scan is running, it is stopped and restarted immediately
// so the new folder appears in the popover without waiting for
// the current scan to finish.
		public void request_rescan() {
				if(scanning) {
						// Stop the current scan so any newly added folders are picked
						// up immediately rather than waiting for it to finish.
						stop_scan();
				}
				start_scan();
		}

		public bool is_cleanup_mode() {
				return cleanup_mode;
		}

// Check if a scan is currently in progress
		public bool is_scanning() {
				return scanning;
		}

// Check if the scan is currently paused
		public bool is_paused() {
				return paused;
		}

		// ---- Incremental file monitoring ----

		public void start_monitoring() {
				if(monitoring) {
						stop_monitoring();
				}
				monitoring = true;
				var paths = settings.get_folders();
				foreach(string folder_path in paths) {
						monitor_directory_recursive(folder_path);
				}
		}

		public void stop_monitoring() {
				monitoring = false;

				// Cancel all GFileMonitors
				var keys = folder_monitors.get_keys_as_array();
				for(uint i = 0; keys != null && i < keys.length; i++) {
						unowned string folder_path = keys[i];
						FileMonitor? monitor = folder_monitors.lookup(folder_path);
						if(monitor != null) {
								monitor.cancel();
						}
				}
				folder_monitors.remove_all();

				// Drain any pending coalesce state
				if(coalesce_timer_id != 0) {
						Source.remove(coalesce_timer_id);
						coalesce_timer_id = 0;
				}
				pending_monitor_paths.remove_all();
				pending_monitor_sizes.remove_all();
				active_monitor_threads = 0;
				if(monitor_burst_mode) {
						monitor_burst_mode = false;
						scan_completed(monitor_processed_total, monitor_queued_total);
						monitor_queued_total = 0;
						monitor_processed_total = 0;
				}

		}

		public void restart_monitoring() {
				if(!monitoring) return;
				stop_monitoring();
				start_monitoring();
		}

		private void monitor_directory_recursive(string folder_path) {
				var dir = File.new_for_path(folder_path);
				if(!dir.query_exists()) return;

				try {
						// WATCH_MOVES is required on Linux so GLib's inotify backend
						// delivers MOVED_IN events for atomic file writes (rename
						// into the watched directory).  Without it, files created
						// via g_file_replace / atomic rename are silently dropped.
						var monitor = dir.monitor_directory(FileMonitorFlags.WATCH_MOVES, null);
						monitor.changed.connect(on_monitor_changed);
						folder_monitors.insert(folder_path, monitor);
						debug("[ScannerService] Monitoring directory: %s", folder_path);

						FileInfo? child_info = null;
						var enumerator = dir.enumerate_children(
								"standard::name,standard::type",
								FileQueryInfoFlags.NONE,
								null
						);
						while((child_info = enumerator.next_file(null)) != null) {
								if(child_info.get_file_type() == FileType.DIRECTORY) {
										string child_path = Path.build_filename(folder_path, child_info.get_name());
										monitor_directory_recursive(child_path);
								}
						}
				} catch(GLib.Error e) {
						warning("Error monitoring directory %s: %s", folder_path, e.message);
				}
		}

		private void on_monitor_changed(File file, File? other_file, FileMonitorEvent event) {
				string path = file.get_path();
				if(path == null) return;
				// Validate path — skip if it looks corrupted(too short, no separator)
				if(path.length < 10 || !path.contains("/")) {
						warning("[ScannerService] Monitor ignoring invalid path: '%s'", path);
						return;
				}

				debug("[ScannerService] Monitor event %d on: %s",(int) event, path);

				if(event == FileMonitorEvent.CREATED || event == FileMonitorEvent.MOVED_IN) {
						FileType? ftype = null;
						try {
								var info = file.query_info("standard::type", FileQueryInfoFlags.NONE, null);
								ftype = info.get_file_type();
						} catch(GLib.Error e) {
								warning("Error querying file type for %s: %s", path, e.message);
						}

						if(ftype == FileType.DIRECTORY) {
								debug("[ScannerService] New directory, setting up monitor: %s", path);
								monitor_directory_recursive(path);
						} else if(Utils.is_supported_image_path(path)) {
								debug("[ScannerService] Monitor queuing new image: %s", path);
								queue_monitor_path(path);
						}
				} else if(event == FileMonitorEvent.CHANGES_DONE_HINT || event == FileMonitorEvent.CHANGED) {
						// CHANGES_DONE_HINT means the file has been closed after
						// writing.  CHANGED is a safety net for mid-write updates.
						// Both are deduplicated by the hash table.
						if(Utils.is_supported_image_path(path)) {
								queue_monitor_path(path);
						}
				} else if(event == FileMonitorEvent.DELETED || event == FileMonitorEvent.MOVED_OUT) {
						if(folder_monitors.contains(path)) {
								FileMonitor? monitor = folder_monitors.lookup(path);
								if(monitor != null) {
										monitor.cancel();
								}
								folder_monitors.remove(path);
								debug("[ScannerService] Monitor directory removed: %s", path);
						} else if(Utils.is_supported_image_path(path)) {
								debug("[ScannerService] Monitor file deleted/moved out: %s", path);
								process_deleted_file(path);
						}
				} else if(event == FileMonitorEvent.RENAMED) {
						if(Utils.is_supported_image_path(path)) {
								process_deleted_file(path);
						}
						string? new_path = other_file != null ? other_file.get_path() : null;
						// Validate new_path with same checks as the main path above
						if(new_path != null && new_path.length >= 10 && new_path.contains("/")
								&& Utils.is_supported_image_path(new_path)) {
								debug("[ScannerService] Monitor rename %s → %s", path, new_path);
								queue_monitor_path(new_path);
						} else if(new_path != null) {
								debug("[ScannerService] Monitor RENAMED ignoring invalid new_path: '%s'", new_path);
						}
				}
		}

		// ── Coalescing file-monitor pipeline ──────────────────────────────
		//
		// File events are NOT processed immediately. Instead they are added to a
		// hash table(deduplicated) and drained periodically by a timer. This
		// solves two problems:
		//
		//  1.  Copy / generate storms: when 100 files land in 2 s we don't spawn
		//      100 tesseract processes and crash the machine.
		//  2.  Duplicate events: repeated CREATED/CHANGED for the same path are
		//      collapsed into one.
		//
		// When the drain finds ≥5 files in one cycle it enters **burst mode**
		// and shows the scan-progress pie / popover. The progress total grows
		// dynamically as more files keep arriving.
		//
		// OCR runs on at most MAX_MONITOR_THREADS background threads at a time.
		// Excess paths are re-queued for the next drain cycle.

// Add a path to the coalescing set and ensure the periodic drain timer
// is running. Safe to call from any thread — uses main-thread Idle.
// Stores the time (in microseconds) when the path was queued for
// file-stability checking.
	private void queue_monitor_path(string path) {
			// Additional safety: validate path before inserting
			if(path == null || path.length < 5 || !path.contains("/")) {
					warning("[ScannerService] queue_monitor_path ignoring invalid path: '%s'", path ?? "null");
					return;
			}
			debug("[ScannerService] queue_monitor_path: %s", path);
			pending_monitor_paths.insert(path, GLib.get_monotonic_time());
			// Reset size tracking so the stability check starts fresh —
			// every file event means the file might have been rewritten.
			pending_monitor_sizes.remove(path);
				// Start the coalesce timer if it isn't already running.
				// This is always called from the main-thread file-monitor signal,
				// so we can safely create the timeout here.
				if(coalesce_timer_id == 0) {
						coalesce_timer_id = Timeout.add(MONITOR_COALESCE_MS,() => {
								return drain_coalesced_paths();
						});
				}
		}

// Drain all pending monitor paths — called every MONITOR_COALESCE_MS.
// Returns Source.CONTINUE if the timer should keep running.
		private bool drain_coalesced_paths() {
				int total_pending =(int) pending_monitor_paths.size();

				if(total_pending == 0) {
						// No pending files. If no threads are active either, finalise.
						if(active_monitor_threads == 0) {
								if(monitor_burst_mode) {
										finish_monitor_burst();
								}
								coalesce_timer_id = 0;
								return Source.REMOVE;
						}
						return Source.CONTINUE;
				}

				// Count how many OCR slots are free this cycle.
				int slots = MAX_MONITOR_THREADS - active_monitor_threads;
				if(slots <= 0) {
						// All slots busy — just keep timer running.
						return Source.CONTINUE;
				}

				// Pop paths from the hash table.  Collect keys once and iterate
				// with an index — this avoids infinite re-queuing when a file
				// is unstable (the old get_keys_as_array()[0] + continue pattern
				// would spin forever on the same path, blocking the main loop).
				var keys = pending_monitor_paths.get_keys_as_array();
				int started_this_cycle = 0;
				for(int i = 0; i < keys.length && started_this_cycle < slots; i++) {
						unowned string path = keys[i];

						// Defense-in-depth: skip null/empty keys (shouldn't happen,
						// but guard against corrupted HashTable entries).
						if(path == null || path.length == 0) {
								warning("[ScannerService] drain_coalesced_paths removing null/empty key");
								pending_monitor_paths.remove(path);
								pending_monitor_sizes.remove(path);
								continue;
						}

						// ── File stability check (size-based) ──
						// Instead of relying on mtime (which isn't updated during
						// buffered writes), we track file size across cycles.
						// A file is "stable" when its size hasn't changed between
						// two consecutive drain checks AND size > 0.
						//
						// If the path has been pending for more than 30 seconds,
						// process it anyway to avoid deadlock.
						int64 now_us = GLib.get_monotonic_time();
						int64 queued_us = pending_monitor_paths.lookup(path) ?? 0;
						int64 age_us = now_us - queued_us;
						bool is_stale =(age_us > 30000000); // 30 seconds max wait

						if(!is_stale) {
								int64 cur_size = get_file_size_main(path);
								if(cur_size < 0) {
										// File doesn't exist or can't be queried —
										// leave in queue, retry next cycle.
										debug("[ScannerService] File not yet queryable, retrying: %s", path);
										continue;
								}
								if(cur_size == 0) {
										// File exists but is empty — still being written.
										debug("[ScannerService] File is empty, retrying: %s", path);
										continue;
								}

								int64? prev_size = pending_monitor_sizes.lookup(path);
								if(prev_size == null) {
										// First time we've checked this file's size.
										// Record it and wait for the next cycle to
										// confirm stability.
										pending_monitor_sizes.insert(path, cur_size);
										debug("[ScannerService] First size check for %s (%lld bytes), waiting for stability", path, cur_size);
										continue;
								}

								if(cur_size != prev_size) {
										// Size changed since last check — file is
										// still being written.
										pending_monitor_sizes.insert(path, cur_size);
										debug("[ScannerService] File size changed (%lld → %lld), retrying: %s", prev_size, cur_size, path);
										continue;
								}

								// Size is stable (> 0 and unchanged from last check).
								// File is ready for OCR.
								debug("[ScannerService] File stable, starting OCR: %s (%lld bytes)", path, cur_size);
						}

						// CRITICAL: Copy the path BEFORE removing from the hash table.
						// get_keys_as_array() returns borrowed pointers to the hash
						// table's internal key strings.  Calling remove() frees the
						// key, making 'path' a dangling pointer.  We must dup() first.
						string owned_path = path;
						pending_monitor_paths.remove(path);
						pending_monitor_sizes.remove(path);

						if(scanning && !monitor_burst_mode) {
								// Full scan running — postpone.  Re-insert so the
								// file is picked up when the full scan finishes.
								pending_monitor_paths.insert(owned_path, now_us);
								break;
						}

						start_monitor_ocr(owned_path);
						started_this_cycle++;
				}

				if(started_this_cycle == 0) {
						return Source.CONTINUE;
				}

				// Recalculate the grand total: processed + in-flight + pending.
				int real_total = monitor_processed_total + active_monitor_threads
												+(int) pending_monitor_paths.size();

				// Burst detection.
				if(!monitor_burst_mode && real_total >= MONITOR_BURST_THRESHOLD) {
						monitor_burst_mode = true;
						monitor_queued_total = real_total;
						monitor_processed_total = 0;
						scan_started(monitor_queued_total);
						scan_progress(0, monitor_queued_total);
						// Emit a generic folder row so the popover shows something.
						scan_folder_started(_("New files"), monitor_queued_total);
				} else if(monitor_burst_mode) {
						// Update the running total.
						monitor_queued_total = real_total;
						scan_progress(monitor_processed_total, monitor_queued_total);
						scan_folder_progress(_("New files"), monitor_processed_total,
																	monitor_queued_total);
				}

				return Source.CONTINUE;
		}

// Process one monitor-triggered file: run OCR in a background thread
// and save results on the main thread.  This keeps the UI responsive —
// the coalesce timer never blocks, even when OCR takes 200ms+ per file.
		private void start_monitor_ocr(string path) {
				// Defense-in-depth: validate path before OCR.
				// (Path is already validated by queue_monitor_path and
				// on_monitor_changed; this is a safety net.)
				if(path == null || path.length < 5 || !path.contains("/")) {
						warning("[ScannerService] start_monitor_ocr ignoring invalid path: '%s'", path ?? "null");
						return;
				}

				active_monitor_threads++;

				// Capture main-thread-only values before entering the thread.
				// SettingsService is not thread-safe; all GSettings calls must
				// happen on the main thread.
				string accuracy = settings.get_ocr_accuracy();
				string language = settings.get_ocr_language();
				string? folder_path = find_folder_for_path(path);

				new Thread<void*>("monitor-ocr",() => {
						// ── Background thread ──
						debug("[ScannerService] OCR thread starting for: %s", path);
						string text = ocr.extract_text(path);
						int64 file_created_at = get_file_created_time_bg(path);
						int64 file_size = get_file_size_bg(path);
						string mime_type = Utils.guess_mime_type(path);
						debug("[ScannerService] OCR thread done: %s (%lld bytes, %d chars of text)", path, file_size, text.length);

						var entry = new ScanEntryData();
						entry.path = path;
						entry.text_content = text;
						entry.accuracy_level = accuracy;
						entry.ocr_language = language;
						entry.scanned_at = new DateTime.now_utc().to_unix();
						entry.file_created_at = file_created_at;
						entry.file_size = file_size;
						entry.mime_type = mime_type;
						entry.folder_path = folder_path;

						// Post result to main thread for DB write + UI update
						Idle.add(() => {
								active_monitor_threads--;
								debug("[ScannerService] Saving monitor OCR result for: %s", path);
								save_monitor_result(entry);

								if(monitor_burst_mode) {
										monitor_processed_total++;
										scan_progress(monitor_processed_total, monitor_queued_total);

										if(monitor_processed_total >= monitor_queued_total
												&& pending_monitor_paths.size() == 0) {
												finish_monitor_burst();
										}
								}

								// If new paths arrived while this thread was running,
								// the coalesce timer may have stopped — restart it.
								if(pending_monitor_paths.size() > 0 && coalesce_timer_id == 0) {
										coalesce_timer_id = Timeout.add(MONITOR_COALESCE_MS,() => {
												return drain_coalesced_paths();
										});
								}

								return Source.REMOVE;
						});

						return null;
				});
		}

// End burst mode and hide the progress pie / popover.
		private void finish_monitor_burst() {
				if(!monitor_burst_mode) return;
				monitor_burst_mode = false;
				scan_completed(monitor_processed_total, monitor_queued_total);
				monitor_queued_total = 0;
				monitor_processed_total = 0;
		}

// Called when the file monitor detects a deletion.
		private void process_deleted_file(string path) {
				// If this path was queued for OCR, remove it now.
				pending_monitor_paths.remove(path);
				pending_monitor_sizes.remove(path);

				// Queue the deletion so it is processed on the main thread in batches.
				var entry = new ScanEntryData();
				entry.is_deleted = true;
				entry.path = path.make_valid(-1);
				result_queue.push(entry);

				if(drain_timeout_id == 0) {
						drain_timeout_id = Timeout.add(50,() => {
								return drain_result_queue();
						});
				}
		}

		private string? find_folder_for_path(string file_path) {
				var folders = settings.get_folders();
				string? best_match = null;
				foreach(string folder_path in folders) {
						if(file_path.has_prefix(folder_path)) {
								if(best_match == null || folder_path.length > best_match.length) {
										best_match = folder_path;
								}
						}
				}
				return best_match;
		}

		private void save_monitor_result(ScanEntryData entry) {
				var image = new ImageEntry();
				image.path = entry.path;
				image.text_content = entry.text_content;
				image.scanned_at = entry.scanned_at;
				image.accuracy_level = entry.accuracy_level;
				image.ocr_language = entry.ocr_language;
				image.file_size = entry.file_size;
				image.mime_type = entry.mime_type;
				image.file_created_at = entry.file_created_at;

				if(entry.folder_path != null) {
						int64 folder_id = database.get_folder_id(entry.folder_path);
						if(folder_id >= 0) {
								image.folder_id = folder_id;
						}
				}

				database.save_image(image, true);
				// Reliable ID lookup — see comment above
				int64 saved_id = database.get_image_id_by_path(entry.path);
				if(saved_id >= 0) {
						database.save_ocr_models(saved_id, entry.ocr_language, entry.accuracy_level);
				}
				file_saved(image);
		}
}

// Simple data class pushed from background thread to main thread via AsyncQueue.
// Avoids creating per-file closures — one object per result, drained in batches.
private class ScanEntryData : Object {
		public string path { get; set; }
		public string text_content { get; set; }
		public string accuracy_level { get; set; }
		public string ocr_language { get; set; }
		public int64 scanned_at { get; set; }
		public int64 file_created_at { get; set; }
		public int64 file_size { get; set; }
		public string mime_type { get; set; }
		public string? folder_path { get; set; }  // which folder this file belongs to
		public bool is_done { get; set; }    // sentinel: scan complete
		public bool is_collection_done { get; set; }  // sentinel: file discovery complete
		public bool is_deleted { get; set; } // sentinel: file deletion request
		public bool is_cleanup_progress { get; set; } // sentinel: cleanup progress tick
		// Fields for collection_done entry — grand totals and per-folder counts
		public int scan_total { get; set; }
		public int scan_skipped { get; set; }
		public string[] folder_paths_arr { get; set; }
		public int[] folder_counts_arr { get; set; }  // parallel to folder_paths_arr: new-file count per folder
		// Fields for cleanup progress entry
		public int cleanup_current { get; set; }
		public int cleanup_total { get; set; }
}

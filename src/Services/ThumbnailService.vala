// ThumbnailService generates and caches image thumbnails in memory.
//
// Uses Glycin for image decoding. Decoded at thumbnail size via
// Gly.FrameRequest.set_scale() — full-resolution pixels are never
// materialised in this process.
//
// All calls are synchronous. The scaled decode is fast and the in-memory
// LRU cache avoids repeated work during scrolling.
public class ThumbnailService : Object {

		public const int SIZE_LIST = 48;
		public const int SIZE_GRID = 200;
		public const int SIZE_PREVIEW = 250;

		private const int MAX_CACHE_ENTRIES = 200;

		private HashTable<string, Gdk.Texture?> cache;
		private List<string> access_order;
		private Mutex cache_mutex = Mutex();

		public delegate void ThumbnailReadyCb(Gdk.Texture? texture);

		public ThumbnailService() {
				cache = new HashTable<string, Gdk.Texture?>(str_hash, str_equal);
				access_order = new List<string>();
		}

// Generate (or return from cache) a thumbnail for the given image path.
// Decodes at thumbnail size (not full resolution). Thread-safe via cache_mutex.
		public Gdk.Texture? generate_thumbnail(string? path, int size) {
				if(path == null || path.length == 0) return null;

				var source = File.new_for_path(path);
				if(!source.query_exists()) return null;

				var key = "%s:%d".printf(path, size);

				cache_mutex.lock();
				var cached = cache.lookup(key);
				if(cached != null) {
						record_access_locked(key);
						cache_mutex.unlock();
						return cached;
				}
				cache_mutex.unlock();

				try {
						var loader = new Gly.Loader(source);
						var image = loader.load();
						if(image == null) return null;

						uint32 orig_w = image.get_width();
						uint32 orig_h = image.get_height();
						if(orig_w == 0 || orig_h == 0) return null;

						Gdk.Texture? texture;
						if(orig_w <= size && orig_h <= size) {
								var frame = image.next_frame();
								if(frame == null) return null;
								texture = GlyGtk4.frame_get_texture(frame);
						} else {
								double scale = double.min((double) size / orig_w,(double) size / orig_h);
								uint32 new_w =(uint32) int.max(1,(int)(orig_w * scale));
								uint32 new_h =(uint32) int.max(1,(int)(orig_h * scale));
								var req = new Gly.FrameRequest();
								req.set_scale(new_w, new_h);
								var frame = image.get_specific_frame(req);
								if(frame == null) return null;
								texture = GlyGtk4.frame_get_texture(frame);
						}
						if(texture != null) add_to_cache(key, texture);
						return texture;
				} catch(Error e) {
						return null;
				}
		}

		public void request_thumbnail(string? path, int size, owned ThumbnailReadyCb cb) {
				cb(generate_thumbnail(path, size));
		}

		private void add_to_cache(string key, Gdk.Texture texture) {
				cache_mutex.lock();
				if(cache.size() >= MAX_CACHE_ENTRIES) {
						unowned var oldest = access_order.last();
						if(oldest != null) {
								cache.remove(oldest.data);
								access_order.remove(oldest.data);
						}
				}
				cache.insert(key, texture);
				access_order.prepend(key);
				cache_mutex.unlock();
		}

		private void record_access_locked(string key) {
				access_order.remove(key);
				access_order.prepend(key);
		}

		public void clear_cache() {
				cache_mutex.lock();
				cache.remove_all();
				access_order = new List<string>();
				cache_mutex.unlock();
		}
}

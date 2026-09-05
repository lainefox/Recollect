// TesseractModel — represents a downloadable Tesseract OCR language/script model.
// Variants (Fast, Balanced, Best) are attached to the model.
public class TesseractModel : Object {
		public string code { get; construct; }
		public string display_name { get; set; }
		public GenericArray<TesseractModelVariant> variants { get; construct; }
		// All quality variants currently installed for this code. Multiple
		// variants can coexist (each lives in its own subdir), so this is a
		// list rather than a single value.
		public GenericArray<string> installed_variants = new GenericArray<string>();

		public TesseractModel(string code, string display_name) {
				Object(
						code: code,
						display_name: display_name,
						variants: new GenericArray<TesseractModelVariant>()
				);
		}

		public void add_variant(TesseractModelVariant variant) {
				variants.add(variant);
		}

		public bool has_variant(string name) {
				for(uint i = 0; i < installed_variants.length; i++) {
						if(installed_variants.get(i) == name) return true;
				}
				return false;
		}

		public void add_installed_variant(string name) {
				if(!has_variant(name)) {
						installed_variants.add(name);
				}
		}

		public void remove_installed_variant(string name) {
				for(uint i = 0; i < installed_variants.length; i++) {
						if(installed_variants.get(i) == name) {
								installed_variants.remove_index(i);
								return;
						}
				}
		}

		public void set_installed_variants(string[] names) {
				installed_variants = new GenericArray<string>();
				foreach(unowned string n in names) {
						installed_variants.add(n);
				}
		}
}

public class TesseractModelVariant : Object {
		public string name { get; construct; }
		public int64 size { get; construct; }
		public string download_url { get; construct; }

		public TesseractModelVariant(string name, int64 size, string download_url) {
				Object(name: name, size: size, download_url: download_url);
		}
}

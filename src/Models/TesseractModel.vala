// TesseractModel — represents a downloadable Tesseract OCR language/script model.
// Variants (Fast, Balanced, Best) are attached to the model.
public class TesseractModel : Object {
		public string code { get; construct; }
		public string display_name { get; set; }
		public GenericArray<TesseractModelVariant> variants { get; construct; }
		public string? installed_variant { get; set; }

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
}

public class TesseractModelVariant : Object {
		public string name { get; construct; }
		public int64 size { get; construct; }
		public string download_url { get; construct; }

		public TesseractModelVariant(string name, int64 size, string download_url) {
				Object(name: name, size: size, download_url: download_url);
		}
}

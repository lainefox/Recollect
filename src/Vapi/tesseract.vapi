[CCode (cheader_filename = "tesseract/capi.h", lower_case_cprefix = "Tess")]
namespace Tesseract {
    [CCode (cname = "TessPageSegMode", cprefix = "PSM_", has_type_id = false)]
    public enum PageSegMode {
        OSD_ONLY,
        AUTO_OSD,
        AUTO_ONLY,
        AUTO,
        SINGLE_COLUMN,
        SINGLE_BLOCK_VERT_TEXT,
        SINGLE_BLOCK,
        SINGLE_LINE,
        SINGLE_WORD,
        CIRCLE_WORD,
        SINGLE_CHAR,
        SPARSE_TEXT,
        SPARSE_TEXT_OSD,
        RAW_LINE,
        COUNT
    }

    [CCode (cname = "TessBaseAPI", free_function = "TessBaseAPIDelete")]
    [Compact]
    public class BaseAPI {
        [CCode (cname = "TessBaseAPICreate")]
        public static BaseAPI create ();

        [CCode (cname = "TessBaseAPIDelete")]
        public void delete ();

        [CCode (cname = "TessBaseAPIInit3")]
        public int init (string? datapath, string? language);

        [CCode (cname = "TessBaseAPISetImage")]
        public void set_image ([CCode(array_length = false)] uint8[] imagedata, int width, int height, int bytes_per_pixel, int bytes_per_line);

        [CCode (cname = "TessBaseAPISetPageSegMode")]
        public void set_page_seg_mode (Tesseract.PageSegMode mode);

        [CCode (cname = "TessBaseAPIGetUTF8Text")]
        public unowned string? get_utf8_text ();

        [CCode (cname = "TessBaseAPIRecognize")]
        public int recognize (void* monitor = null);

        [CCode (cname = "TessBaseAPIClear")]
        public void clear ();

        [CCode (cname = "TessBaseAPIEnd")]
        public void end ();

        [CCode (cname = "TessBaseAPISetVariable")]
        public int set_variable (string name, string value);

        [CCode (cname = "TessBaseAPIGetStringVariable")]
        public unowned string? get_string_variable (string name);

        [CCode (cname = "TessBaseAPIGetIntVariable")]
        public int get_int_variable (string name);

        [CCode (cname = "TessBaseAPIGetDoubleVariable")]
        public double get_double_variable (string name);
    }

    [CCode (cname = "TessDeleteText")]
    public void delete_text (string text);
}

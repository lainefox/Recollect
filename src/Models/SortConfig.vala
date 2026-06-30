// Sorting options for search results. Gom property names
// use underscores (e.g. file_created_at) while SQL columns use
// hyphens (e.g. file-created-at).
public enum SortCriteria {
	NAME,
	DATE;

	public string to_display_string() {
		switch(this) {
			case NAME:
				return "Alphabetically";
			case DATE:
				return "Date";
			default:
				return "Date";
		}
	}

	// GObject property name used for Gom.Sorting
	public string to_property_name() {
		switch(this) {
			case NAME:
				return "path";
			case DATE:
				return "file_created_at";
			default:
				return "file_created_at";
		}
	}

	// SQL column name used for raw SQL queries
	public string to_column_name() {
		switch(this) {
			case NAME:
				return "path";
			case DATE:
				return "file-created-at";
			default:
				return "file-created-at";
		}
	}
}

public enum SortDirection {
	ASCENDING,
	DESCENDING;

	public string to_display_string() {
		return this == ASCENDING ? "Ascending" : "Descending";
	}

	public string to_sql() {
		return this == ASCENDING ? "ASC" : "DESC";
	}

	public Gom.SortingMode to_gom_mode() {
		return this == ASCENDING ? Gom.SortingMode.ASCENDING : Gom.SortingMode.DESCENDING;
	}
}

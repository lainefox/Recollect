using GLib;

[CCode (has_type_id = false, cprefix = "Gom", gir_namespace = "Gom", lower_case_cprefix = "gom_")]
namespace Gom {
	[CCode (cheader_filename = "gom.h", type_id = "gom_filter_get_type ()")]
	public class Filter: GLib.Object {
		public FilterMode mode {[CCode (cname = "gom_filter_get_mode_x")] get;construct;}
		[CCode (has_construct_function = false)]
		public Filter (){
			Object ();
		}
		[CCode (cname = "gom_filter_get_mode_x")]
		public FilterMode get_mode ();
		public string get_sql (GLib.HashTable<string, string> table_map);
		public GLib.Array<GLib.Value> get_values ();
		public Filter.sql (string sql, GLib.Array<GLib.Value> values);
		public Filter.or (Filter left, Filter right);
		public Filter.or_full (Filter first, ...);
		public Filter.or_fullv ([CCode (array_null_terminated = true)] Filter[] filter_array);
		public Filter.and (Filter left, Filter right);
		public Filter.and_full (Filter first, ...);
		public Filter.and_fullv ([CCode (array_null_terminated = true)] Filter[] filter_array);
		public Filter.eq (GLib.Type resource_type, string property_name, GLib.Value value);
		public Filter.neq (GLib.Type resource_type, string property_name, GLib.Value value);
		public Filter.gt (GLib.Type resource_type, string property_name, GLib.Value value);
		public Filter.gte (GLib.Type resource_type, string property_name, GLib.Value value);
		public Filter.lt (GLib.Type resource_type, string property_name, GLib.Value value);
		public Filter.lte (GLib.Type resource_type, string property_name, GLib.Value value);
		public Filter.like (GLib.Type resource_type, string property_name, GLib.Value value);
		public Filter.glob (GLib.Type resource_type, string property_name, GLib.Value value);
		public Filter.is_null (GLib.Type resource_type, string property_name);
		public Filter.is_not_null (GLib.Type resource_type, string property_name);
	}
	[CCode (cheader_filename = "gom.h", has_target = true)]
	public delegate bool RepositoryMigrator (Repository repository, Adapter adapter, uint version) throws GLib.Error;
	[CCode (cheader_filename = "gom.h", type_id = "gom_repository_get_type ()")]
	public class Repository: GLib.Object {
		[CCode (has_construct_function = false)]
		public Repository (Adapter adapter);
		public Adapter adapter {[CCode (cname = "gom_repository_get_adapter_x")] get;construct;}
		/* sync func */
		[CCode (cname = "gom_repository_get_adapter_x")]
		public Adapter get_adapter ();
		public bool migrate_sync (uint version, RepositoryMigrator migrator) throws GLib.Error;
        public bool automatic_migrate_sync (uint version, owned GLib.List<GLib.Type> object_types) throws GLib.Error;
        public Resource? find_one_sync (GLib.Type resource_type, Filter? filter = null) throws GLib.Error;
		public ResourceGroup? find_sync (GLib.Type resource_type, Filter? filter = null) throws GLib.Error;
		public ResourceGroup? find_sorted_sync (GLib.Type resource_type, Filter? filter = null, Sorting? sorting = null) throws GLib.Error;
		/* async func */
		public async bool migrate_async (uint version, RepositoryMigrator migrator) throws GLib.Error;
        public async bool automatic_migrate_async (uint version, owned GLib.List<GLib.Type> object_types) throws GLib.Error;
		public async Resource? find_one_async (GLib.Type resource_type, Filter? filter = null) throws GLib.Error;
		public async ResourceGroup? find_async (GLib.Type resource_type, Filter? filter = null) throws GLib.Error;
		public async ResourceGroup? find_sorted_async (GLib.Type resource_type, Filter? filter = null, Sorting? sorting = null) throws GLib.Error;
	}
	[CCode (cheader_filename = "gom.h", type_id = "gom_resource_get_type ()")]
	public class Resource : GLib.Object {
		public Repository repository {[CCode(cname = "gom_resource_get_repository_x")] get;
			                          [CCode(cname = "gom_resource_set_repository_x")] set;}
		[CCode (has_construct_function = false)]
		public Resource () {
			Object ();
		}
		/* class properties */
		public class char table[64];
		public class char primary_key[64];
		/* class func */
		[CCode(cname = "gom_resource_set_repository_x")]
		void set_repository (Repository? repository);
		[CCode(cname = "gom_resource_get_repository_x")]
		Repository? get_repository ();
		[CCode (cname = "gom_resource_class_set_table")]
		public class void set_table (string table);
		[CCode (cname = "gom_resource_class_set_primary_key")]
		public class void set_primary_key (string primary_key);
		[CCode (cname = "gom_resource_class_set_property_new_in_version")]
		public class void set_property_new_in_version (string property_name, int version);
		[CCode (cname = "gom_resource_class_set_reference")]
		public class void set_reference (string property_name, string ref_table_name, string ref_property_name);
		[CCode (cname = "gom_resource_class_set_unique")]
		public class void set_unique (string property_name);
		[CCode (cname = "gom_resource_class_set_notnull")]
		public class void set_notnull (string property_name);
		[CCode (cname = "gom_resource_class_set_mapped")]
		public class void set_mapped (string property_name, bool is_mapped);
		/* sync func */
        public bool delete_sync () throws GLib.Error;
        public bool save_sync () throws GLib.Error;
        /* async func */
		public async bool delete_async () throws GLib.Error;
        public async void save_async (GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async ResourceGroup fetch_m2m_async (GLib.Type resource_type, string m2m_table, Filter filter) throws GLib.Error;
	}
	[CCode (cheader_filename = "gom.h", type_id = "gom_resource_group_get_type ()")]
	public class ResourceGroup: GLib.Object {
		public uint size {
			get {return count;}
		}
		public uint count {get;construct;}
		public Filter filter {[CCode (cname = "gom_resource_group_get_filter_x")] get;construct;}
		public Sorting sorting {[CCode (cname = "gom_resource_group_get_sorting_x")] get;construct;}
		public GLib.Type resource_type {[CCode (cname = "gom_resource_group_get_resource_type_x")] get;construct;}
		public GLib.Type m2m_type {[CCode (cname = "gom_resource_group_get_m2m_type_x")] get;construct;}
		public bool is_writable {get;construct;}
		public Repository repository {[CCode (cname = "gom_resource_group_get_repository_x")] get;construct;}
		[CCode (has_construct_function = false)]
		public ResourceGroup (Repository repository);
		/* sync func */
		public bool append (Resource resource);
		public bool write_sync () throws GLib.Error;
		public bool delete_sync () throws GLib.Error;
		public bool fetch_sync (uint index_, uint count) throws GLib.Error;
		public uint get_count ();
		public unowned Resource get_index (uint index_);
		public unowned Resource get (uint index) {
			return get_index (index);
	    }
		public string get_m2m_table ();
		[CCode (cname = "gom_resource_group_get_sorting_x")] 
		public Sorting get_sorting ();
		[CCode (cname = "gom_resource_group_get_filter_x")] 
		public Filter get_filter ();
		[CCode (cname = "gom_resource_group_get_resource_type_x")] 
		public GLib.Type get_resource_type ();
		[CCode (cname = "gom_resource_group_get_m2m_type_x")] 
		public GLib.Type get_m2m_type ();
		[CCode (cname = "gom_resource_group_get_repository_x")] 
		public Repository get_repository ();
		public bool get_is_writable ();
		/* async func */
		public async bool write_async () throws GLib.Error;
        public async bool delete_async () throws GLib.Error;
		public async bool fetch_async (uint index_, uint count) throws GLib.Error;
	}
	[CCode (cheader_filename = "gom.h", cprefix = "GOM_SORTING_", has_type_id = true, type_id = "gom_sorting_mode_get_type ()")]
	public enum SortingMode {
		ASCENDING,
		DESCENDING
	}
	[CCode (cheader_filename = "gom.h", type_id = "gom_sorting_get_type ()")]
	public class Sorting: GLib.Object {
		[CCode (has_construct_function = false)]
        public Sorting (GLib.Type first_resource_type, string first_property_name, SortingMode  first_sorting_mode, ...);
		public string get_sql (GLib.HashTable<string, string> table_map);
		public void add (GLib.Type resource_type, string property_name, SortingMode sorting_mode);
	}
	[CCode (cheader_filename = "gom.h", has_target = true)]
	public delegate void AdapterCallback (Adapter adapter);
	[CCode (cheader_filename = "gom.h", type_id = "gom_adapter_get_type ()")]
	public class Adapter: GLib.Object {
		[CCode (has_construct_function = false)]
		public Adapter () {
			Object ();
		}
		/* sync func */
		public bool close_sync () throws GLib.Error;
		public bool open_sync (string uri) throws GLib.Error;
		public void queue_read (AdapterCallback callback);
		public void queue_write (AdapterCallback callback);
		public bool execute_sql (string sql) throws GLib.Error;
		/* async func */
		public async bool close_async () throws GLib.Error;
		public async bool open_async (string uri) throws GLib.Error;
	}
	[CCode (cheader_filename = "gom.h", type_id = "gom_cursor_get_type ()")]
	public class Cursor: GLib.Object {
		[CCode (has_construct_function = false)]
		public Cursor () {
			Object ();
		}
		public string get_column_name (uint column);
		public uint get_n_columns ();
		public void get_column (uint column, GLib.Value value);
		public bool get_column_boolean (uint column);
		public double get_column_double (uint column);
		public float get_column_float (uint column);
		public int get_column_int (uint column);
		public int64 get_column_int64 (uint column);
		public string get_column_string (uint column);
		public uint get_column_uint (uint column);
		public uint64 get_column_uint64 (uint column);
		[CCode (cname = "gom_cursor_next")]
		public bool next ();
	}
	[CCode (cheader_filename = "gom.h", cprefix = "GOM_ERROR_", has_type_id = true, type_id = "gom_error_get_type ()")]
	public errordomain Error {
		ADAPTER_OPEN,
		COMMAND_NO_SQL,
		COMMAND_SQLITE,
		REPOSITORY_EMPTY_RESULT,
		RESOURCE_CURSOR,
		COMMAND_NO_REPOSITORY;
		public static GLib.Quark quark ();
	}
	[CCode (cheader_filename = "gom.h", type_id = "gom_command_get_type ()")]
	public class Command: GLib.Object {
		public string sql {set;}
		public Adapter adapter {get;construct;}
		[CCode (has_construct_function = false)]
		public Command () {
			Object ();
		}
		public bool execute (out Cursor cursor) throws GLib.Error;
		public void set_sql (string sql);
		public Adapter get_adapter ();
		public int get_param_index (string param_name);
		public void reset ();
		public void set_param (uint param, GLib.Value value);
		public void set_param_double (uint param, double value);
		public void set_param_float (uint param, float value);
		public void set_param_int (uint param, int value);
		public void set_param_int64 (uint param, int64 value);
		public void set_param_uint (uint param, uint value);
		public void set_param_uint64 (uint param, uint64 value);
		public void set_param_string (uint param, string value);
	}
	[CCode (cheader_filename = "gom.h", type_id = "gom_command_builder_get_type ()")]
	public class CommandBuilder: GLib.Object {
		public Adapter adapter {[CCode (cname = "gom_command_get_adapter_x")] get;construct;}
		public Filter filter {get;set;}
		public Sorting sorting {get;set;}
		public uint limit {get;set;}
		public string m2m_table {get;construct;}
		public GLib.Type m2m_type {get;construct;}
		public GLib.Type resource_type {get;set;}
		public uint offset {get;set;}
		public Command build_count ();
		public Command build_delete ();
		public Command build_select ();
		public Command build_insert (Resource resource);
		public Command build_update (Resource resource);
		public GLib.List build_create (uint version);
		public GLib.Type get_resource_type ();
		public GLib.Type get_m2m_type ();
		public string get_m2m_table ();
		public uint get_limit ();
		public uint get_offset ();
		public Filter get_filter ();
		[CCode (cname = "gom_command_get_adapter_x")]
		public Adapter get_adapter ();
		public Sorting get_sorting ();
		public void set_sorting (Sorting sorting);
		public void set_limit (uint limit);
		public void set_offset (uint offset);
		public void set_filter (Filter filter);
		public void set_resource_type (GLib.Type resource_type);
	}
	[CCode (cheader_filename = "gom.h", cprefix = "GOM_FILTER_", has_type_id = true, type_id = "gom_filter_mode_get_type ()")]
	public enum FilterMode {
		SQL,
		Cor,
		AND,
		EQ,
		NEQ,
		GT,
		GTE,
		LT,
		LTE,
		LIKE,
		GLOB,
		IS_NULL,
		IS_NOT_NULL
	}
}

[CCode (cheader_filename = "archive.h,archive_entry.h")]
namespace LA {
    [CCode (cname = "ARCHIVE_EOF")]
    public const int EOF;
    [CCode (cname = "ARCHIVE_OK")]
    public const int OK;
    [CCode (cname = "ARCHIVE_RETRY")]
    public const int RETRY;
    [CCode (cname = "ARCHIVE_WARN")]
    public const int WARN;
    [CCode (cname = "ARCHIVE_FAILED")]
    public const int FAILED;
    [CCode (cname = "ARCHIVE_FATAL")]
    public const int FATAL;

    [CCode (cname = "ARCHIVE_EXTRACT_TIME")]
    public const int EXTRACT_TIME;
    [CCode (cname = "ARCHIVE_EXTRACT_PERM")]
    public const int EXTRACT_PERM;
    [CCode (cname = "ARCHIVE_EXTRACT_SECURE_SYMLINKS")]
    public const int EXTRACT_SECURE_SYMLINKS;
    [CCode (cname = "ARCHIVE_EXTRACT_SECURE_NODOTDOT")]
    public const int EXTRACT_SECURE_NODOTDOT;
    [CCode (cname = "ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS")]
    public const int EXTRACT_SECURE_NOABSOLUTEPATHS;
    [CCode (cname = "ARCHIVE_EXTRACT_UNLINK")]
    public const int EXTRACT_UNLINK;

    [CCode (cname = "AE_IFREG")]
    public const uint IFREG;
    [CCode (cname = "AE_IFDIR")]
    public const uint IFDIR;
    [CCode (cname = "AE_IFLNK")]
    public const uint IFLNK;

    [CCode (cname = "archive_passphrase_callback", has_target = false)]
    public delegate unowned string? PassphraseCallback (void* archive, void* client_data);
    [CCode (cname = "archive_open_callback", has_target = false)]
    public delegate int OpenCallback (void* archive, void* client_data);
    [CCode (cname = "archive_write_callback", has_target = false)]
    public delegate ssize_t WriteCallback (void* archive, void* client_data, void* buffer, size_t length);
    [CCode (cname = "archive_close_callback", has_target = false)]
    public delegate int CloseCallback (void* archive, void* client_data);
    [CCode (cname = "archive_free_callback", has_target = false)]
    public delegate int FreeCallback (void* archive, void* client_data);

    [CCode (cname = "archive_read_callback", has_target = false)]
    public delegate ssize_t ReadCallback (void* archive, void* client_data, out void* buffer);
    [CCode (cname = "archive_skip_callback", has_target = false)]
    public delegate int64 SkipCallback (void* archive, void* client_data, int64 request);
    [CCode (cname = "archive_seek_callback", has_target = false)]
    public delegate int64 SeekCallback (void* archive, void* client_data, int64 offset, int whence);

    [Compact]
    [CCode (cname = "struct archive_entry", free_function = "archive_entry_free")]
    public class Entry {
        [CCode (cname = "archive_entry_new")]
        public Entry ();
        [CCode (cname = "archive_entry_pathname")]
        public unowned string? pathname ();
        [CCode (cname = "archive_entry_set_pathname")]
        public void set_pathname (string path);
        [CCode (cname = "archive_entry_size")]
        public int64 size ();
        [CCode (cname = "archive_entry_size_is_set")]
        public int size_is_set ();
        [CCode (cname = "archive_entry_set_size")]
        public void set_size (int64 size);
        [CCode (cname = "archive_entry_filetype")]
        public uint filetype ();
        [CCode (cname = "archive_entry_set_filetype")]
        public void set_filetype (uint type);
        [CCode (cname = "archive_entry_perm")]
        public uint perm ();
        [CCode (cname = "archive_entry_set_perm")]
        public void set_perm (uint perm);
        [CCode (cname = "archive_entry_mtime")]
        public int64 mtime ();
        [CCode (cname = "archive_entry_set_mtime")]
        public void set_mtime (int64 sec, long nsec);
        [CCode (cname = "archive_entry_symlink")]
        public unowned string? symlink ();
        [CCode (cname = "archive_entry_set_symlink")]
        public void set_symlink (string? target);
        [CCode (cname = "archive_entry_hardlink")]
        public unowned string? hardlink ();
        [CCode (cname = "archive_entry_set_hardlink")]
        public void set_hardlink (string? target);
        [CCode (cname = "archive_entry_is_encrypted")]
        public int is_encrypted ();
    }

    [Compact]
    [CCode (cname = "struct archive", free_function = "archive_read_free")]
    public class Reader {
        [CCode (cname = "archive_read_new")]
        public Reader ();
        [CCode (cname = "archive_read_support_filter_all")]
        public int support_filter_all ();
        [CCode (cname = "archive_read_support_format_all")]
        public int support_format_all ();
        [CCode (cname = "archive_read_support_format_raw")]
        public int support_format_raw ();
        [CCode (cname = "archive_read_add_passphrase")]
        public int add_passphrase (string passphrase);
        [CCode (cname = "archive_read_set_passphrase_callback")]
        public int set_passphrase_callback (void* client_data, PassphraseCallback callback);
        [CCode (cname = "archive_read_open_filename")]
        public int open_filename (string path, size_t block_size);
        [CCode (cname = "archive_read_open_filenames")]
        public int open_filenames ([CCode (array_length = false, array_null_terminated = true)] string[] paths, size_t block_size);
        [CCode (cname = "archive_read_set_seek_callback")]
        public int set_seek_callback (SeekCallback callback);
        [CCode (cname = "archive_read_open2")]
        public int open2 (void* client_data, OpenCallback? open, ReadCallback read, SkipCallback? skip, CloseCallback? close);
        [CCode (cname = "archive_read_next_header")]
        public int next_header (out unowned Entry entry);
        [CCode (cname = "archive_read_data")]
        public ssize_t read_data (uint8* buffer, size_t length);
        [CCode (cname = "archive_read_data_skip")]
        public int data_skip ();
        [CCode (cname = "archive_read_has_encrypted_entries")]
        public int has_encrypted_entries ();
        [CCode (cname = "archive_format_name")]
        public unowned string? format_name ();
        [CCode (cname = "archive_filter_count")]
        public int filter_count ();
        [CCode (cname = "archive_filter_name")]
        public unowned string? filter_name (int n);
        [CCode (cname = "archive_filter_bytes")]
        public int64 filter_bytes (int n);
        [CCode (cname = "archive_error_string")]
        public unowned string? error_string ();
        [CCode (cname = "archive_read_close")]
        public int close ();
    }

    [Compact]
    [CCode (cname = "struct archive", free_function = "archive_write_free")]
    public class Writer {
        [CCode (cname = "archive_write_new")]
        public Writer ();
        [CCode (cname = "archive_write_set_format_by_name")]
        public int set_format_by_name (string name);
        [CCode (cname = "archive_write_add_filter_by_name")]
        public int add_filter_by_name (string name);
        [CCode (cname = "archive_write_set_options")]
        public int set_options (string options);
        [CCode (cname = "archive_write_set_passphrase")]
        public int set_passphrase (string passphrase);
        [CCode (cname = "archive_write_set_bytes_in_last_block")]
        public int set_bytes_in_last_block (int bytes);
        [CCode (cname = "archive_write_open_filename")]
        public int open_filename (string path);
        [CCode (cname = "archive_write_open2")]
        public int open2 (void* client_data, OpenCallback? open, WriteCallback write, CloseCallback? close, FreeCallback? free);
        [CCode (cname = "archive_write_header")]
        public int write_header (Entry entry);
        [CCode (cname = "archive_write_data")]
        public ssize_t write_data (uint8* buffer, size_t length);
        [CCode (cname = "archive_write_finish_entry")]
        public int finish_entry ();
        [CCode (cname = "archive_error_string")]
        public unowned string? error_string ();
        [CCode (cname = "archive_write_close")]
        public int close ();
    }

    [Compact]
    [CCode (cname = "struct archive", free_function = "archive_write_free")]
    public class DiskWriter {
        [CCode (cname = "archive_write_disk_new")]
        public DiskWriter ();
        [CCode (cname = "archive_write_disk_set_options")]
        public int set_options (int flags);
        [CCode (cname = "archive_write_header")]
        public int write_header (Entry entry);
        [CCode (cname = "archive_write_data")]
        public ssize_t write_data (uint8* buffer, size_t length);
        [CCode (cname = "archive_write_finish_entry")]
        public int finish_entry ();
        [CCode (cname = "archive_error_string")]
        public unowned string? error_string ();
        [CCode (cname = "archive_write_close")]
        public int close ();
    }
}

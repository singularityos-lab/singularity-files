namespace Singularity.Apps.Files.Archives {

    public errordomain ArchiveError {
        FAILED,
        PASSWORD,
        UNSUPPORTED
    }

    public enum ExtractChoice {
        REPLACE,
        KEEP_BOTH,
        SKIP,
        CANCEL
    }

    public class ArchiveEntryInfo : Object {
        public string path;
        public int64 size;
        public bool is_dir;
        public bool is_link;
        public int64 mtime;
        public bool encrypted;
    }

    public class ArchiveListing : Object {
        public ArchiveKind kind = ArchiveKind.UNKNOWN;
        public string format_name = "";
        public string filter_name = "";
        public GenericArray<ArchiveEntryInfo> entries = new GenericArray<ArchiveEntryInfo>();
        public int files = 0;
        public int folders = 0;
        public int64 uncompressed = 0;
        public int64 compressed = 0;
        public bool encrypted = false;
        public int volumes = 1;

        public string[] top_level() {
            var seen = new GenericSet<string>(str_hash, str_equal);
            string[] result = {};
            foreach (var e in entries.data) {
                string? clean = ArchivePaths.sanitize(e.path);
                if (clean == null) continue;
                string first = clean.split("/")[0];
                if (seen.contains(first)) continue;
                seen.add(first);
                result += first;
            }
            return result;
        }
    }

    public delegate ExtractChoice ConflictResolver(ArchiveEntryInfo entry, string dest_path, out string? new_name);
    public delegate string? PasswordProvider(bool retry);

    public class VolumeStream : Object {
        private int[] fds = {};
        private int64[] starts = {};
        private int64 total = 0;
        private int64 offset = 0;
        private uint8[] buffer = new uint8[65536];

        public VolumeStream(string[] paths) throws Error {
            foreach (unowned string p in paths) {
                int fd = Posix.open(p, Posix.O_RDONLY);
                if (fd < 0) throw new ArchiveError.FAILED(_("Cannot open \"%s\".").printf(Path.get_basename(p)));
                Posix.Stat st;
                Posix.fstat(fd, out st);
                fds += fd;
                starts += total;
                total += (int64) st.st_size;
            }
        }

        ~VolumeStream() {
            foreach (int fd in fds) Posix.close(fd);
        }

        private ssize_t read_block(out void* out_buffer) {
            out_buffer = (void*) buffer;
            if (offset >= total) return 0;
            int i = fds.length - 1;
            while (i > 0 && starts[i] > offset) i--;
            int64 end = i + 1 < fds.length ? starts[i + 1] : total;
            size_t want = (size_t) int64.min(buffer.length, end - offset);
            ssize_t got = Posix.pread(fds[i], buffer, want, (Posix.off_t) (offset - starts[i]));
            if (got < 0) return -1;
            offset += got;
            return got;
        }

        private int64 move_to(int64 request, int whence) {
            int64 target;
            switch (whence) {
                case Posix.SEEK_SET: target = request; break;
                case Posix.SEEK_CUR: target = offset + request; break;
                default: target = total + request; break;
            }
            if (target < 0) return LA.FATAL;
            offset = int64.min(target, total);
            return offset;
        }

        internal static ssize_t read_cb(void* archive, void* data, out void* out_buffer) {
            return ((VolumeStream) data).read_block(out out_buffer);
        }

        internal static int64 skip_cb(void* archive, void* data, int64 request) {
            var self = (VolumeStream) data;
            int64 before = self.offset;
            self.move_to(request, Posix.SEEK_CUR);
            return self.offset - before;
        }

        internal static int64 seek_cb(void* archive, void* data, int64 request, int whence) {
            return ((VolumeStream) data).move_to(request, whence);
        }
    }

    public class ArchiveReader : Object {
        private const size_t BLOCK = 65536;

        internal static bool unsupported_encryption(string? msg) {
            if (msg == null) return false;
            string m = msg.down();
            return m.contains("encrypt") && (m.contains("not supported") || m.contains("not currently supported") || m.contains("unsupported"));
        }

        internal static Error failure(string? msg, string fallback) {
            if (unsupported_encryption(msg)) {
                return new ArchiveError.UNSUPPORTED(_("Files can open password-protected zip archives, but not password-protected 7z or RAR archives yet."));
            }
            return new ArchiveError.FAILED(msg != null && msg != "" ? msg : fallback);
        }

        internal static LA.Reader open_reader(string path, ArchiveKind kind, out VolumeStream? volumes, string? password = null,
                                              void* client = null, LA.PassphraseCallback? callback = null) throws Error {
            volumes = null;
            var r = new LA.Reader();
            r.support_filter_all();
            r.support_format_all();
            if (kind == ArchiveKind.COMPRESSED_FILE) r.support_format_raw();
            if (password != null) r.add_passphrase(password);
            if (callback != null) r.set_passphrase_callback(client, callback);
            string[] parts = ArchiveFormats.volume_paths(path);
            if (parts.length == 0) throw new ArchiveError.FAILED(_("The archive cannot be found."));
            int rc;
            if (parts.length == 1) {
                rc = r.open_filename(parts[0], BLOCK);
            } else {
                volumes = new VolumeStream(parts);
                r.set_seek_callback(VolumeStream.seek_cb);
                rc = r.open2((void*) volumes, null, VolumeStream.read_cb, VolumeStream.skip_cb, null);
            }
            if (rc != LA.OK) throw failure(r.error_string(), _("The archive cannot be opened."));
            return r;
        }

        public static int64 input_size(string path) {
            int64 total = 0;
            foreach (unowned string part in ArchiveFormats.volume_paths(path)) {
                Posix.Stat st;
                if (Posix.stat(part, out st) == 0) total += (int64) st.st_size;
            }
            return total;
        }

        public static ArchiveListing list(string path, string? password = null, Cancellable? cancellable = null) throws Error {
            var listing = new ArchiveListing();
            listing.kind = ArchiveFormats.detect(path);
            listing.compressed = input_size(path);
            listing.volumes = ArchiveFormats.volume_paths(path).length;
            VolumeStream? volumes;
            var r = open_reader(path, listing.kind, out volumes, password);
            unowned LA.Entry entry;
            while (true) {
                if (cancellable != null && cancellable.is_cancelled()) throw new IOError.CANCELLED(_("Cancelled"));
                int rc = r.next_header(out entry);
                if (rc == LA.EOF) break;
                if (rc < LA.WARN) throw failure(r.error_string(), _("The archive is damaged."));
                var info = new ArchiveEntryInfo();
                info.path = entry.pathname() ?? "";
                if (listing.kind == ArchiveKind.COMPRESSED_FILE && (info.path == "data" || info.path == "")) {
                    info.path = ArchiveFormats.stem(Path.get_basename(path));
                }
                uint type = entry.filetype();
                info.is_dir = type == LA.IFDIR;
                info.is_link = type == LA.IFLNK;
                info.size = entry.size_is_set() != 0 ? entry.size() : 0;
                info.mtime = entry.mtime();
                info.encrypted = entry.is_encrypted() != 0;
                if (info.encrypted) listing.encrypted = true;
                if (info.is_dir) listing.folders++;
                else listing.files++;
                listing.uncompressed += info.size;
                listing.entries.add(info);
                r.data_skip();
            }
            if (r.has_encrypted_entries() > 0) listing.encrypted = true;
            listing.format_name = r.format_name() ?? "";
            if (r.filter_count() > 1) listing.filter_name = r.filter_name(0) ?? "";
            r.close();
            return listing;
        }
    }

    public class ArchiveExtractor : Object {
        public string archive_path { get; construct; }
        public string dest_dir { get; construct; }
        public Cancellable? cancellable = null;
        public string? password = null;
        public bool read_only = false;
        public bool use_trash = true;

        public int64 total_bytes = 0;
        public int64 done_bytes = 0;
        public int files = 0;
        public int folders = 0;
        public int skipped = 0;
        public int rejected = 0;
        public string? result_path = null;

        private ConflictResolver? resolver = null;
        private PasswordProvider? provider = null;
        private string? current_pass = null;
        private int pass_requests = 0;
        private bool pass_cancelled = false;
        private GenericArray<string> tops = new GenericArray<string>();
        private GenericArray<string> created_dirs = new GenericArray<string>();

        public ArchiveExtractor(string archive_path, string dest_dir) {
            Object(archive_path: archive_path, dest_dir: dest_dir);
        }

        public void set_resolver(owned ConflictResolver r) {
            resolver = (owned) r;
        }

        public void set_password_provider(owned PasswordProvider p) {
            provider = (owned) p;
        }

        public string[] top_level_names() {
            return tops.data;
        }

        private static unowned string? passphrase_cb(void* archive, void* data) {
            var self = (ArchiveExtractor) data;
            return self.next_passphrase();
        }

        private unowned string? next_passphrase() {
            if (provider == null || pass_cancelled) return null;
            bool retry = pass_requests > 0 || password != null;
            pass_requests++;
            string? answer = provider(retry);
            if (answer == null) {
                pass_cancelled = true;
                return null;
            }
            current_pass = answer;
            return current_pass;
        }

        private void check_cancel() throws Error {
            if (cancellable != null && cancellable.is_cancelled()) throw new IOError.CANCELLED(_("Cancelled"));
        }

        private void note_top(string rel) {
            string first = rel.split("/")[0];
            for (int i = 0; i < tops.length; i++) if (tops[i] == first) return;
            tops.add(first);
        }

        private static bool exists(string path) {
            Posix.Stat st;
            return Posix.lstat(path, out st) == 0;
        }

        private static bool is_real_dir(string path) {
            Posix.Stat st;
            return Posix.lstat(path, out st) == 0 && Posix.S_ISDIR(st.st_mode);
        }

        private void discard(string path) {
            try {
                if (use_trash && File.new_for_path(path).trash(null)) return;
            } catch (Error e) {
            }
            ArchivePaths.remove_tree(path);
        }

        private string password_error(LA.Reader r) {
            string msg = r.error_string() ?? "";
            return msg;
        }

        private void note_missing_dirs(string path, string? stop) {
            string[] missing = {};
            string current = path;
            while (current != "" && current != stop && !exists(current)) {
                missing += current;
                string parent = Path.get_dirname(current);
                if (parent == current) break;
                current = parent;
            }
            for (int i = missing.length - 1; i >= 0; i--) created_dirs.add(missing[i]);
        }

        private void remove_created_dirs() {
            for (int i = (int) created_dirs.length - 1; i >= 0; i--) {
                if (is_real_dir(created_dirs[i])) DirUtils.remove(created_dirs[i]);
            }
            created_dirs.remove_range(0, created_dirs.length);
        }

        public void run() throws Error {
            created_dirs.remove_range(0, created_dirs.length);
            try {
                extract();
            } catch (Error e) {
                remove_created_dirs();
                throw e;
            }
        }

        private void extract() throws Error {
            var kind = ArchiveFormats.detect(archive_path);
            total_bytes = ArchiveReader.input_size(archive_path);
            note_missing_dirs(File.new_for_path(dest_dir).get_path() ?? dest_dir, null);
            DirUtils.create_with_parents(dest_dir, 0755);
            string root = Posix.realpath(dest_dir) ?? dest_dir;
            VolumeStream? volumes;
            var r = ArchiveReader.open_reader(archive_path, kind, out volumes, password, (void*) this, passphrase_cb);
            var disk = new LA.DiskWriter();
            disk.set_options(LA.EXTRACT_TIME | LA.EXTRACT_PERM | LA.EXTRACT_SECURE_SYMLINKS | LA.EXTRACT_SECURE_NODOTDOT);
            uint8[] buffer = new uint8[65536];
            unowned LA.Entry entry;
            while (true) {
                check_cancel();
                int rc = r.next_header(out entry);
                if (rc == LA.EOF) break;
                if (rc < LA.WARN) {
                    if (pass_cancelled) throw new IOError.CANCELLED(_("Cancelled"));
                    throw ArchiveReader.failure(r.error_string(), _("The archive is damaged."));
                }
                done_bytes = r.filter_bytes(-1);
                string raw = entry.pathname() ?? "";
                if (kind == ArchiveKind.COMPRESSED_FILE && (raw == "data" || raw == "")) {
                    raw = ArchiveFormats.stem(Path.get_basename(archive_path));
                }
                string? rel = ArchivePaths.sanitize(raw);
                uint type = entry.filetype();
                if (rel == null) {
                    rejected++;
                    r.data_skip();
                    continue;
                }
                if (type == LA.IFLNK && !ArchivePaths.link_stays_inside(rel, entry.symlink())) {
                    rejected++;
                    r.data_skip();
                    continue;
                }
                string? hard = entry.hardlink();
                if (hard != null) {
                    string? hrel = ArchivePaths.sanitize(hard);
                    if (hrel == null) {
                        rejected++;
                        r.data_skip();
                        continue;
                    }
                    entry.set_hardlink(Path.build_filename(root, hrel));
                }
                string dest = Path.build_filename(root, rel);
                var info = new ArchiveEntryInfo();
                info.path = rel;
                info.size = entry.size_is_set() != 0 ? entry.size() : 0;
                info.is_dir = type == LA.IFDIR;
                info.is_link = type == LA.IFLNK;
                info.mtime = entry.mtime();
                info.encrypted = entry.is_encrypted() != 0;

                if (info.is_dir) {
                    if (is_real_dir(dest)) {
                        folders++;
                        note_top(rel);
                        r.data_skip();
                        continue;
                    }
                }
                if (exists(dest) && !(info.is_dir && is_real_dir(dest))) {
                    string? new_name = null;
                    ExtractChoice choice = resolver != null ? resolver(info, dest, out new_name) : ExtractChoice.SKIP;
                    switch (choice) {
                        case ExtractChoice.CANCEL:
                            throw new IOError.CANCELLED(_("Cancelled"));
                        case ExtractChoice.SKIP:
                            skipped++;
                            r.data_skip();
                            continue;
                        case ExtractChoice.KEEP_BOTH:
                            string candidate = dest;
                            if (new_name != null && new_name.strip() != "" && !new_name.contains("/")) {
                                candidate = Path.build_filename(Path.get_dirname(dest), new_name.strip());
                            }
                            dest = ArchivePaths.unique_sibling(candidate);
                            rel = dest.substring(root.length + 1);
                            break;
                        default:
                            discard(dest);
                            break;
                    }
                }
                note_top(rel);
                note_missing_dirs(info.is_dir ? dest : Path.get_dirname(dest), root);
                entry.set_pathname(dest);
                int wr = disk.write_header(entry);
                if (wr < LA.WARN) {
                    rejected++;
                    r.data_skip();
                    continue;
                }
                if (!info.is_dir && !info.is_link && hard == null) {
                    while (true) {
                        check_cancel();
                        ssize_t got = r.read_data((uint8*) buffer, buffer.length);
                        if (got == 0) break;
                        if (got < 0) {
                            if (pass_cancelled) throw new IOError.CANCELLED(_("Cancelled"));
                            string msg = password_error(r);
                            disk.finish_entry();
                            FileUtils.unlink(dest);
                            if (ArchiveReader.unsupported_encryption(msg)) throw ArchiveReader.failure(msg, "");
                            if (info.encrypted || msg.down().contains("passphrase") || msg.down().contains("encrypt")) {
                                throw new ArchiveError.PASSWORD(msg != "" ? msg : _("The password is not correct."));
                            }
                            throw new ArchiveError.FAILED(msg != "" ? msg : _("The archive is damaged."));
                        }
                        if (disk.write_data((uint8*) buffer, (size_t) got) < 0) {
                            throw new ArchiveError.FAILED(disk.error_string() ?? _("Cannot write the extracted file."));
                        }
                        done_bytes = r.filter_bytes(-1);
                    }
                }
                disk.finish_entry();
                if (info.is_dir) folders++;
                else files++;
            }
            disk.close();
            r.close();
            done_bytes = total_bytes;
            result_path = dest_dir;
            if (read_only) ArchivePaths.set_tree_writable(dest_dir, false);
        }

        public static string extract_here_folder(string archive_path) {
            string dir = Path.get_dirname(archive_path);
            string stem = ArchiveFormats.stem(Path.get_basename(archive_path));
            if (stem == "") stem = _("Archive");
            return ArchivePaths.unique_sibling(Path.build_filename(dir, stem));
        }

        public static string flatten_single_child(string wrapper) {
            string[] names = {};
            try {
                var dir = Dir.open(wrapper);
                unowned string? name;
                while ((name = dir.read_name()) != null) {
                    names += name;
                    if (names.length > 1) return wrapper;
                }
            } catch (FileError e) {
                return wrapper;
            }
            if (names.length != 1) return wrapper;
            string parent = Path.get_dirname(wrapper);
            string target = Path.build_filename(parent, names[0]);
            if (target != wrapper && exists(target)) return wrapper;
            string holder = ArchivePaths.unique_sibling(wrapper + ".extracting");
            if (FileUtils.rename(wrapper, holder) != 0) return wrapper;
            if (FileUtils.rename(Path.build_filename(holder, names[0]), target) != 0) {
                FileUtils.rename(holder, wrapper);
                return wrapper;
            }
            DirUtils.remove(holder);
            return target;
        }
    }

    public class ArchiveCreator : Object {
        public string[] sources;
        public string output_path;
        public ArchiveKind kind = ArchiveKind.ZIP;
        public CompressionLevel level = CompressionLevel.NORMAL;
        public string? password = null;
        public int64 volume_size = 0;
        public Cancellable? cancellable = null;

        public int64 total_bytes = 0;
        public int64 done_bytes = 0;
        public int entries = 0;
        public GenericArray<string> outputs = new GenericArray<string>();

        private int part_fd = -1;
        private int64 part_written = 0;
        private bool split_failed = false;

        public ArchiveCreator(string[] sources, string output_path) {
            this.sources = sources;
            this.output_path = output_path;
        }

        private static int64 walk_size(string path) {
            Posix.Stat st;
            if (Posix.lstat(path, out st) != 0) return 0;
            if (Posix.S_ISLNK(st.st_mode)) return 0;
            if (!Posix.S_ISDIR(st.st_mode)) return (int64) st.st_size;
            int64 total = 0;
            try {
                var dir = Dir.open(path);
                unowned string? name;
                while ((name = dir.read_name()) != null) total += walk_size(Path.build_filename(path, name));
            } catch (FileError e) {
            }
            return total;
        }

        private static ssize_t split_write(void* archive, void* data, void* buffer, size_t length) {
            var self = (ArchiveCreator) data;
            return self.write_part((uint8*) buffer, length);
        }

        private static int split_close(void* archive, void* data) {
            var self = (ArchiveCreator) data;
            self.close_part();
            return LA.OK;
        }

        private ssize_t write_part(uint8* buffer, size_t length) {
            size_t offset = 0;
            while (offset < length) {
                if (part_fd < 0 || part_written >= volume_size) {
                    close_part();
                    string name = "%s.%03d".printf(output_path, outputs.length + 1);
                    part_fd = Posix.open(name, Posix.O_WRONLY | Posix.O_CREAT | Posix.O_TRUNC, 0644);
                    if (part_fd < 0) {
                        split_failed = true;
                        return -1;
                    }
                    outputs.add(name);
                    part_written = 0;
                }
                size_t room = (size_t) (volume_size - part_written);
                size_t chunk = size_t.min(room, length - offset);
                ssize_t wrote = Posix.write(part_fd, buffer + offset, chunk);
                if (wrote != (ssize_t) chunk) {
                    split_failed = true;
                    return -1;
                }
                part_written += (int64) chunk;
                offset += chunk;
            }
            return (ssize_t) length;
        }

        private void check_cancel() throws Error {
            if (cancellable != null && cancellable.is_cancelled()) throw new IOError.CANCELLED(_("Cancelled"));
        }

        private void close_part() {
            if (part_fd >= 0) Posix.close(part_fd);
            part_fd = -1;
        }

        private void cleanup_outputs() {
            close_part();
            foreach (var p in outputs.data) FileUtils.unlink(p);
        }

        public void run() throws Error {
            string? format = kind.writer_format();
            if (format == null) throw new ArchiveError.UNSUPPORTED(_("This format cannot be created."));
            foreach (unowned string s in sources) total_bytes += walk_size(s);
            var w = new LA.Writer();
            if (w.set_format_by_name(format) != LA.OK) throw new ArchiveError.UNSUPPORTED(w.error_string() ?? format);
            string? filter = kind.writer_filter();
            if (filter != null && w.add_filter_by_name(filter) < LA.WARN) {
                throw new ArchiveError.UNSUPPORTED(w.error_string() ?? filter);
            }
            bool encrypt = password != null && password != "";
            if (encrypt && !ArchiveFormats.supports_encryption(kind)) {
                throw new ArchiveError.UNSUPPORTED(_("This format cannot be protected with a password."));
            }
            string opts = ArchiveFormats.options_for(kind, level, encrypt);
            if (opts != "" && w.set_options(opts) < LA.WARN) {
                throw new ArchiveError.UNSUPPORTED(w.error_string() ?? opts);
            }
            if (encrypt) w.set_passphrase(password);
            int rc;
            if (volume_size > 0) {
                rc = w.open2((void*) this, null, split_write, split_close, null);
            } else {
                rc = w.open_filename(output_path);
                outputs.add(output_path);
            }
            if (rc != LA.OK) {
                string msg = w.error_string() ?? _("Cannot create the archive.");
                cleanup_outputs();
                throw new ArchiveError.FAILED(msg);
            }
            try {
                uint8[] buffer = new uint8[65536];
                foreach (unowned string s in sources) {
                    string base_dir = Path.get_dirname(s);
                    add_path(w, s, base_dir, buffer);
                }
                if (w.close() != LA.OK || split_failed) {
                    throw new ArchiveError.FAILED(w.error_string() ?? _("Cannot finish the archive."));
                }
            } catch (Error e) {
                w.close();
                cleanup_outputs();
                throw e;
            }
            if (volume_size > 0 && outputs.length == 1) {
                if (FileUtils.rename(outputs[0], output_path) == 0) outputs[0] = output_path;
            }
            done_bytes = total_bytes;
        }

        private void add_path(LA.Writer w, string path, string base_dir, uint8[] buffer) throws Error {
            check_cancel();
            Posix.Stat st;
            if (Posix.lstat(path, out st) != 0) return;
            string rel = path.substring(base_dir.length).replace("//", "/");
            while (rel.has_prefix("/")) rel = rel.substring(1);
            var e = new LA.Entry();
            e.set_mtime((int64) st.st_mtime, 0);
            e.set_perm((uint) (st.st_mode & 07777));
            if (Posix.S_ISLNK(st.st_mode)) {
                string target;
                try {
                    target = FileUtils.read_link(path);
                } catch (FileError fe) {
                    return;
                }
                e.set_pathname(rel);
                e.set_filetype(LA.IFLNK);
                e.set_symlink(target);
                e.set_size(0);
                if (w.write_header(e) < LA.WARN) throw new ArchiveError.FAILED(w.error_string() ?? rel);
                entries++;
                return;
            }
            if (Posix.S_ISDIR(st.st_mode)) {
                e.set_pathname(rel + "/");
                e.set_filetype(LA.IFDIR);
                e.set_size(0);
                if (w.write_header(e) < LA.WARN) throw new ArchiveError.FAILED(w.error_string() ?? rel);
                entries++;
                string[] names = {};
                try {
                    var dir = Dir.open(path);
                    unowned string? name;
                    while ((name = dir.read_name()) != null) names += name;
                } catch (FileError fe) {
                    throw new ArchiveError.FAILED(fe.message);
                }
                qsort_names(names);
                foreach (unowned string n in names) add_path(w, Path.build_filename(path, n), base_dir, buffer);
                return;
            }
            if (!Posix.S_ISREG(st.st_mode)) return;
            e.set_pathname(rel);
            e.set_filetype(LA.IFREG);
            e.set_size((int64) st.st_size);
            if (w.write_header(e) < LA.WARN) throw new ArchiveError.FAILED(w.error_string() ?? rel);
            var input = FileStream.open(path, "rb");
            if (input == null) throw new ArchiveError.FAILED(_("Cannot read \"%s\".").printf(rel));
            while (true) {
                check_cancel();
                size_t got = input.read(buffer, 1);
                if (got == 0) break;
                if (w.write_data((uint8*) buffer, got) < 0) throw new ArchiveError.FAILED(w.error_string() ?? rel);
                done_bytes += (int64) got;
            }
            w.finish_entry();
            entries++;
        }

        private static void qsort_names(string[] names) {
            for (int i = 1; i < names.length; i++) {
                string key = names[i];
                int j = i - 1;
                while (j >= 0 && strcmp(names[j], key) > 0) {
                    names[j + 1] = names[j];
                    j--;
                }
                names[j + 1] = key;
            }
        }
    }
}

namespace Singularity.Apps.Files {

    public enum NameState {
        OK,
        HIDDEN,
        EMPTY,
        SLASH,
        CONTROL_CHARS,
        RESERVED,
        TOO_LONG,
        EXISTS_FOLDER,
        EXISTS_FILE;

        public bool blocks() {
            return this != OK && this != HIDDEN;
        }
    }

    public delegate FileType NameLookup(string name);

    public class FolderNames : Object {
        public const int MAX_BYTES = 255;

        public static NameState check(string raw, NameLookup lookup) {
            if (raw.contains("/")) return NameState.SLASH;
            string name = raw.strip();
            if (name == "") return NameState.EMPTY;
            unichar c;
            int i = 0;
            while (name.get_next_char(ref i, out c)) {
                if (c.iscntrl()) return NameState.CONTROL_CHARS;
            }
            if (name == "." || name == "..") return NameState.RESERVED;
            if (name.length > MAX_BYTES) return NameState.TOO_LONG;
            var type = lookup(name);
            if (type == FileType.DIRECTORY) return NameState.EXISTS_FOLDER;
            if (type != FileType.UNKNOWN) return NameState.EXISTS_FILE;
            if (name.has_prefix(".")) return NameState.HIDDEN;
            return NameState.OK;
        }

        public static string message(NameState state, string raw) {
            string name = raw.strip();
            switch (state) {
                case NameState.HIDDEN:
                    return _("Names starting with a dot are hidden");
                case NameState.EMPTY:
                    return _("Enter a name");
                case NameState.SLASH:
                    return _("Names cannot contain “/”");
                case NameState.CONTROL_CHARS:
                    return _("Names cannot contain line breaks or tabs");
                case NameState.RESERVED:
                    return _("“%s” is reserved by the system").printf(name);
                case NameState.TOO_LONG:
                    return _("This name is too long");
                case NameState.EXISTS_FOLDER:
                    return _("A folder named “%s” already exists here").printf(name);
                case NameState.EXISTS_FILE:
                    return _("A file named “%s” already exists here").printf(name);
                default:
                    return "";
            }
        }

        public static string unique(string base_name, NameLookup lookup) {
            if (lookup(base_name) == FileType.UNKNOWN) return base_name;
            for (int n = 2; ; n++) {
                string candidate = "%s %d".printf(base_name, n);
                if (lookup(candidate) == FileType.UNKNOWN) return candidate;
            }
        }

        public static string unique_file(string file_name, NameLookup lookup) {
            if (lookup(file_name) == FileType.UNKNOWN) return file_name;
            int dot = file_name.last_index_of_char('.');
            string stem = dot > 0 ? file_name.substring(0, dot) : file_name;
            string ext = dot > 0 ? file_name.substring(dot) : "";
            for (int n = 2; ; n++) {
                string candidate = "%s %d%s".printf(stem, n, ext);
                if (lookup(candidate) == FileType.UNKNOWN) return candidate;
            }
        }

        public static int stem_length(string name, bool is_folder) {
            if (is_folder) return name.char_count();
            int dot = name.last_index_of_char('.');
            if (dot <= 0) return name.char_count();
            int tar = name.ascii_down().last_index_of(".tar.");
            if (tar > 0 && tar + 4 == dot) dot = tar;
            return name.char_count(dot);
        }

        public static FileType lookup_in(File folder, string name) {
            return folder.get_child(name).query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        }
    }

    public class TemplateEntry : Object {
        public string path { get; construct; }
        public bool is_dir { get; construct; }
        public string? content { get; construct; }

        public TemplateEntry(string path, bool is_dir, string? content) {
            Object(path: path, is_dir: is_dir, content: content);
        }
    }

    public class FolderTemplate : Object {
        public string id { get; construct; }
        public string name { get; construct; }
        public string summary { get; construct; }
        public string icon_name { get; construct; }
        public string? folder_name { get; construct; }
        public File? source { get; construct; }
        public GenericArray<TemplateEntry> entries = new GenericArray<TemplateEntry>();

        public FolderTemplate(string id, string name, string summary, string icon_name,
                              string? folder_name, File? source) {
            Object(id: id, name: name, summary: summary, icon_name: icon_name,
                   folder_name: folder_name, source: source);
        }

        public bool is_empty {
            get { return source == null && entries.length == 0; }
        }
    }

    public class FolderTemplates : Object {
        public const string DATA_FILE = "folder-templates.json";

        public static string expand(string text, string name, DateTime now) {
            return text.replace("{{name}}", name)
                .replace("{{year}}", now.format("%Y"))
                .replace("{{date}}", now.format("%Y-%m-%d"));
        }

        public static FolderTemplate empty_template() {
            return new FolderTemplate("empty", _("Empty Folder"), _("A plain folder with nothing inside"),
                "folder", null, null);
        }

        public static GenericArray<FolderTemplate> parse(string json) throws Error {
            var list = new GenericArray<FolderTemplate>();
            var parser = new Json.Parser();
            parser.load_from_data(json);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return list;
            var obj = root.get_object();
            if (!obj.has_member("templates")) return list;
            foreach (var node in obj.get_array_member("templates").get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                var t = node.get_object();
                string id = t.get_string_member_with_default("id", "");
                string name = t.get_string_member_with_default("name", "");
                if (id == "" || name == "") continue;
                string? folder_name = t.has_member("folder-name") ? t.get_string_member("folder-name") : null;
                var tpl = new FolderTemplate(id, _(name),
                    _(t.get_string_member_with_default("summary", "")),
                    t.get_string_member_with_default("icon", "folder"),
                    folder_name != null ? _(folder_name) : null, null);
                if (t.has_member("entries")) {
                    foreach (var en in t.get_array_member("entries").get_elements()) {
                        if (en.get_node_type() != Json.NodeType.OBJECT) continue;
                        var e = en.get_object();
                        string path = e.get_string_member_with_default("path", "");
                        bool dir = path.has_suffix("/");
                        string clean = dir ? path.substring(0, path.length - 1) : path;
                        if (!safe_relative(clean)) continue;
                        string? content = e.has_member("content") ? e.get_string_member("content") : null;
                        tpl.entries.add(new TemplateEntry(clean, dir, dir ? null : (content ?? "")));
                    }
                }
                list.add(tpl);
            }
            return list;
        }

        public static bool safe_relative(string path) {
            if (path == "" || path.has_prefix("/")) return false;
            foreach (string part in path.split("/")) {
                if (part == "" || part == "." || part == "..") return false;
            }
            return true;
        }

        public static File? builtin_file() {
            var dirs = new GenericArray<string>();
            dirs.add(Environment.get_user_data_dir());
            foreach (string d in Environment.get_system_data_dirs()) dirs.add(d);
            foreach (string d in dirs.data) {
                var f = File.new_build_filename(d, "singularity-files", DATA_FILE);
                if (f.query_exists()) return f;
            }
            return null;
        }

        public static GenericArray<FolderTemplate> load_builtin() {
            var f = builtin_file();
            if (f == null) return new GenericArray<FolderTemplate>();
            try {
                uint8[] data;
                f.load_contents(null, out data, null);
                return parse((string) data);
            } catch (Error e) {
                warning("Folder templates: %s", e.message);
                return new GenericArray<FolderTemplate>();
            }
        }

        public static File? user_dir() {
            string home = Environment.get_home_dir();
            string? dir = Environment.get_user_special_dir(UserDirectory.TEMPLATES);
            if (dir == null || dir == "") dir = Path.build_filename(home, "Templates");
            if (Path.build_filename(dir) == Path.build_filename(home)) return null;
            return File.new_for_path(dir);
        }

        private static GenericArray<FileInfo> list_children(File dir, bool folders) {
            var result = new GenericArray<FileInfo>();
            try {
                var en = dir.enumerate_children("standard::name,standard::type,standard::is-hidden,standard::icon,standard::content-type",
                    FileQueryInfoFlags.NONE, null);
                FileInfo? info;
                while ((info = en.next_file(null)) != null) {
                    if (info.get_is_hidden() || info.get_name().has_prefix(".")) continue;
                    bool is_dir = info.get_file_type() == FileType.DIRECTORY;
                    if (is_dir == folders && (is_dir || info.get_file_type() == FileType.REGULAR)) result.add(info);
                }
            } catch (Error e) {
                if (!(e is IOError.NOT_FOUND)) warning("Templates folder: %s", e.message);
            }
            result.sort((a, b) => a.get_name().collate(b.get_name()));
            return result;
        }

        public static GenericArray<FolderTemplate> load_user(File? dir) {
            var list = new GenericArray<FolderTemplate>();
            if (dir == null) return list;
            var children = list_children(dir, true);
            foreach (var info in children.data) {
                string n = info.get_name();
                var src = dir.get_child(n);
                string[] inside = {};
                var sub_dirs = list_children(src, true);
                var sub_files = list_children(src, false);
                foreach (var child in sub_dirs.data) inside += child.get_name();
                foreach (var child in sub_files.data) inside += child.get_name();
                string summary;
                if (inside.length == 0) {
                    summary = _("Your empty template folder");
                } else if (inside.length <= 3) {
                    summary = _("Your template with %s").printf(string.joinv(", ", inside));
                } else {
                    summary = ngettext("Your template with %s and %d more", "Your template with %s and %d more", inside.length - 2)
                        .printf(string.joinv(", ", inside[0:2]), inside.length - 2);
                }
                list.add(new FolderTemplate("user:" + n, n, summary, "folder-templates", n, src));
            }
            return list;
        }

        public static GenericArray<FileInfo> document_templates(File? dir) {
            if (dir == null) return new GenericArray<FileInfo>();
            return list_children(dir, false);
        }

        public static void create(FolderTemplate tpl, File target, DateTime now) throws Error {
            target.make_directory(null);
            if (tpl.source != null) {
                copy_tree(tpl.source, target, true);
                return;
            }
            string name = target.get_basename();
            foreach (var e in tpl.entries.data) {
                string rel = expand(e.path, name, now);
                if (!safe_relative(rel)) continue;
                var child = target.resolve_relative_path(rel);
                if (!child.has_prefix(target)) continue;
                if (e.is_dir) {
                    make_dirs(child);
                } else {
                    var parent = child.get_parent();
                    if (parent != null) make_dirs(parent);
                    string text = expand(e.content ?? "", name, now);
                    child.replace_contents(text.data, null, false, FileCreateFlags.NONE, null, null);
                }
            }
        }

        private static void make_dirs(File dir) throws Error {
            try {
                dir.make_directory_with_parents(null);
            } catch (IOError.EXISTS e) {
            }
        }

        public static void copy_tree(File src, File dst, bool with_files) throws Error {
            var en = src.enumerate_children("standard::name,standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            FileInfo? info;
            while ((info = en.next_file(null)) != null) {
                var from = src.get_child(info.get_name());
                var to = dst.get_child(info.get_name());
                if (info.get_file_type() == FileType.DIRECTORY) {
                    to.make_directory(null);
                    copy_tree(from, to, with_files);
                } else if (with_files) {
                    from.copy(to, FileCopyFlags.NOFOLLOW_SYMLINKS, null, null);
                }
            }
        }

        public static File save_folder(File folder, File templates, bool with_files) throws Error {
            if (templates.equal(folder) || templates.has_prefix(folder))
                throw new IOError.INVALID_ARGUMENT(_("A folder that contains Templates cannot be saved as a template"));
            make_dirs(templates);
            string n = FolderNames.unique(folder.get_basename(), (x) => FolderNames.lookup_in(templates, x));
            var dest = templates.get_child(n);
            dest.make_directory(null);
            copy_tree(folder, dest, with_files);
            return dest;
        }
    }
}

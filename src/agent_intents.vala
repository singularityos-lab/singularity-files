using Singularity.Apps.Files.Archives;

namespace Singularity.Apps {

    internal class FilesIntents : Object {
        private const string PATH = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}";
        private const string PAIR = "{\"type\":\"object\",\"properties\":{\"from\":{\"type\":\"string\"},\"to\":{\"type\":\"string\"}},\"required\":[\"from\",\"to\"]}";

        private static File path (Json.Object args, string key = "path") throws Error {
            string p = args.has_member (key) ? args.get_string_member (key) : "";
            if (!p.has_prefix ("/")) throw new IOError.INVALID_ARGUMENT ("%s must be an absolute path", key);
            return File.new_for_path (p);
        }

        private static Json.Node result (File f) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("path").add_string_value (f.get_path ());
            b.end_object ();
            return b.get_root ();
        }

        private static string text (Json.Object args, string key) {
            return args.has_member (key) ? args.get_string_member (key) : "";
        }

        private static Json.Node obj (Json.Object o) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (o);
            return node;
        }

        private class SearchQuery {
            public string root;
            public PatternSpec? glob;
            public string words;
            public string type_prefix;
            public int64 min_size;
            public int64 max_size;
            public int64 after;
            public bool folders;
            public bool hidden;
            public int limit;
            public int seen = 0;
            public Json.Array found = new Json.Array ();
        }

        private static void walk (SearchQuery q, File dir, int depth) {
            if (depth > 24 || q.found.get_length () >= q.limit || q.seen > 200000) return;
            FileEnumerator e;
            try {
                e = dir.enumerate_children ("standard::name,standard::type,standard::size,standard::content-type,standard::is-hidden,time::modified", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            } catch (Error err) {
                return;
            }
            try {
                FileInfo? info;
                while ((info = e.next_file ()) != null && q.found.get_length () < q.limit) {
                    q.seen++;
                    string name = info.get_name ();
                    if (!q.hidden && (info.get_is_hidden () || name.has_prefix ("."))) continue;
                    var child = dir.get_child (name);
                    bool folder = info.get_file_type () == FileType.DIRECTORY;
                    if (matches (q, info, name, folder)) {
                        var o = new Json.Object ();
                        o.set_string_member ("path", child.get_path ());
                        o.set_boolean_member ("folder", folder);
                        if (!folder) o.set_int_member ("size", info.get_size ());
                        o.set_string_member ("type", info.get_content_type () ?? "");
                        var m = info.get_modification_date_time ();
                        if (m != null) o.set_string_member ("modified", m.to_local ().format_iso8601 ());
                        q.found.add_object_element (o);
                    }
                    if (folder) walk (q, child, depth + 1);
                }
            } catch (Error err) {
            }
        }

        private static bool matches (SearchQuery q, FileInfo info, string name, bool folder) {
            if (folder && !q.folders) return false;
            string low = name.down ();
            if (q.glob != null && !q.glob.match_string (low)) return false;
            if (q.words != "") {
                foreach (string w in q.words.down ().split (" ")) if (w != "" && !low.contains (w)) return false;
            }
            if (!folder) {
                if (q.type_prefix != "" && !(info.get_content_type () ?? "").has_prefix (q.type_prefix)) return false;
                if (q.min_size > 0 && info.get_size () < q.min_size) return false;
                if (q.max_size > 0 && info.get_size () > q.max_size) return false;
            }
            if (q.after > 0) {
                var m = info.get_modification_date_time ();
                if (m == null || m.to_unix () < q.after) return false;
            }
            return true;
        }

        private static async void search (Json.Object args, owned Singularity.AppIntentReply reply) {
            try {
                var q = new SearchQuery ();
                var root = path (args, "folder");
                if (root.query_file_type (FileQueryInfoFlags.NONE) != FileType.DIRECTORY) throw new IOError.NOT_DIRECTORY ("%s is not a folder", root.get_path ());
                q.root = root.get_path ();
                if (text (args, "pattern") != "") q.glob = new PatternSpec (text (args, "pattern").down ());
                q.words = text (args, "name");
                q.type_prefix = text (args, "type");
                q.min_size = args.has_member ("min_size") ? args.get_int_member ("min_size") : 0;
                q.max_size = args.has_member ("max_size") ? args.get_int_member ("max_size") : 0;
                q.after = 0;
                if (args.has_member ("modified_after")) {
                    var d = new DateTime.from_iso8601 (text (args, "modified_after"), new TimeZone.local ());
                    if (d == null) throw new IOError.INVALID_ARGUMENT ("modified_after must be an ISO 8601 date");
                    q.after = d.to_unix ();
                }
                q.folders = args.has_member ("folders") && args.get_boolean_member ("folders");
                q.hidden = args.has_member ("hidden") && args.get_boolean_member ("hidden");
                q.limit = args.has_member ("limit") ? (int) args.get_int_member ("limit").clamp (1, 2000) : 200;
                try {
                    yield Async.run<bool>((c) => {
                        walk (q, root, 0);
                        return true;
                    }, Async.Qos.USER);
                } catch (Error e) {
                    warning("%s", e.message);
                }
                var o = new Json.Object ();
                o.set_int_member ("count", q.found.get_length ());
                o.set_boolean_member ("truncated", q.found.get_length () >= q.limit);
                o.set_array_member ("files", q.found);
                reply (obj (o), null);
            } catch (Error e) {
                reply (null, e);
            }
        }

        private static async void compress (Json.Object args, owned Singularity.AppIntentReply reply) {
            try {
                if (!args.has_member ("paths")) throw new IOError.INVALID_ARGUMENT ("paths is required");
                string[] sources = {};
                foreach (var n in args.get_array_member ("paths").get_elements ()) {
                    var f = File.new_for_path (n.get_string ());
                    if (!n.get_string ().has_prefix ("/")) throw new IOError.INVALID_ARGUMENT ("paths must be absolute");
                    if (!f.query_exists ()) throw new IOError.NOT_FOUND ("no file %s", f.get_path ());
                    sources += f.get_path ();
                }
                if (sources.length == 0) throw new IOError.INVALID_ARGUMENT ("paths is empty");
                var to = path (args, "to");
                if (to.query_exists ()) throw new IOError.EXISTS ("%s already exists, it is never overwritten", to.get_path ());
                var kind = ArchiveFormats.from_name (to.get_basename ());
                if (!kind.can_write ()) throw new IOError.INVALID_ARGUMENT ("give to a .zip, .7z, .tar, .tar.gz, .tar.bz2, .tar.xz or .tar.zst name");
                var creator = new ArchiveCreator (sources, to.get_path ());
                creator.kind = kind;
                switch (text (args, "level")) {
                    case "store": creator.level = CompressionLevel.STORE; break;
                    case "fast": creator.level = CompressionLevel.FAST; break;
                    case "best": creator.level = CompressionLevel.BEST; break;
                    case "": case "normal": break;
                    default: throw new IOError.INVALID_ARGUMENT ("level is store, fast, normal or best");
                }
                Error? failure = null;
                try {
                    yield Async.run<bool>((c) => {
                        try {
                            creator.run ();
                        } catch (Error e) {
                            failure = e;
                        }
                        return true;
                    }, Async.Qos.USER);
                } catch (Error e) {
                    warning("%s", e.message);
                }
                if (failure != null) throw failure;
                var o = new Json.Object ();
                o.set_string_member ("path", to.get_path ());
                o.set_string_member ("format", kind.label ());
                o.set_int_member ("entries", creator.entries);
                o.set_int_member ("bytes", creator.total_bytes);
                o.set_boolean_member ("verified", to.query_exists () && ArchiveReader.list (to.get_path ()).entries.length > 0);
                reply (obj (o), null);
            } catch (Error e) {
                reply (null, e);
            }
        }

        private static string new_name (Json.Object args, string name, int n, Regex? re) throws Error {
            int dot = name.last_index_of_char ('.');
            bool keep_ext = !(args.has_member ("extension") && args.get_boolean_member ("extension"));
            string stem = keep_ext && dot > 0 ? name.substring (0, dot) : name;
            string ext = keep_ext && dot > 0 ? name.substring (dot) : "";
            if (re != null) stem = re.replace (stem, -1, 0, text (args, "replace"));
            else if (text (args, "find") != "") stem = stem.replace (text (args, "find"), text (args, "replace"));
            if (args.has_member ("case")) {
                switch (text (args, "case")) {
                    case "lower": stem = stem.down (); break;
                    case "upper": stem = stem.up (); break;
                    default: throw new IOError.INVALID_ARGUMENT ("case is lower or upper");
                }
            }
            string numbered = "";
            if (args.has_member ("number_from")) {
                int width = args.has_member ("digits") ? (int) args.get_int_member ("digits").clamp (1, 9) : 2;
                numbered = n.to_string ();
                while (numbered.length < width) numbered = "0" + numbered;
            }
            return text (args, "prefix") + (text (args, "number_position") == "start" ? numbered : "") + stem + (text (args, "number_position") == "start" ? "" : numbered) + text (args, "suffix") + ext;
        }

        private static string kind_of (string type, string name) {
            string low = name.down ();
            if (type.has_prefix ("image/")) return "Images";
            if (type.has_prefix ("video/")) return "Videos";
            if (type.has_prefix ("audio/")) return "Music";
            if (ArchiveFormats.is_archive_type (type) || ArchiveFormats.is_archive_name (name)) return "Archives";
            if (type == "application/pdf" || type.has_prefix ("application/vnd.oasis.opendocument") || type.has_prefix ("application/vnd.openxmlformats") || type == "application/msword" || type == "application/rtf" || type == "text/markdown" || type == "text/plain" || type == "application/vnd.ms-excel" || type == "application/vnd.ms-powerpoint" || type == "text/csv") return "Documents";
            if (type == "application/x-executable" || type == "application/vnd.appimage" || low.has_suffix (".sxi") || low.has_suffix (".flatpakref") || low.has_suffix (".deb") || low.has_suffix (".rpm")) return "Installers";
            if (type.has_prefix ("text/") || type == "application/json" || type == "application/xml" || type == "application/javascript" || type == "application/x-shellscript") return "Code";
            return "";
        }

        private static async void share (Singularity.Application app, Json.Object args, owned Singularity.AppIntentReply reply) {
            try {
                if (!args.has_member ("paths")) throw new IOError.INVALID_ARGUMENT ("paths is required");
                File[] files = {};
                foreach (var n in args.get_array_member ("paths").get_elements ()) {
                    if (!n.get_string ().has_prefix ("/")) throw new IOError.INVALID_ARGUMENT ("paths must be absolute");
                    var f = File.new_for_path (n.get_string ());
                    if (f.query_file_type (FileQueryInfoFlags.NONE) != FileType.REGULAR) throw new IOError.NOT_FOUND ("%s is not a file", f.get_path ());
                    files += f;
                }
                if (files.length == 0) throw new IOError.INVALID_ARGUMENT ("paths is empty");
                var o = new Json.Object ();
                o.set_int_member ("files", files.length);
                string device = text (args, "device");
                if (device == "") {
                    Gtk.Window? parent = app.active_window != null && app.active_window.get_mapped () ? app.active_window : null;
                    Singularity.Share.present (parent, new Singularity.ShareContent.for_files (files), app);
                    o.set_string_member ("shown", "the share sheet is open on screen, the person picks where");
                    reply (obj (o), null);
                    return;
                }
                var nearby = Singularity.NearbyClient.get_default ();
                yield nearby.refresh ();
                Singularity.NearbyDevice? target = null;
                string[] names = {};
                foreach (var d in nearby.devices) {
                    if (!d.usable) continue;
                    names += d.name;
                    if (d.id == device || d.name.down () == device.down ()) target = d;
                }
                if (target == null) {
                    throw new IOError.NOT_FOUND (names.length > 0 ? "no Nearby device %s; reachable: %s".printf (device, string.joinv (", ", names)) : "no paired Nearby device is reachable");
                }
                string transfer = yield nearby.share_files (target.id, files);
                o.set_string_member ("device", target.name);
                o.set_string_member ("transfer", transfer);
                reply (obj (o), null);
            } catch (Error e) {
                reply (null, e);
            }
        }

        internal static void install (Singularity.Application app) {
            var agent = app.agent;
            agent.add_intent ("files_list", "List a folder.",
                PATH, Singularity.AppIntentRisk.READ, (args) => {
                    var list = new Json.Array ();
                    var e = path (args).enumerate_children ("standard::name,standard::type,standard::size,standard::content-type", FileQueryInfoFlags.NONE);
                    FileInfo? info;
                    while ((info = e.next_file ()) != null && list.get_length () < 2000) {
                        var o = new Json.Object ();
                        o.set_string_member ("name", info.get_name ());
                        o.set_boolean_member ("folder", info.get_file_type () == FileType.DIRECTORY);
                        o.set_int_member ("size", info.get_size ());
                        o.set_string_member ("type", info.get_content_type () ?? "");
                        list.add_object_element (o);
                    }
                    var node = new Json.Node (Json.NodeType.ARRAY);
                    node.set_array (list);
                    return node;
                });
            agent.add_intent ("files_show", "Show a file or a folder in a window.",
                PATH, Singularity.AppIntentRisk.READ, (args) => {
                    var f = path (args);
                    app.open ({ f }, "");
                    return result (f);
                });
            agent.add_intent ("files_mkdir", "Create a folder.",
                PATH, Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var f = path (args);
                    f.make_directory_with_parents ();
                    return result (f);
                });
            agent.add_intent ("files_copy", "Copy a file. It never overwrites.",
                PAIR, Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var to = path (args, "to");
                    path (args, "from").copy (to, FileCopyFlags.NONE);
                    return result (to);
                });
            agent.add_intent ("files_move", "Move or rename a file. It never overwrites.",
                PAIR, Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var to = path (args, "to");
                    path (args, "from").move (to, FileCopyFlags.NONE);
                    return result (to);
                });
            agent.add_intent ("files_trash", "Move a file to the trash.",
                PATH, Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var f = path (args);
                    f.trash ();
                    return result (f);
                });
            agent.add_async_intent ("files_search", "Search a folder and its subfolders for files: name holds words the file name must all contain, pattern is a glob such as *.pdf, type a content type prefix such as image/ or application/pdf, sizes in bytes, modified_after an ISO 8601 date. Hidden files and folders are left out unless asked.",
                "{\"type\":\"object\",\"properties\":{\"folder\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"},\"pattern\":{\"type\":\"string\"},\"type\":{\"type\":\"string\"},\"min_size\":{\"type\":\"integer\"},\"max_size\":{\"type\":\"integer\"},\"modified_after\":{\"type\":\"string\"},\"folders\":{\"type\":\"boolean\"},\"hidden\":{\"type\":\"boolean\"},\"limit\":{\"type\":\"integer\"}},\"required\":[\"folder\"]}",
                Singularity.AppIntentRisk.READ, (args, reply) => {
                    search.begin (args, (owned) reply);
                });
            agent.add_intent ("files_rename_batch", "Rename many files at once. Take paths, or every file of folder matching pattern (a glob). Each name, without its extension unless extension is true, gets find replaced (regex true for a regular expression, $1 for groups), case lower or upper, then prefix, suffix and a counter from number_from with digits, placed at the end or at the start (number_position). dry_run shows the new names without renaming. Nothing is renamed if any new name clashes.",
                "{\"type\":\"object\",\"properties\":{\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"folder\":{\"type\":\"string\"},\"pattern\":{\"type\":\"string\"},\"find\":{\"type\":\"string\"},\"replace\":{\"type\":\"string\"},\"regex\":{\"type\":\"boolean\"},\"case\":{\"type\":\"string\",\"enum\":[\"lower\",\"upper\"]},\"prefix\":{\"type\":\"string\"},\"suffix\":{\"type\":\"string\"},\"number_from\":{\"type\":\"integer\"},\"digits\":{\"type\":\"integer\"},\"number_position\":{\"type\":\"string\",\"enum\":[\"start\",\"end\"]},\"extension\":{\"type\":\"boolean\"},\"dry_run\":{\"type\":\"boolean\"}}}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var files = new Gee.ArrayList<File> ();
                    if (args.has_member ("paths")) {
                        foreach (var n in args.get_array_member ("paths").get_elements ()) {
                            if (!n.get_string ().has_prefix ("/")) throw new IOError.INVALID_ARGUMENT ("paths must be absolute");
                            files.add (File.new_for_path (n.get_string ()));
                        }
                    } else if (args.has_member ("folder")) {
                        PatternSpec? spec = null;
                        if (text (args, "pattern") != "") spec = new PatternSpec (text (args, "pattern"));
                        var e = path (args, "folder").enumerate_children ("standard::name,standard::type", FileQueryInfoFlags.NONE);
                        var names = new Gee.ArrayList<string> ();
                        FileInfo? info;
                        while ((info = e.next_file ()) != null) {
                            if (info.get_file_type () == FileType.DIRECTORY || info.get_name ().has_prefix (".")) continue;
                            if (spec == null || spec.match_string (info.get_name ())) names.add (info.get_name ());
                        }
                        names.sort ((a, b) => a.collate_key_for_filename ().collate (b.collate_key_for_filename ()));
                        foreach (string n in names) files.add (path (args, "folder").get_child (n));
                    } else {
                        throw new IOError.INVALID_ARGUMENT ("give paths, or folder with an optional pattern");
                    }
                    if (files.size == 0) throw new IOError.NOT_FOUND ("no file to rename");
                    if (files.size > 5000) throw new IOError.INVALID_ARGUMENT ("at most 5000 files at once");
                    Regex? re = args.has_member ("regex") && args.get_boolean_member ("regex") && text (args, "find") != "" ? new Regex (text (args, "find")) : null;
                    int n = args.has_member ("number_from") ? (int) args.get_int_member ("number_from") : 0;
                    var plan = new Gee.ArrayList<File> ();
                    var taken = new Gee.HashSet<string> ();
                    foreach (var f in files) taken.add (f.get_path ());
                    var targets = new Gee.HashSet<string> ();
                    foreach (var f in files) {
                        if (!f.query_exists ()) throw new IOError.NOT_FOUND ("no file %s", f.get_path ());
                        string name = new_name (args, f.get_basename (), n++, re);
                        if (name == "" || name.contains ("/") || name == "." || name == "..") throw new IOError.INVALID_ARGUMENT ("%s would get the name \"%s\"", f.get_basename (), name);
                        var to = f.get_parent ().get_child (name);
                        if (!targets.add (to.get_path ())) throw new IOError.EXISTS ("two files would both be named %s", name);
                        if (to.get_path () != f.get_path () && to.query_exists () && !taken.contains (to.get_path ())) throw new IOError.EXISTS ("%s already exists, nothing was renamed", to.get_path ());
                        plan.add (to);
                    }
                    bool dry = args.has_member ("dry_run") && args.get_boolean_member ("dry_run");
                    var list = new Json.Array ();
                    if (!dry) {
                        var staged = new Gee.ArrayList<File> ();
                        for (int i = 0; i < files.size; i++) {
                            if (plan[i].get_path () == files[i].get_path ()) {
                                staged.add (files[i]);
                                continue;
                            }
                            var tmp = files[i].get_parent ().get_child (".rename-%s-%d".printf (Uuid.string_random ().substring (0, 8), i));
                            files[i].move (tmp, FileCopyFlags.NONE);
                            staged.add (tmp);
                        }
                        for (int i = 0; i < files.size; i++) {
                            if (staged[i].get_path () != plan[i].get_path ()) staged[i].move (plan[i], FileCopyFlags.NONE);
                        }
                    }
                    int changed = 0;
                    for (int i = 0; i < files.size; i++) {
                        var o = new Json.Object ();
                        o.set_string_member ("from", files[i].get_basename ());
                        o.set_string_member ("to", plan[i].get_basename ());
                        if (plan[i].get_path () != files[i].get_path ()) changed++;
                        list.add_object_element (o);
                    }
                    var o = new Json.Object ();
                    o.set_boolean_member ("dry_run", dry);
                    o.set_int_member ("renamed", dry ? 0 : changed);
                    o.set_array_member ("files", list);
                    bool ok = true;
                    if (!dry) foreach (var t in plan) ok = ok && t.query_exists ();
                    o.set_boolean_member ("verified", ok);
                    return obj (o);
                });
            agent.add_async_intent ("files_compress", "Pack files and folders into a new archive; the extension of to picks the format (zip, 7z, tar, tar.gz, tar.bz2, tar.xz, tar.zst). level is store, fast, normal or best. It never overwrites.",
                "{\"type\":\"object\",\"properties\":{\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"to\":{\"type\":\"string\"},\"level\":{\"type\":\"string\",\"enum\":[\"store\",\"fast\",\"normal\",\"best\"]}},\"required\":[\"paths\",\"to\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    compress.begin (args, (owned) reply);
                });
            agent.add_intent ("files_organize_propose", "Propose how to tidy a folder: which loose files would go into Images, Videos, Music, Documents, Archives, Installers or Code subfolders, optionally split by year. Nothing is moved; files_move does it once the person agrees.",
                "{\"type\":\"object\",\"properties\":{\"folder\":{\"type\":\"string\"},\"by_year\":{\"type\":\"boolean\"}},\"required\":[\"folder\"]}",
                Singularity.AppIntentRisk.READ, (args) => {
                    var root = path (args, "folder");
                    bool by_year = args.has_member ("by_year") && args.get_boolean_member ("by_year");
                    var e = root.enumerate_children ("standard::name,standard::type,standard::content-type,standard::is-hidden,time::modified", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                    var moves = new Json.Array ();
                    var counts = new Gee.TreeMap<string, int> ();
                    int left = 0;
                    FileInfo? info;
                    while ((info = e.next_file ()) != null && moves.get_length () < 2000) {
                        if (info.get_file_type () != FileType.REGULAR || info.get_is_hidden () || info.get_name ().has_prefix (".")) continue;
                        string kind = kind_of (info.get_content_type () ?? "", info.get_name ());
                        if (kind == "") {
                            left++;
                            continue;
                        }
                        string dest = kind;
                        var m = info.get_modification_date_time ();
                        if (by_year && m != null) dest = Path.build_filename (kind, m.to_local ().get_year ().to_string ());
                        var o = new Json.Object ();
                        o.set_string_member ("from", root.get_child (info.get_name ()).get_path ());
                        o.set_string_member ("to", Path.build_filename (root.get_path (), dest, info.get_name ()));
                        moves.add_object_element (o);
                        counts[dest] = counts.has_key (dest) ? counts[dest] + 1 : 1;
                    }
                    var summary = new Json.Object ();
                    foreach (var entry in counts.entries) summary.set_int_member (entry.key, entry.value);
                    var o = new Json.Object ();
                    o.set_string_member ("folder", root.get_path ());
                    o.set_object_member ("folders", summary);
                    o.set_int_member ("left_in_place", left);
                    o.set_array_member ("moves", moves);
                    return obj (o);
                });
            agent.add_async_intent ("files_share", "Share files. With device, send them to that paired Nearby device by name; without it, open the share sheet on screen so the person picks the destination.",
                "{\"type\":\"object\",\"properties\":{\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"device\":{\"type\":\"string\"}},\"required\":[\"paths\"]}",
                Singularity.AppIntentRisk.IRREVERSIBLE, (args, reply) => {
                    share.begin (app, args, (owned) reply);
                });
            agent.add_intent ("files_delete", "Delete a file or an empty folder for good.",
                PATH, Singularity.AppIntentRisk.IRREVERSIBLE, (args) => {
                    var f = path (args);
                    f.delete ();
                    return result (f);
                });
        }
    }
}

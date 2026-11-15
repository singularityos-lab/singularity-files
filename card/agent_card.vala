using Gtk;

namespace Singularity.Apps.Files {

    public class AgentCard : Object {
        private const int MAX_ROWS = 6;

        private class Entry {
            public string path;
            public bool folder;
            public int64 size;
            public string type;
        }

        private static void show_file (string path) {
            var info = new GLib.DesktopAppInfo ("dev.sinty.files.desktop");
            var files = new GLib.List<File> ();
            files.append (File.new_for_path (path));
            try {
                if (info != null) info.launch (files, null);
            } catch (Error e) {
                warning ("Files card: %s", e.message);
            }
        }

        private static string place_of (string path) {
            string dir = Path.get_dirname (path);
            string home = Environment.get_home_dir ();
            if (dir == home) return _("Home");
            if (dir.has_prefix (home + "/")) return "~" + dir.substring (home.length);
            return dir;
        }

        private static Entry? entry_of (Json.Node node, string parent) {
            if (node.get_node_type () != Json.NodeType.OBJECT) return null;
            var o = node.get_object ();
            var e = new Entry ();
            if (o.has_member ("path")) {
                e.path = o.get_string_member ("path");
            } else if (o.has_member ("name") && parent != "") {
                e.path = Path.build_filename (parent, o.get_string_member ("name"));
            } else {
                return null;
            }
            e.type = o.has_member ("type") ? o.get_string_member ("type") : "";
            e.folder = o.has_member ("folder") ? o.get_boolean_member ("folder") : FileUtils.test (e.path, FileTest.IS_DIR);
            e.size = o.has_member ("size") ? o.get_int_member ("size") : -1;
            if (e.type == "" && !e.folder) {
                bool uncertain;
                e.type = ContentType.guess (e.path, null, out uncertain);
            }
            return e;
        }

        private static ListBoxRow row_for (Entry e) {
            var row = new ListBoxRow ();
            var box = new Box (Orientation.HORIZONTAL, 10);
            box.margin_top = box.margin_bottom = 6;
            box.margin_start = box.margin_end = 10;
            var icon = new Image.from_gicon (e.folder ? new ThemedIcon ("folder") : ContentType.get_icon (e.type));
            icon.pixel_size = 32;
            box.append (icon);
            var text = new Box (Orientation.VERTICAL, 1);
            text.hexpand = true;
            text.valign = Align.CENTER;
            var name = new Label (Path.get_basename (e.path));
            name.xalign = 0;
            name.ellipsize = Pango.EllipsizeMode.MIDDLE;
            text.append (name);
            string sub = place_of (e.path);
            if (!e.folder && e.size >= 0) sub = "%s · %s".printf (format_size ((uint64) e.size), sub);
            var detail = new Label (sub);
            detail.xalign = 0;
            detail.ellipsize = Pango.EllipsizeMode.MIDDLE;
            detail.add_css_class ("caption");
            detail.add_css_class ("dim-label");
            text.append (detail);
            box.append (text);
            row.child = box;
            row.set_data<string> ("path", e.path);
            row.tooltip_text = e.path;
            return row;
        }

        public static Widget? build (string intent, string args, string result) {
            Json.Node root;
            try {
                root = Json.from_string (result);
            } catch (Error e) {
                return null;
            }
            if (root == null) return null;
            string parent = "";
            try {
                var a = Json.from_string (args);
                if (a != null && a.get_node_type () == Json.NodeType.OBJECT && a.get_object ().has_member ("path")) {
                    parent = a.get_object ().get_string_member ("path");
                }
            } catch (Error e) {
            }
            var nodes = new Gee.ArrayList<Json.Node> ();
            int total = 0;
            if (root.get_node_type () == Json.NodeType.ARRAY) {
                foreach (var n in root.get_array ().get_elements ()) nodes.add (n);
                total = nodes.size;
            } else if (root.get_node_type () == Json.NodeType.OBJECT && root.get_object ().has_member ("files")) {
                foreach (var n in root.get_object ().get_array_member ("files").get_elements ()) nodes.add (n);
                total = root.get_object ().has_member ("count") ? (int) root.get_object ().get_int_member ("count") : nodes.size;
            } else {
                nodes.add (root);
                total = 1;
            }
            var list = new ListBox ();
            list.selection_mode = SelectionMode.NONE;
            list.add_css_class ("boxed-list");
            list.row_activated.connect ((r) => show_file (r.get_data<string> ("path")));
            int shown = 0;
            foreach (var n in nodes) {
                if (shown == MAX_ROWS) break;
                var e = entry_of (n, parent);
                if (e == null) continue;
                list.append (row_for (e));
                shown++;
            }
            if (shown == 0) {
                var none = new Label (_("No files"));
                none.add_css_class ("dim-label");
                none.xalign = 0;
                return none;
            }
            if (total <= shown) return list;
            var box = new Box (Orientation.VERTICAL, 4);
            box.append (list);
            var more = new Button.with_label (ngettext ("%d more", "%d more", total - shown).printf (total - shown));
            more.has_frame = false;
            more.halign = Align.START;
            more.add_css_class ("caption");
            string open = parent != "" ? parent : Path.get_dirname (list.get_row_at_index (0).get_data<string> ("path"));
            more.clicked.connect (() => show_file (open));
            box.append (more);
            return box;
        }
    }

    [CCode (cname = "singularity_files_card_new")]
    public Widget? agent_card_new (string intent, string args, string result) {
        return AgentCard.build (intent, args, result);
    }
}

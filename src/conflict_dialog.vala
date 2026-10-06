using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Files {

    public class ConflictDialog : AppDialog {
        private ConflictRequest request;
        private CheckButton apply_all;
        private Entry rename_entry;
        private bool answered = false;

        public ConflictDialog (Gtk.Application app, ConflictRequest request, int remaining_hint) {
            base (app, true);
            this.request = request;
            transient_for = app.get_active_window ();
            bool folders = request.both_folders;
            string name = request.target_info.get_display_name () ?? request.target.get_basename ();
            set_title (folders ? _("Folder Already Exists") : _("File Already Exists"));
            set_default_size (560, -1);

            var box = new Box (Orientation.VERTICAL, 16);
            box.margin_top = 4;
            box.margin_bottom = 18;
            box.margin_start = 22;
            box.margin_end = 22;

            var headline = new Label (folders
                ? _("\"%s\" is already in \"%s\". Merge the two folders or choose what to do.").printf (name, folder_name (request.target))
                : _("\"%s\" is already in \"%s\".").printf (name, folder_name (request.target)));
            headline.wrap = true;
            headline.xalign = 0;
            headline.add_css_class ("title-4");
            box.append (headline);

            var cards = new Box (Orientation.HORIZONTAL, 12);
            cards.homogeneous = true;
            int64 src_time = modified (request.source_info);
            int64 dst_time = modified (request.target_info);
            int64 src_size = request.source_info.get_size ();
            int64 dst_size = request.target_info.get_size ();
            cards.append (card (_("Already There"), request.target, request.target_info,
                dst_time > src_time + 1 ? _("Newer") : null,
                !folders && dst_size > src_size ? _("Larger") : null));
            string incoming = request.op.kind == "extract" ? _("In the Archive") : (request.op.is_move ? _("Being Moved") : _("Being Copied"));
            cards.append (card (incoming, request.source, request.source_info,
                src_time > dst_time + 1 ? _("Newer") : null,
                !folders && src_size > dst_size ? _("Larger") : null));
            box.append (cards);

            if (!folders && src_size == dst_size && same_content (request.source, request.target, src_size)) {
                var same = new Label (_("The two files are identical."));
                same.wrap = true;
                same.xalign = 0;
                same.add_css_class ("dim-label");
                box.append (same);
            }

            var rename_box = new Box (Orientation.HORIZONTAL, 8);
            var rename_label = new Label (_("Keep both as"));
            rename_label.add_css_class ("dim-label");
            rename_box.append (rename_label);
            rename_entry = new Entry ();
            rename_entry.text = request.suggested_name;
            rename_entry.hexpand = true;
            rename_entry.activate.connect (() => respond (ConflictChoice.KEEP_BOTH));
            rename_box.append (rename_entry);
            box.append (rename_box);

            apply_all = new CheckButton.with_label (folders
                ? _("Do the same for every folder that already exists")
                : _("Do the same for every file that already exists"));
            if (remaining_hint > 1) apply_all.active = false;
            box.append (apply_all);

            var actions = new Box (Orientation.HORIZONTAL, 8);
            actions.margin_top = 4;
            var stop = new Button.with_label (request.op.kind == "extract" ? _("Stop Extracting") : (request.op.is_move ? _("Stop Moving") : _("Stop Copying")));
            stop.add_css_class ("flat");
            stop.clicked.connect (() => respond (ConflictChoice.CANCEL));
            set_cancel_button (stop);
            actions.append (stop);
            var spacer = new Box (Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            actions.append (spacer);
            var skip = new Button.with_label (_("Skip"));
            skip.clicked.connect (() => respond (ConflictChoice.SKIP));
            actions.append (skip);
            var keep = new Button.with_label (_("Keep Both"));
            keep.clicked.connect (() => respond (ConflictChoice.KEEP_BOTH));
            actions.append (keep);
            var replace = new Button.with_label (_("Replace"));
            replace.add_css_class (folders ? "flat" : "destructive-action");
            replace.tooltip_text = _("The existing item is moved to the Trash");
            replace.clicked.connect (() => respond (ConflictChoice.REPLACE));
            actions.append (replace);
            if (folders) {
                var merge = new Button.with_label (_("Merge"));
                merge.add_css_class ("suggested-action");
                merge.tooltip_text = _("Add the contents to the existing folder, asking about files that exist in both");
                merge.clicked.connect (() => respond (ConflictChoice.MERGE));
                actions.append (merge);
                merge.grab_focus ();
            } else {
                keep.add_css_class ("suggested-action");
            }
            box.append (actions);
            content_box.append (box);

            close_request.connect (() => {
                if (!answered) respond (ConflictChoice.CANCEL);
                return false;
            });
        }

        private void respond (ConflictChoice choice) {
            if (answered) return;
            answered = true;
            request.answer (choice, apply_all.active, choice == ConflictChoice.KEEP_BOTH ? rename_entry.text : null);
            close_dialog ();
        }

        private static bool same_content (GLib.File a, GLib.File b, int64 size) {
            if (size > 4 * 1024 * 1024) return false;
            try {
                uint8[] x, y;
                a.load_contents (null, out x, null);
                b.load_contents (null, out y, null);
                return x.length == y.length && Memory.cmp (x, y, x.length) == 0;
            } catch (Error e) {
                return false;
            }
        }

        private static string folder_name (GLib.File file) {
            var parent = file.get_parent ();
            if (parent == null) return "/";
            if (parent.get_path () == Environment.get_home_dir ()) return _("Home");
            return parent.get_basename () ?? parent.get_uri ();
        }

        private static int64 modified (FileInfo info) {
            var dt = info.get_modification_date_time ();
            return dt != null ? dt.to_unix () : 0;
        }

        private Widget card (string heading, GLib.File file, FileInfo info, string? newer, string? larger) {
            var frame = new Box (Orientation.VERTICAL, 8);
            frame.add_css_class ("files-conflict-card");

            var top = new Box (Orientation.HORIZONTAL, 6);
            var title = new Label (heading);
            title.xalign = 0;
            title.hexpand = true;
            title.add_css_class ("heading");
            top.append (title);
            foreach (string? badge in new string?[] { newer, larger }) {
                if (badge == null) continue;
                var pill = new Label (badge);
                pill.add_css_class ("files-conflict-badge");
                top.append (pill);
            }
            frame.append (top);

            frame.append (preview (file, info));

            var name = new Label (info.get_display_name ());
            name.ellipsize = Pango.EllipsizeMode.MIDDLE;
            name.xalign = 0;
            frame.append (name);

            var details = new Label (describe (file, info));
            details.xalign = 0;
            details.wrap = true;
            details.add_css_class ("dim-label");
            details.add_css_class ("caption");
            frame.append (details);
            return frame;
        }

        private Widget preview (GLib.File file, FileInfo info) {
            string? thumb = info.get_attribute_byte_string (FileAttribute.THUMBNAIL_PATH);
            string type = info.get_content_type () ?? "";
            Widget widget;
            if ((thumb != null && thumb != "") || (ContentType.is_a (type, "image/*") && info.get_size () < 20 * 1024 * 1024 && file.query_exists ())) {
                var picture = thumb != null && thumb != "" ? new Picture.for_filename (thumb) : new Picture.for_file (file);
                picture.content_fit = ContentFit.COVER;
                picture.can_shrink = true;
                widget = picture;
            } else {
                var image = new Image ();
                var icon = info.get_icon ();
                if (icon != null) image.gicon = icon;
                else image.icon_name = "text-x-generic";
                image.pixel_size = 64;
                widget = image;
            }
            widget.set_size_request (-1, 110);
            widget.add_css_class ("files-conflict-preview");
            return widget;
        }

        private string describe (GLib.File file, FileInfo info) {
            string when = "";
            var dt = info.get_modification_date_time ();
            if (dt != null) when = dt.to_local ().format ("%-d %b %Y, %H:%M");
            if (info.get_file_type () == FileType.DIRECTORY) {
                int count = 0;
                try {
                    var en = file.enumerate_children ("standard::name", FileQueryInfoFlags.NONE);
                    while (en.next_file () != null && count < 10000) count++;
                } catch (Error e) {
                }
                string items = ngettext ("%d item", "%d items", count).printf (count);
                return when != "" ? "%s\n%s".printf (items, when) : items;
            }
            string size = GLib.format_size (info.get_size ());
            return when != "" ? "%s\n%s".printf (size, when) : size;
        }
    }
}

using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Files.Archives {

    public class CreateArchiveDialog : AppDialog {
        public signal void create_requested(ArchiveCreator creator);

        private const ArchiveKind[] KINDS = {
            ArchiveKind.ZIP, ArchiveKind.SEVEN_ZIP, ArchiveKind.TAR_GZ, ArchiveKind.TAR_XZ,
            ArchiveKind.TAR_ZST, ArchiveKind.TAR_BZ2, ArchiveKind.TAR
        };
        private const int64[] PART_SIZES = {
            100 * 1024 * 1024, 700 * 1024 * 1024, 1024 * 1024 * 1024, 4000LL * 1024 * 1024
        };

        private GLib.File folder;
        private string[] sources;
        private ArchiveKind[] kinds = {};
        private Entry name_entry;
        private Label message_label;
        private Image message_icon;
        private DropDown format_drop;
        private DropDown level_drop;
        private ActionRow level_row;
        private PreferencesGroup protect_group;
        private PasswordRow password_row;
        private PasswordRow confirm_row;
        private DropDown part_drop;
        private Button create_btn;

        public CreateArchiveDialog(Gtk.Application app, Gtk.Window? parent, GLib.File folder, string[] sources, string default_name) {
            base(app, true);
            this.folder = folder;
            this.sources = sources;
            set_title(_("Create Archive"));
            if (parent != null) transient_for = parent;
            set_default_size(520, -1);
            resizable = false;

            foreach (var k in KINDS) {
                if (ArchiveFormats.supports_writing(k)) kinds += k;
            }

            var body = new Box(Orientation.VERTICAL, 14);
            body.margin_start = body.margin_end = 18;
            body.margin_top = 6;
            body.margin_bottom = 12;
            content_box.append(body);

            var header = new Box(Orientation.HORIZONTAL, 16);
            header.margin_start = header.margin_end = 6;
            var icon = new Image.from_icon_name("package-x-generic");
            icon.pixel_size = 64;
            icon.valign = Align.START;
            header.append(icon);
            var fields = new Box(Orientation.VERTICAL, 6);
            fields.hexpand = true;
            fields.valign = Align.CENTER;
            var what = new Label(sources.length == 1
                ? _("\"%s\" in %s").printf(Path.get_basename(sources[0]), folder_label(folder))
                : ngettext("%d item in %s", "%d items in %s", sources.length).printf(sources.length, folder_label(folder)));
            what.xalign = 0;
            what.ellipsize = Pango.EllipsizeMode.MIDDLE;
            what.add_css_class("dim-label");
            fields.append(what);
            name_entry = new Entry();
            name_entry.hexpand = true;
            name_entry.placeholder_text = _("Archive name");
            name_entry.text = default_name;
            Singularity.Widgets.ContextMenu.attach_editable(name_entry);
            fields.append(name_entry);
            var message = new Box(Orientation.HORIZONTAL, 6);
            message.height_request = 20;
            message_icon = new Image();
            message_icon.pixel_size = 16;
            message.append(message_icon);
            message_label = new Label("");
            message_label.xalign = 0;
            message_label.wrap = true;
            message_label.hexpand = true;
            message_label.add_css_class("caption");
            message.append(message_label);
            fields.append(message);
            header.append(fields);
            body.append(header);

            var format_group = new PreferencesGroup(_("Format"));
            string[] names = {};
            foreach (var k in kinds) names += k.label();
            format_drop = new DropDown.from_strings(names);
            format_drop.valign = Align.CENTER;
            var format_row = new ActionRow(_("Type"), _("ZIP opens everywhere, 7z is smaller"));
            format_row.add_suffix(format_drop);
            format_group.add_row(format_row);
            level_drop = new DropDown.from_strings({ "" });
            level_drop.valign = Align.CENTER;
            level_row = new ActionRow(_("Compression"), null);
            level_row.add_suffix(level_drop);
            format_group.add_row(level_row);
            part_drop = new DropDown.from_strings({ _("Off"), _("100 MB"), _("700 MB"), _("1 GB"), _("4 GB") });
            part_drop.valign = Align.CENTER;
            var part_row = new ActionRow(_("Split into Parts"), _("Parts end in .001, .002 and open together"));
            part_row.add_suffix(part_drop);
            format_group.add_row(part_row);
            body.append(format_group);

            protect_group = new PreferencesGroup(_("Protection"));
            password_row = new PasswordRow(_("Password"));
            confirm_row = new PasswordRow(_("Confirm Password"));
            confirm_row.visible = false;
            protect_group.add_row(password_row);
            protect_group.add_row(confirm_row);
            body.append(protect_group);

            var bar = new Box(Orientation.HORIZONTAL, 8);
            bar.margin_start = bar.margin_end = 18;
            bar.margin_bottom = 16;
            bar.margin_top = 4;
            var spacer = new Box(Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            bar.append(spacer);
            bar.append(add_cancel_button());
            create_btn = new Button.with_label(_("Create"));
            create_btn.add_css_class("suggested-action");
            create_btn.clicked.connect(() => submit());
            bar.append(create_btn);
            content_box.append(bar);
            default_widget = create_btn;

            format_drop.notify["selected"].connect(() => sync_format());
            name_entry.changed.connect(() => validate());
            name_entry.activate.connect(() => submit());
            password_row.entry_changed.connect(() => {
                confirm_row.visible = password_row.text != "";
                validate();
            });
            confirm_row.entry_changed.connect(() => validate());
            sync_format();
        }

        public override void open_dialog() {
            present();
            name_entry.grab_focus();
            name_entry.select_region(0, -1);
        }

        private static string folder_label(GLib.File folder) {
            string? path = folder.get_path();
            if (path != null && path == Environment.get_home_dir()) return _("Home");
            return folder.get_basename() ?? folder.get_uri();
        }

        private ArchiveKind current_kind() {
            uint i = format_drop.selected;
            return i < kinds.length ? kinds[i] : ArchiveKind.ZIP;
        }

        private CompressionLevel[] current_levels() {
            var k = current_kind();
            if (k.can_store()) return { CompressionLevel.STORE, CompressionLevel.FAST, CompressionLevel.NORMAL, CompressionLevel.BEST };
            return { CompressionLevel.FAST, CompressionLevel.NORMAL, CompressionLevel.BEST };
        }

        private void sync_format() {
            var k = current_kind();
            var levels = current_levels();
            string[] labels = {};
            uint normal = 0;
            for (int i = 0; i < levels.length; i++) {
                labels += levels[i].label();
                if (levels[i] == CompressionLevel.NORMAL) normal = i;
            }
            level_drop.model = new StringList(labels);
            level_drop.selected = normal;
            level_row.visible = k.has_levels();
            protect_group.visible = ArchiveFormats.supports_encryption(k);
            validate();
        }

        private string target_path() {
            string name = name_entry.text.strip();
            return Path.build_filename(folder.get_path() ?? "", name + current_kind().extension());
        }

        private bool validate() {
            string name = name_entry.text.strip();
            string? problem = null;
            bool warn_only = false;
            if (name == "") {
                problem = _("Enter a name for the archive.");
            } else if (name.contains("/")) {
                problem = _("The name cannot contain \"/\".");
            } else if (FileUtils.test(target_path(), FileTest.EXISTS)) {
                problem = _("An item with this name already exists.");
            } else if (protect_group.visible && password_row.text != confirm_row.text) {
                problem = _("The passwords do not match.");
                warn_only = confirm_row.text == "";
            }
            if (problem == null) {
                message_label.label = protect_group.visible && password_row.text != ""
                    ? _("Encrypted with AES-256, file names stay visible")
                    : _("Saved as %s").printf(Path.get_basename(target_path()));
                message_icon.icon_name = protect_group.visible && password_row.text != "" ? "channel-secure-symbolic" : "emblem-ok-symbolic";
                message_label.remove_css_class("error");
            } else {
                message_label.label = problem;
                message_icon.icon_name = "dialog-warning-symbolic";
                if (!warn_only) message_label.add_css_class("error");
            }
            create_btn.sensitive = problem == null;
            return problem == null;
        }

        private void submit() {
            if (!validate()) return;
            var creator = new ArchiveCreator(sources, target_path());
            creator.kind = current_kind();
            var levels = current_levels();
            creator.level = level_drop.selected < levels.length ? levels[level_drop.selected] : CompressionLevel.NORMAL;
            if (!creator.kind.has_levels()) creator.level = CompressionLevel.NORMAL;
            if (protect_group.visible && password_row.text != "") creator.password = password_row.text;
            if (part_drop.selected > 0) creator.volume_size = PART_SIZES[((int) part_drop.selected - 1).clamp(0, PART_SIZES.length - 1)];
            create_requested(creator);
            close_dialog();
        }
    }

    public class ArchivePasswordDialog : AppDialog {
        public signal void answered(string? password);

        private PasswordRow password_row;
        private bool done = false;

        public ArchivePasswordDialog(Gtk.Application app, Gtk.Window? parent, string archive_name, bool retry) {
            base(app, true);
            set_title(_("Password Required"));
            if (parent != null) transient_for = parent;
            set_default_size(440, -1);
            resizable = false;

            var body = new Box(Orientation.VERTICAL, 14);
            body.margin_start = body.margin_end = 18;
            body.margin_top = 6;
            body.margin_bottom = 12;
            content_box.append(body);

            var header = new Box(Orientation.HORIZONTAL, 16);
            var icon = new Image.from_icon_name("package-x-generic");
            icon.pixel_size = 64;
            icon.valign = Align.START;
            header.append(icon);
            var text = new Box(Orientation.VERTICAL, 4);
            text.valign = Align.CENTER;
            var headline = new Label(_("\"%s\" is protected").printf(archive_name));
            headline.xalign = 0;
            headline.wrap = true;
            headline.add_css_class("title-4");
            text.append(headline);
            var sub = new Label(retry
                ? _("That password is not correct. Try again.")
                : _("Enter the password to extract its contents."));
            sub.xalign = 0;
            sub.wrap = true;
            if (retry) sub.add_css_class("error");
            else sub.add_css_class("dim-label");
            text.append(sub);
            header.append(text);
            body.append(header);

            var group = new PreferencesGroup(_("Unlock"));
            password_row = new PasswordRow(_("Password"));
            password_row.entry_activated.connect(() => respond(password_row.text));
            group.add_row(password_row);
            body.append(group);

            var bar = new Box(Orientation.HORIZONTAL, 8);
            bar.margin_start = bar.margin_end = 18;
            bar.margin_bottom = 16;
            var spacer = new Box(Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            bar.append(spacer);
            var cancel = new Button.with_label(_("Cancel"));
            cancel.clicked.connect(() => respond(null));
            set_cancel_button(cancel);
            bar.append(cancel);
            var ok = new Button.with_label(_("Extract"));
            ok.add_css_class("suggested-action");
            ok.clicked.connect(() => respond(password_row.text));
            bar.append(ok);
            content_box.append(bar);
            default_widget = ok;

            close_request.connect(() => {
                if (!done) respond(null);
                return false;
            });
        }

        public override void open_dialog() {
            present();
            password_row.grab_focus();
        }

        private void respond(string? password) {
            if (done) return;
            done = true;
            answered(password);
            close_dialog();
        }
    }
}

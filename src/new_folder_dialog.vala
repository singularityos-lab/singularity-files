using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Files {

    public class NewFolderDialog : AppDialog {
        public signal void created(GLib.File folder);

        private GLib.File parent_folder;
        private Entry name_entry;
        private Image header_icon;
        private Image message_icon;
        private Label message_label;
        private Button create_btn;
        private PreferencesGroup template_group;
        private GenericArray<FolderTemplate> templates = new GenericArray<FolderTemplate>();
        private FolderTemplate selected;
        private string auto_name = "";
        private bool busy = false;

        public NewFolderDialog(Gtk.Application app, Gtk.Window? parent, GLib.File folder) {
            base(app, true);
            parent_folder = folder;
            set_title(_("New Folder"));
            if (parent != null) transient_for = parent;
            set_default_size(560, -1);
            resizable = false;

            templates.add(FolderTemplates.empty_template());
            var builtin = FolderTemplates.load_builtin();
            foreach (var t in builtin.data) templates.add(t);
            var user = FolderTemplates.load_user(FolderTemplates.user_dir());
            foreach (var t in user.data) templates.add(t);
            selected = templates[0];

            var body = new Box(Orientation.VERTICAL, 14);
            body.margin_start = body.margin_end = 18;
            body.margin_top = 6;
            body.margin_bottom = 12;
            content_box.append(body);

            var header = new Box(Orientation.HORIZONTAL, 16);
            header.margin_start = header.margin_end = 6;
            header_icon = new Image.from_icon_name("folder");
            header_icon.pixel_size = 64;
            header_icon.valign = Align.START;
            header.append(header_icon);

            var fields = new Box(Orientation.VERTICAL, 6);
            fields.hexpand = true;
            fields.valign = Align.CENTER;
            var where = new Label(_("In %s").printf(display_name(folder)));
            where.xalign = 0;
            where.ellipsize = Pango.EllipsizeMode.MIDDLE;
            where.add_css_class("dim-label");
            where.tooltip_text = folder.get_path() ?? folder.get_uri();
            fields.append(where);

            name_entry = new Entry();
            name_entry.hexpand = true;
            name_entry.placeholder_text = _("Folder name");
            name_entry.activates_default = false;
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

            template_group = new PreferencesGroup(_("Template"), selected.summary);
            var flow = new FlowBox();
            flow.selection_mode = SelectionMode.NONE;
            flow.homogeneous = true;
            flow.min_children_per_line = 5;
            flow.max_children_per_line = 5;
            flow.column_spacing = 6;
            flow.row_spacing = 6;
            flow.margin_top = flow.margin_bottom = 8;
            flow.margin_start = flow.margin_end = 8;
            ToggleButton? first = null;
            foreach (var t in templates.data) {
                var card = template_card(t);
                if (first == null) {
                    first = card;
                    card.active = true;
                } else {
                    card.group = first;
                }
                flow.append(card);
            }
            if (templates.length > 15) {
                var scroll = new ScrolledWindow();
                scroll.hscrollbar_policy = PolicyType.NEVER;
                scroll.propagate_natural_height = true;
                scroll.max_content_height = 360;
                scroll.child = flow;
                template_group.add_row(scroll);
            } else {
                template_group.add_row(flow);
            }
            template_group.visible = templates.length > 1;
            body.append(template_group);

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

            name_entry.changed.connect(() => validate());
            name_entry.activate.connect(() => submit());

            auto_name = FolderNames.unique(_("New Folder"), lookup);
            name_entry.text = auto_name;
            validate();
        }

        public override void open_dialog() {
            present();
            name_entry.grab_focus();
            name_entry.select_region(0, -1);
        }

        private FileType lookup(string name) {
            return FolderNames.lookup_in(parent_folder, name);
        }

        private static string display_name(GLib.File folder) {
            string? path = folder.get_path();
            if (path != null && path == Environment.get_home_dir()) return _("Home");
            try {
                var info = folder.query_info("standard::display-name", FileQueryInfoFlags.NONE, null);
                return info.get_display_name();
            } catch (Error e) {
                return folder.get_basename() ?? folder.get_uri();
            }
        }

        private ToggleButton template_card(FolderTemplate t) {
            var btn = new ToggleButton();
            btn.add_css_class("flat");
            btn.add_css_class("files-template-card");
            btn.tooltip_text = t.summary;
            var box = new Box(Orientation.VERTICAL, 6);
            box.add_css_class("files-template-body");
            var icon = new Image.from_icon_name(icon_for(t));
            icon.pixel_size = 48;
            box.append(icon);
            var label = new Label(t.name);
            label.add_css_class("caption");
            label.justify = Justification.CENTER;
            label.wrap = true;
            label.lines = 2;
            label.ellipsize = Pango.EllipsizeMode.END;
            label.max_width_chars = 11;
            label.width_chars = 9;
            box.append(label);
            btn.child = box;
            btn.toggled.connect(() => {
                if (btn.active) choose(t);
            });
            return btn;
        }

        private string icon_for(FolderTemplate t) {
            var theme = IconTheme.get_for_display(Gdk.Display.get_default());
            return theme.has_icon(t.icon_name) ? t.icon_name : "folder";
        }

        private void choose(FolderTemplate t) {
            selected = t;
            template_group.description = t.summary;
            header_icon.icon_name = icon_for(t);
            string base_name = t.folder_name ?? _("New Folder");
            if (name_entry.text == auto_name || name_entry.text.strip() == "") {
                auto_name = FolderNames.unique(base_name, lookup);
                name_entry.text = auto_name;
            }
        }

        private NameState validate() {
            var state = FolderNames.check(name_entry.text, lookup);
            bool error = state.blocks() && state != NameState.EMPTY;
            show_message(FolderNames.message(state, name_entry.text), error);
            create_btn.sensitive = !state.blocks() && !busy;
            return state;
        }

        private void show_message(string text, bool error) {
            message_label.label = text;
            message_icon.visible = text != "";
            message_icon.icon_name = error ? "dialog-error-symbolic" : "dialog-information-symbolic";
            foreach (var w in new Widget[] { message_label, message_icon }) {
                w.remove_css_class(error ? "dim-label" : "error");
                w.add_css_class(error ? "error" : "dim-label");
            }
            if (error) name_entry.add_css_class("error");
            else name_entry.remove_css_class("error");
        }

        private void submit() {
            if (busy || validate().blocks()) return;
            string name = name_entry.text.strip();
            var target = parent_folder.get_child(name);
            busy = true;
            create_btn.sensitive = false;
            name_entry.sensitive = false;
            run_create.begin(selected, target, (obj, res) => {
                string? err = run_create.end(res);
                busy = false;
                name_entry.sensitive = true;
                if (err == null) {
                    created(target);
                    close_dialog();
                    return;
                }
                validate();
                show_message(err, true);
                name_entry.grab_focus();
            });
        }

        private static async string? run_create(FolderTemplate tpl, GLib.File target) {
            SourceFunc resume = run_create.callback;
            string? err = null;
            var now = new DateTime.now_local();
            new Thread<bool>("new-folder", () => {
                try {
                    FolderTemplates.create(tpl, target, now);
                } catch (Error e) {
                    err = e.message;
                }
                Idle.add((owned) resume);
                return true;
            });
            yield;
            return err;
        }
    }
}

using Gtk;
using Singularity.Accounts;

namespace Singularity.Apps.Files {

    public class CloudView : Box {
        public CloudLocations locations { get; private set; }
        public bool active { get; private set; default = false; }

        private const string[] SHADOWED_ACTIONS = { "reload", "new-folder", "select-all" };

        public signal void activated();
        public signal void open_file(File file);

        private unowned Singularity.Widgets.Window window;
        private unowned Stack view_stack;
        private unowned Box path_bar;
        private GLib.Settings settings;

        private Account? account = null;
        private CloudDrive? drive = null;
        private Gee.ArrayList<CloudEntry> trail = new Gee.ArrayList<CloudEntry>();
        private GLib.ListStore store = new GLib.ListStore(typeof(CloudEntry));
        private MultiSelection selection;
        private Stack stack;
        private Singularity.Widgets.DataListView list_widget;
        private Singularity.Widgets.DataGridView grid_widget;
        private Box status_holder;
        private Label count_label;
        private Button upload_btn;
        private Button new_folder_btn;
        private Button refresh_btn;
        private Spinner busy_spinner;
        private Cancellable cancellable = new Cancellable();
        private uint generation = 0;
        private int busy = 0;
        private string view_mode = "";
        private bool blocked = false;

        public CloudView(Singularity.Widgets.Window window, Stack view_stack, Box path_bar, GLib.Settings settings) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.window = window;
            this.view_stack = view_stack;
            this.path_bar = path_bar;
            this.settings = settings;
            hexpand = true;
            vexpand = true;

            selection = new MultiSelection(store);
            stack = new Stack();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.hexpand = true;
            stack.vexpand = true;
            count_label = new Label("");
            count_label.add_css_class("dim-label");
            count_label.add_css_class("caption");
            count_label.add_css_class("files-count-overlay");
            count_label.halign = Align.END;
            count_label.valign = Align.END;
            count_label.margin_end = 12;
            count_label.margin_bottom = 8;
            count_label.can_target = false;
            var overlay = new Overlay();
            overlay.child = stack;
            overlay.add_overlay(count_label);
            append(overlay);
            store.items_changed.connect(() => {
                uint n = store.get_n_items();
                count_label.label = n == 0 ? "" : ngettext("%u item", "%u items", n).printf(n);
            });

            build_list();
            build_grid();

            var loading = new Spinner();
            loading.width_request = 32;
            loading.height_request = 32;
            loading.halign = Align.CENTER;
            loading.valign = Align.CENTER;
            loading.spinning = true;
            stack.add_named(loading, "loading");

            status_holder = new Box(Orientation.VERTICAL, 0);
            status_holder.hexpand = true;
            status_holder.vexpand = true;
            stack.add_named(status_holder, "status");

            var drop = new DropTarget(typeof(Gdk.FileList), Gdk.DragAction.COPY);
            drop.drop.connect((value, x, y) => {
                if (drive == null || !value.holds(typeof(Gdk.FileList))) return false;
                var files = new Gee.ArrayList<File>();
                foreach (unowned File f in ((Gdk.FileList) value.get_boxed()).get_files()) files.add(f);
                upload_files.begin(files);
                return files.size > 0;
            });
            add_controller(drop);

            var keys = new EventControllerKey();
            keys.set_propagation_phase(PropagationPhase.CAPTURE);
            keys.key_pressed.connect(on_key_pressed);
            ((Widget) window).add_controller(keys);

            upload_btn = window.add_bubble_icon("document-send-symbolic", _("Upload…"), () => choose_upload());
            new_folder_btn = window.add_bubble_icon("folder-new-symbolic", _("New Folder…"), () => ask_new_folder());
            refresh_btn = window.add_bubble_icon("view-refresh-symbolic", _("Refresh (F5)"), () => reload());
            busy_spinner = new Spinner();
            busy_spinner.tooltip_text = _("Working…");
            window.add_bubble_widget(busy_spinner);
            set_bubbles_visible(false);

            view_stack.add_named(this, "cloud");
            view_stack.notify["visible-child-name"].connect(() => {
                Idle.add(() => {
                    if (active && view_stack.visible_child_name != "cloud") deactivate();
                    return Source.REMOVE;
                });
            });
            view_mode = settings.get_string("view-mode");
            settings.changed["view-mode"].connect(() => {
                string mode = settings.get_string("view-mode");
                if (mode == view_mode) return;
                view_mode = mode;
                if (!active) return;
                view_stack.visible_child_name = "cloud";
                if (stack.visible_child_name == "list" || stack.visible_child_name == "grid") show_items();
            });
            settings.changed["icon-size"].connect(() => {
                if (active) grid_widget.grid_view.factory = make_grid_factory();
            });

            locations = new CloudLocations();
            locations.location_activated.connect(open_account);
            locations.location_gone.connect((id) => {
                if (account == null || account.id != id) return;
                cancellable.cancel();
                drive = null;
                store.remove_all();
                show_status("singularity-account-generic", _("Online Account Unavailable"),
                    _("This account was removed or its files were switched off in Settings."), null);
                update_path_bar();
            });
            Manager.get_default().account_changed.connect((changed) => {
                if (!active || account == null || changed.id != account.id) return;
                account = changed;
                update_path_bar();
                if (!account.healthy) show_reauth();
                else if (blocked) reload();
            });
        }

        public Box sidebar_section {
            get { return locations.section; }
        }

        private void set_bubbles_visible(bool visible) {
            foreach (string name in SHADOWED_ACTIONS) {
                var action = window.application.lookup_action(name) as SimpleAction;
                if (action != null) action.set_enabled(!visible);
            }
            upload_btn.visible = visible;
            new_folder_btn.visible = visible;
            refresh_btn.visible = visible;
            busy_spinner.visible = visible && busy > 0;
        }

        private void set_busy(bool on) {
            busy += on ? 1 : -1;
            busy_spinner.spinning = busy > 0;
            busy_spinner.visible = active && busy > 0;
        }

        private void deactivate() {
            active = false;
            locations.set_active("");
            set_bubbles_visible(false);
        }

        public void open_account(Account target) {
            cancellable.cancel();
            cancellable = new Cancellable();
            account = target;
            drive = CloudDrive.for_account(target);
            trail.clear();
            var root = new CloudEntry();
            root.id = drive != null ? drive.root_id : "";
            root.name = target.display_name;
            root.is_folder = true;
            trail.add(root);
            active = true;
            locations.set_active(target.id);
            view_stack.visible_child_name = "cloud";
            set_bubbles_visible(true);
            activated();
            reload();
        }

        private CloudEntry current_folder() {
            return trail[trail.size - 1];
        }

        public void reload() {
            load_folder.begin();
        }

        private async void load_folder() {
            uint gen = ++generation;
            update_path_bar();
            if (account == null) return;
            if (!account.healthy) {
                show_reauth();
                return;
            }
            if (drive == null) {
                show_status("network-error", _("Could Not Open This Account"),
                    _("This online account has no file storage that Files can open."), null);
                return;
            }
            blocked = false;
            store.remove_all();
            stack.visible_child_name = "loading";
            try {
                var entries = yield drive.list(current_folder().id, cancellable);
                if (gen != generation) return;
                entries.sort((a, b) => {
                    if (a.is_folder != b.is_folder) return a.is_folder ? -1 : 1;
                    return a.name.collate(b.name);
                });
                var items = new Object[entries.size];
                for (int i = 0; i < entries.size; i++) items[i] = entries[i];
                store.splice(0, store.get_n_items(), items);
                if (entries.size == 0) show_empty();
                else show_items();
            } catch (Error e) {
                if (gen != generation) return;
                show_error(e);
            }
        }

        private void show_items() {
            string mode = settings.get_string("view-mode");
            stack.visible_child_name = mode == "grid" ? "grid" : "list";
        }

        private void show_status(string icon, string title, string description, Widget? child) {
            Widget? old;
            while ((old = status_holder.get_first_child()) != null) status_holder.remove(old);
            var page = new Singularity.Widgets.StatusPage();
            page.icon_name = icon;
            page.title = title;
            page.description = description;
            page.hexpand = true;
            page.vexpand = true;
            if (child != null) page.child = child;
            status_holder.append(page);
            stack.visible_child_name = "status";
        }

        private Button pill(string label, bool suggested) {
            var btn = new Button.with_label(label);
            btn.halign = Align.CENTER;
            btn.add_css_class("pill");
            if (suggested) btn.add_css_class("suggested-action");
            return btn;
        }

        private void show_empty() {
            var upload = pill(_("Upload…"), true);
            upload.clicked.connect(choose_upload);
            show_status("folder", _("This Folder Is Empty"), _("Drop files here or upload something new"), upload);
        }

        private void show_reauth() {
            blocked = true;
            store.remove_all();
            var open = pill(_("Open Settings"), true);
            open.clicked.connect(open_account_settings);
            show_status(account.icon_name, _("Sign In Again"),
                _("%s needs you to sign in again in Settings before its files can be shown.").printf(account.display_name), open);
        }

        private void show_error(Error e) {
            if (e is AccountsError.CANCELLED || e is IOError.CANCELLED) return;
            if (e is AccountsError.NEEDS_REAUTH || (account != null && !account.healthy)) {
                show_reauth();
                return;
            }
            var buttons = new Box(Orientation.HORIZONTAL, 12);
            buttons.halign = Align.CENTER;
            var retry = pill(_("Try Again"), true);
            retry.clicked.connect(() => reload());
            buttons.append(retry);
            if (trail.size > 1) {
                var top = pill(_("Open Top Folder"), false);
                top.clicked.connect(() => go_to_level(0));
                buttons.append(top);
            }
            string title = (e is AccountsError.NETWORK) ? _("Could Not Reach the Server")
                : (e is AccountsError.NOT_FOUND) ? _("Folder Not Found")
                : _("Could Not Open This Folder");
            string description = (e is AccountsError.NOT_FOUND)
                ? _("It was moved or deleted on the server.")
                : e.message;
            show_status("network-error", title, description, buttons);
        }

        private void open_account_settings() {
            try {
                Singularity.Shell.ShellService shell = Bus.get_proxy_sync(
                    BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                shell.open_settings("accounts");
            } catch (Error e) {
                warning("Failed to open settings: %s", e.message);
            }
        }

        private void toast(string text) {
            window.add_toast(new Singularity.Widgets.Toast(text));
        }

        private void report(string title, Error e) {
            if (e is AccountsError.CANCELLED || e is IOError.CANCELLED) return;
            if (e is AccountsError.NEEDS_REAUTH) {
                show_reauth();
                return;
            }
            toast("%s: %s".printf(title, e.message));
        }

        private void go_to_level(int level) {
            if (level < 0 || level >= trail.size) return;
            while (trail.size > level + 1) trail.remove_at(trail.size - 1);
            reload();
        }

        private void update_path_bar() {
            if (!active) return;
            Widget? child;
            while ((child = path_bar.get_first_child()) != null) path_bar.remove(child);
            if (account == null) return;
            var root_icon = new Button.from_icon_name(account.symbolic_icon_name);
            root_icon.tooltip_text = account.provider_name;
            root_icon.add_css_class("flat");
            root_icon.add_css_class("path-button");
            root_icon.clicked.connect(() => go_to_level(0));
            path_bar.append(root_icon);
            path_bar.append(path_button(account.display_name, 0));
            int start = trail.size > 4 ? trail.size - 2 : 1;
            if (start > 1) {
                path_bar.append(separator());
                var ellipsis = new Label("..");
                ellipsis.add_css_class("dim-label");
                path_bar.append(ellipsis);
            }
            for (int i = start; i < trail.size; i++) {
                path_bar.append(separator());
                path_bar.append(path_button(trail[i].name, i));
            }
        }

        private Label separator() {
            var sep = new Label("/");
            sep.add_css_class("path-separator");
            return sep;
        }

        private Button path_button(string text, int level) {
            var btn = new Button.with_label(text);
            btn.add_css_class("flat");
            btn.add_css_class("path-button");
            var lbl = btn.get_child() as Label;
            if (lbl != null) {
                lbl.ellipsize = Pango.EllipsizeMode.END;
                lbl.max_width_chars = 14;
            }
            btn.clicked.connect(() => go_to_level(level));
            return btn;
        }

        private static string format_modified(DateTime? modified) {
            if (modified == null) return "";
            var local = modified.to_local();
            var now = new DateTime.now_local();
            var diff = now.difference(local) / TimeSpan.DAY;
            if (diff == 0) return local.format(_("%H:%M"));
            if (diff < 365) return local.format(_("%b %d"));
            return local.format(_("%Y-%m-%d"));
        }

        private static GLib.Icon icon_for(CloudEntry entry) {
            if (entry.is_folder) return new ThemedIcon("folder");
            string type = entry.content_type != "" && entry.content_type != "application/octet-stream"
                ? entry.content_type
                : ContentType.guess(entry.name, null, null);
            return ContentType.get_icon(type);
        }

        private void build_list() {
            list_widget = new Singularity.Widgets.DataListView();
            list_widget.set_selection_model(selection);
            var view = list_widget.column_view;
            view.add_css_class("file-view");

            var name_factory = new SignalListItemFactory();
            name_factory.setup.connect((item) => {
                var box = new Box(Orientation.HORIZONTAL, 12);
                var img = new Image();
                img.pixel_size = 24;
                var label = new Label("");
                label.ellipsize = Pango.EllipsizeMode.MIDDLE;
                box.append(img);
                box.append(label);
                ((ListItem) item).set_child(box);
            });
            name_factory.bind.connect((item) => {
                var list_item = (ListItem) item;
                var box = (Box) list_item.get_child();
                var entry = (CloudEntry) list_item.get_item();
                box.set_data<CloudEntry>("cloud-entry", entry);
                ((Image) box.get_first_child()).gicon = icon_for(entry);
                ((Label) box.get_last_child()).label = entry.name;
            });
            var col_name = new ColumnViewColumn(_("Name"), name_factory);
            col_name.expand = true;
            col_name.resizable = true;
            view.append_column(col_name);

            var size_factory = new SignalListItemFactory();
            size_factory.setup.connect((item) => {
                var label = new Label("");
                label.halign = Align.END;
                ((ListItem) item).set_child(label);
            });
            size_factory.bind.connect((item) => {
                var list_item = (ListItem) item;
                var entry = (CloudEntry) list_item.get_item();
                ((Label) list_item.get_child()).label = entry.is_folder || entry.size < 0 ? "--" : format_size((uint64) entry.size);
            });
            var col_size = new ColumnViewColumn(_("Size"), size_factory);
            col_size.resizable = true;
            view.append_column(col_size);

            var modified_factory = new SignalListItemFactory();
            modified_factory.setup.connect((item) => {
                var label = new Label("");
                label.halign = Align.END;
                label.add_css_class("dim-label");
                ((ListItem) item).set_child(label);
            });
            modified_factory.bind.connect((item) => {
                var list_item = (ListItem) item;
                var entry = (CloudEntry) list_item.get_item();
                ((Label) list_item.get_child()).label = format_modified(entry.modified);
            });
            var col_modified = new ColumnViewColumn(_("Modified"), modified_factory);
            col_modified.fixed_width = 90;
            col_modified.resizable = true;
            view.append_column(col_modified);

            var menu_gesture = new GestureClick();
            menu_gesture.button = 3;
            menu_gesture.set_propagation_phase(PropagationPhase.CAPTURE);
            menu_gesture.pressed.connect((n, x, y) => {
                var entry = entry_at(view, x, y);
                if (entry == null) return;
                menu_gesture.set_state(EventSequenceState.CLAIMED);
                select_for_menu(entry);
                show_item_menu(view, entry, x, y);
            });
            view.add_controller(menu_gesture);
            list_widget.row_activated.connect(activate_position);
            list_widget.background_right_clicked.connect((x, y) => show_background_menu(list_widget.scroll, x, y));
            stack.add_named(list_widget, "list");
        }

        private SignalListItemFactory make_grid_factory() {
            int size = settings.get_int("icon-size");
            var factory = new SignalListItemFactory();
            factory.setup.connect((item) => {
                var box = new Box(Orientation.VERTICAL, 6);
                box.add_css_class("file-grid-item");
                box.halign = Align.CENTER;
                box.valign = Align.START;
                var img = new Image();
                img.pixel_size = size;
                img.add_css_class("file-icon");
                var label = new Label("");
                label.ellipsize = Pango.EllipsizeMode.END;
                label.wrap = true;
                label.wrap_mode = Pango.WrapMode.WORD_CHAR;
                label.lines = 2;
                label.max_width_chars = 12;
                label.justify = Justification.CENTER;
                box.append(img);
                box.append(label);
                var gesture = new GestureClick();
                gesture.button = 3;
                gesture.pressed.connect((n, x, y) => {
                    var entry = box.get_data<CloudEntry>("cloud-entry");
                    if (entry == null) return;
                    gesture.set_state(EventSequenceState.CLAIMED);
                    select_for_menu(entry);
                    show_item_menu(box, entry, x, y);
                });
                box.add_controller(gesture);
                ((ListItem) item).set_child(box);
            });
            factory.bind.connect((item) => {
                var list_item = (ListItem) item;
                var box = (Box) list_item.get_child();
                var entry = (CloudEntry) list_item.get_item();
                box.set_data<CloudEntry>("cloud-entry", entry);
                ((Image) box.get_first_child()).gicon = icon_for(entry);
                ((Label) box.get_last_child()).label = entry.name;
            });
            return factory;
        }

        private void build_grid() {
            grid_widget = new Singularity.Widgets.DataGridView();
            grid_widget.set_selection_model(selection);
            grid_widget.grid_view.add_css_class("file-grid");
            grid_widget.max_columns = 8;
            grid_widget.min_columns = 2;
            grid_widget.set_factory(make_grid_factory());
            grid_widget.item_activated.connect(activate_position);
            grid_widget.background_right_clicked.connect((x, y) => show_background_menu(grid_widget.scroll, x, y));
            stack.add_named(grid_widget, "grid");
        }

        private CloudEntry? entry_at(Widget view, double x, double y) {
            Widget? w = view.pick(x, y, PickFlags.DEFAULT);
            while (w != null && w != view) {
                if (w.get_css_name() == "row") {
                    for (var cell = w.get_first_child(); cell != null; cell = cell.get_next_sibling()) {
                        var child = cell.get_first_child();
                        if (child == null) continue;
                        var entry = child.get_data<CloudEntry>("cloud-entry");
                        if (entry != null) return entry;
                    }
                    return null;
                }
                w = w.get_parent();
            }
            return null;
        }

        private void select_for_menu(CloudEntry entry) {
            for (uint i = 0; i < store.get_n_items(); i++) {
                if (store.get_item(i) == entry) {
                    if (!selection.is_selected(i)) selection.select_item(i, true);
                    return;
                }
            }
        }

        private Gee.ArrayList<CloudEntry> selected_entries() {
            var result = new Gee.ArrayList<CloudEntry>();
            for (uint i = 0; i < store.get_n_items(); i++) {
                if (selection.is_selected(i)) result.add((CloudEntry) store.get_item(i));
            }
            return result;
        }

        private void activate_position(uint position) {
            var entry = store.get_item(position) as CloudEntry;
            if (entry != null) open_entry(entry);
        }

        private void open_entry(CloudEntry entry) {
            if (entry.is_folder) {
                trail.add(entry);
                reload();
                return;
            }
            download_and_open.begin(entry);
        }

        private async void download_and_open(CloudEntry entry) {
            if (drive == null) return;
            set_busy(true);
            try {
                var file = yield CloudFile.download(drive, entry, cancellable);
                open_file(file.local);
            } catch (Error e) {
                report(_("Could not open %s").printf(entry.name), e);
            }
            set_busy(false);
        }

        private bool on_key_pressed(uint keyval, uint keycode, Gdk.ModifierType state) {
            if (!active) return false;
            var focus = window.get_focus();
            if (focus is Gtk.Editable || focus is Gtk.Text) return false;
            bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
            bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
            if (keyval == Gdk.Key.F5) {
                reload();
                return true;
            }
            if (ctrl && shift && (keyval == Gdk.Key.N || keyval == Gdk.Key.n)) {
                ask_new_folder();
                return true;
            }
            if (ctrl && (keyval == Gdk.Key.a || keyval == Gdk.Key.A)) {
                selection.select_all();
                return true;
            }
            var selected = selected_entries();
            if (selected.size == 0) return false;
            if (!ctrl && (keyval == Gdk.Key.Delete || keyval == Gdk.Key.KP_Delete)) {
                confirm_delete(selected);
                return true;
            }
            if (keyval == Gdk.Key.F2 && selected.size == 1) {
                ask_rename(selected[0]);
                return true;
            }
            return false;
        }

        private void show_item_menu(Widget widget, CloudEntry entry, double x, double y) {
            var menu = new Singularity.Widgets.ContextMenu(widget);
            Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
            menu.set_pointing_to(rect);
            var selected = selected_entries();
            if (selected.size <= 1) {
                menu.add_item(_("Open"), "document-open-symbolic", () => open_entry(entry));
                if (!entry.is_folder) {
                    menu.add_item(_("Save a Copy…"), "document-save-as-symbolic", () => save_copy(entry));
                }
                menu.add_separator();
                menu.add_item(_("Rename…"), "document-edit-symbolic", () => ask_rename(entry));
            }
            menu.add_item(_("Delete…"), "user-trash-symbolic", () => confirm_delete(selected.size > 0 ? selected : single(entry)), "destructive-action");
            release_on_close(menu);
            menu.popup();
        }

        private void show_background_menu(Widget widget, double x, double y) {
            if (drive == null) return;
            var menu = new Singularity.Widgets.ContextMenu(widget);
            Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
            menu.set_pointing_to(rect);
            menu.add_item(_("New Folder…"), "folder-new-symbolic", () => ask_new_folder());
            menu.add_item(_("Upload…"), "document-send-symbolic", () => choose_upload());
            menu.add_separator();
            menu.add_item(_("Refresh"), "view-refresh-symbolic", () => reload());
            release_on_close(menu);
            menu.popup();
        }

        private void release_on_close(Popover popover) {
            popover.closed.connect(() => {
                Idle.add(() => {
                    popover.unparent();
                    return Source.REMOVE;
                });
            });
        }

        private static Gee.ArrayList<CloudEntry> single(CloudEntry entry) {
            var list = new Gee.ArrayList<CloudEntry>();
            list.add(entry);
            return list;
        }

        private void choose_upload() {
            if (drive == null) return;
            var dialog = new Gtk.FileDialog();
            dialog.title = _("Upload to %s").printf(current_folder().name);
            dialog.accept_label = _("Upload");
            dialog.open_multiple.begin(window, null, (obj, res) => {
                try {
                    var model = dialog.open_multiple.end(res);
                    var files = new Gee.ArrayList<File>();
                    for (uint i = 0; i < model.get_n_items(); i++) files.add((File) model.get_item(i));
                    upload_files.begin(files);
                } catch (Error e) {
                    if (!(e is Gtk.DialogError.DISMISSED) && !(e is Gtk.DialogError.CANCELLED)) {
                        warning("Upload dialog: %s", e.message);
                    }
                }
            });
        }

        private async void upload_files(Gee.List<File> files) {
            if (drive == null || files.size == 0) return;
            var target_drive = drive;
            string folder_id = current_folder().id;
            string folder_name = current_folder().name;
            uint gen = generation;
            int done = 0;
            set_busy(true);
            foreach (var file in files) {
                if (file.get_path() == null || file.query_file_type(FileQueryInfoFlags.NONE) != FileType.REGULAR) {
                    toast(_("Only files can be uploaded, %s was skipped").printf(file.get_basename()));
                    continue;
                }
                try {
                    yield target_drive.upload(folder_id, file.get_basename(), file, cancellable);
                    done++;
                } catch (Error e) {
                    report(_("Could not upload %s").printf(file.get_basename()), e);
                }
            }
            set_busy(false);
            if (done > 0) {
                toast(ngettext("Uploaded %d file to %s", "Uploaded %d files to %s", done).printf(done, folder_name));
                if (gen == generation && drive == target_drive) reload();
            }
        }

        private void save_copy(CloudEntry entry) {
            if (drive == null) return;
            var target_drive = drive;
            var dialog = new Gtk.FileDialog();
            dialog.title = _("Save a Copy");
            dialog.initial_name = entry.name;
            string? downloads = Environment.get_user_special_dir(UserDirectory.DOWNLOAD);
            if (downloads == null || !FileUtils.test(downloads, FileTest.IS_DIR)) downloads = Environment.get_home_dir();
            dialog.initial_folder = File.new_for_path(downloads);
            dialog.save.begin(window, null, (obj, res) => {
                try {
                    var dest = dialog.save.end(res);
                    if (dest != null) download_copy.begin(target_drive, entry, dest);
                } catch (Error e) {
                    if (!(e is Gtk.DialogError.DISMISSED) && !(e is Gtk.DialogError.CANCELLED)) {
                        warning("Save dialog: %s", e.message);
                    }
                }
            });
        }

        private async void download_copy(CloudDrive target_drive, CloudEntry entry, File dest) {
            set_busy(true);
            try {
                yield target_drive.download(entry, dest, cancellable);
                toast(_("Saved a copy of %s").printf(entry.name));
            } catch (Error e) {
                report(_("Could not save %s").printf(entry.name), e);
            }
            set_busy(false);
        }

        private void ask_name(string title, string action_label, string initial, owned NameCallback callback) {
            var dialog = new Singularity.Widgets.AppDialog(window.application, false);
            dialog.title = title;
            dialog.transient_for = window;
            dialog.set_default_size(360, 160);

            var box = new Box(Orientation.VERTICAL, 16);
            box.margin_top = 24;
            box.margin_bottom = 24;
            box.margin_start = 24;
            box.margin_end = 24;

            var entry = new Entry();
            entry.text = initial;
            entry.hexpand = true;
            box.append(entry);

            var btn_box = new Box(Orientation.HORIZONTAL, 8);
            btn_box.halign = Align.END;
            var cancel_btn = new Button.with_label(_("Cancel"));
            cancel_btn.add_css_class("flat");
            cancel_btn.clicked.connect(() => dialog.close());
            dialog.set_cancel_button(cancel_btn);
            var ok_btn = new Button.with_label(action_label);
            ok_btn.add_css_class("suggested-action");
            ok_btn.clicked.connect(() => {
                string name = entry.text.strip();
                if (name != "" && !name.contains("/")) callback(name);
                dialog.close();
            });
            entry.activate.connect(() => ok_btn.clicked());
            btn_box.append(cancel_btn);
            btn_box.append(ok_btn);
            box.append(btn_box);

            dialog.content_box.append(box);
            dialog.present();
            entry.grab_focus();
            int dot = initial.last_index_of(".");
            entry.select_region(0, dot > 0 ? initial.char_count(dot) : -1);
        }

        private delegate void NameCallback(string name);

        private void ask_new_folder() {
            if (drive == null) return;
            ask_name(_("New Folder"), _("Create"), _("New Folder"), (name) => create_folder.begin(name));
        }

        private async void create_folder(string name) {
            if (drive == null) return;
            var target_drive = drive;
            string folder_id = current_folder().id;
            uint gen = generation;
            set_busy(true);
            try {
                yield target_drive.create_folder(folder_id, name, cancellable);
                if (gen == generation && drive == target_drive) reload();
            } catch (Error e) {
                report(_("Could not create %s").printf(name), e);
            }
            set_busy(false);
        }

        private void ask_rename(CloudEntry entry) {
            if (drive == null) return;
            ask_name(_("Rename"), _("Rename"), entry.name, (name) => {
                if (name != entry.name) rename_entry.begin(entry, name);
            });
        }

        private async void rename_entry(CloudEntry entry, string new_name) {
            var target_drive = drive;
            uint gen = generation;
            string server_name = new_name;
            if (entry.export_type != "") {
                int dot = entry.name.last_index_of(".");
                string ext = dot > 0 ? entry.name.substring(dot) : "";
                if (ext != "" && server_name.has_suffix(ext) && server_name.length > ext.length) {
                    server_name = server_name.substring(0, server_name.length - ext.length);
                }
            }
            set_busy(true);
            try {
                yield target_drive.rename(entry, server_name, cancellable);
                if (gen == generation && drive == target_drive) reload();
            } catch (Error e) {
                report(_("Could not rename %s").printf(entry.name), e);
            }
            set_busy(false);
        }

        private void confirm_delete(Gee.List<CloudEntry> entries) {
            if (drive == null || entries.size == 0) return;
            string title = entries.size == 1
                ? _("Delete %s?").printf(entries[0].name)
                : ngettext("Delete %d Item?", "Delete %d Items?", entries.size).printf(entries.size);
            string description = _("This deletes it from %s on the server. It cannot be undone.").printf(account.display_name);
            if (entries.size > 1) {
                description = _("This deletes them from %s on the server. It cannot be undone.").printf(account.display_name);
            }
            var dialog = new Singularity.Widgets.ConfirmDialog(window.application, title, null, description,
                _("Delete"), Singularity.Widgets.ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dialog.transient_for = window;
            var targets = new Gee.ArrayList<CloudEntry>();
            targets.add_all(entries);
            dialog.response.connect((r) => {
                if (r == Singularity.Widgets.ConfirmDialog.Response.PRIMARY) delete_entries.begin(targets);
            });
            dialog.present();
        }

        private async void delete_entries(Gee.List<CloudEntry> entries) {
            var target_drive = drive;
            uint gen = generation;
            set_busy(true);
            foreach (var entry in entries) {
                try {
                    yield target_drive.delete(entry, cancellable);
                } catch (Error e) {
                    report(_("Could not delete %s").printf(entry.name), e);
                }
            }
            set_busy(false);
            if (gen == generation && drive == target_drive) reload();
        }
    }
}

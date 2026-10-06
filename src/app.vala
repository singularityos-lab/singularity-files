using Gtk;
using GLib;
using Singularity;
using Singularity.Widgets;
using Singularity.FileSystem;

namespace Singularity.Apps {

    public delegate void StorageEntryFunc(string name, string icon, string? path, GLib.Volume? volume);

    public class FilesApp : Singularity.Application {
        private Files.FileOpsManager? _ops = null;
        private Gtk.Revealer? _ops_banner = null;
        private Gtk.ProgressBar? _ops_progress_bar = null;
        private Gtk.Label? _ops_label = null;
        private Gtk.Button? _ops_cancel_btn = null;

        private File current_folder;
        private GLib.ListStore file_store;
        private ColumnView file_view;
        private ColumnViewColumn col_size;
        private ColumnViewColumn col_author;
        private ColumnViewColumn col_type;
        private ColumnViewColumn col_modified;
        private Box path_bar;
        private GLib.Settings settings;
        public bool picker_mode = false;
        public string? picker_title = null;
        public bool save_mode = false;
        public bool directory_mode = false;
        private string? picker_current_name = null;
        private string? picker_accept_label = null;
        public bool portal_mode = false;
        public bool multiple_mode = false;
        private Stack? view_stack_ref = null;
        private Singularity.Widgets.SwipeNavigation? swipe_nav = null;
        private Box? _empty_holder = null;
        private string _empty_key = "";
        private File? _picker_selected_file = null;
        private FileInfo? _picker_selected_info = null;
        private Stack path_bar_stack;
        private Entry path_entry_widget;
        private GLib.GenericArray<File> clipboard_files = new GLib.GenericArray<File>();
        private bool clipboard_is_cut = false;
        private int grid_icon_size = 48;
        private GridView? _grid_view = null;
        private Singularity.Widgets.Window? active_window = null;
        private GLib.FileMonitor? folder_monitor = null;
        private uint folder_refresh_id = 0;
        private uint navigation_generation = 0;
        private Entry? filename_entry = null;
        private Entry search_entry_widget;
        private string current_search = "";
        private string _type_ahead = "";
        private uint _type_ahead_timeout = 0;
        private Popover? path_completion_popover = null;
        private ListBox? path_completion_list = null;
        private File[] nav_history = {};
        private int nav_index = -1;
        private Button? back_btn = null;
        private Button? fwd_btn = null;
        private Box? nav_box_ref = null;
        private Button? toolbar_term_btn = null;
        private Button? toolbar_search_btn = null;
        private Box? _places_box = null;
        private Gee.HashMap<string, Button> _place_buttons = new Gee.HashMap<string, Button>();
        private Button? _disks_sidebar_btn = null;
        private Gtk.Label? _file_count_lbl = null;
        private Box? _bookmarks_section = null;
        private Box? _devices_section = null;
        private Box? _picker_devices_section = null;
        private GLib.VolumeMonitor? _volume_monitor = null;
        private GLib.FileMonitor? _bookmarks_file_monitor = null;
        // Miller columns state
        private Singularity.Widgets.ColumnBrowser? _col_browser = null;
        private File[]         _col_folders = {};
        private int            _col_count = 0;
        private int            _col_viewport_start = 0;
        private const int      MAX_COL_VISIBLE = 3;

        private Button? empty_trash_btn = null;
        private Button? share_btn = null;
        private FlowBox? _disks_page_box = null;
        private Files.CloudView? _cloud_view = null;
        private string[] _temp_archive_dirs = {};
        private HashTable<string, string> _archive_views = new HashTable<string, string>(str_hash, str_equal);
        private Singularity.Widgets.Banner? _archive_banner = null;

        private struct Bookmark {
            public string path;
            public string label;
        }

        public FilesApp(string app_id = "dev.sinty.files") {
            Object(application_id: app_id,
                   flags: ApplicationFlags.HANDLES_COMMAND_LINE | ApplicationFlags.NON_UNIQUE);
        }

        private void update_view_mode() {
            if (view_stack_ref != null) {
                if (view_stack_ref.visible_child_name == "empty") return;

                string mode = settings.get_string("view-mode");
                if (mode == "column") {
                    view_stack_ref.visible_child_name = "column";
                    if (current_folder != null && _col_count == 0) {
                        if (_col_browser != null) _col_browser.clear();
                        _col_folders = {};
                        load_column_pane(0, current_folder);
                    }
                } else {
                    view_stack_ref.visible_child_name = (mode == "grid") ? "grid" : "list";
                }
            }
        }

        private void ensure_empty_page() {
            if (view_stack_ref == null) return;
            if (_empty_holder != null) return;
            _empty_holder = new Box(Orientation.VERTICAL, 0);
            _empty_holder.hexpand = true;
            _empty_holder.vexpand = true;
            _empty_key = "";
            view_stack_ref.add_named(_empty_holder, "empty");
        }

        private void show_empty_state(string kind) {
            if (view_stack_ref == null) return;
            ensure_empty_page();
            bool writable = false;
            bool at_home = false;
            if (kind == "folder" && current_folder != null) {
                at_home = current_folder.get_path() == Environment.get_home_dir();
                try {
                    var info = current_folder.query_info(FileAttribute.ACCESS_CAN_WRITE, FileQueryInfoFlags.NONE, null);
                    writable = info.get_attribute_boolean(FileAttribute.ACCESS_CAN_WRITE);
                } catch (Error e) {
                    writable = false;
                }
            }
            bool can_paste = writable && !picker_mode && clipboard_files.length > 0;
            string key = "%s:%s:%s:%s:%s".printf(kind, writable.to_string(), at_home.to_string(),
                can_paste.to_string(), picker_mode.to_string());
            if (key != _empty_key) {
                Widget? old = _empty_holder.get_first_child();
                if (old != null) _empty_holder.remove(old);
                _empty_holder.append(build_empty_page(kind, writable, at_home, can_paste));
                _empty_key = key;
            }
            view_stack_ref.visible_child_name = "empty";
        }

        private Widget build_empty_page(string kind, bool writable, bool at_home, bool can_paste) {
            if (kind == "search") {
                var none = new Singularity.Widgets.StatusPage();
                none.icon_name = "system-search";
                none.title = _("No Matches");
                none.description = _("Try a different search term.");
                none.hexpand = true;
                none.vexpand = true;
                var clear = new Button.with_label(_("Clear Search"));
                clear.halign = Align.CENTER;
                clear.add_css_class("pill");
                clear.add_css_class("suggested-action");
                clear.clicked.connect(() => {
                    clear_search();
                    if (current_folder != null) navigate_to.begin(current_folder);
                });
                none.child = clear;
                return none;
            }
            var page = new Singularity.Widgets.WelcomePage();
            page.is_section = true;
            page.hexpand = true;
            page.vexpand = true;
            if (kind == "trash") {
                page.app_icon_name = "user-trash-empty";
                page.title = _("Trash Is Empty");
                page.subtitle = _("Deleted files stay here until you empty the Trash");
                page.add_action("user-home", _("Open Home"), _("Go back to your personal folder"), () => go_to_place("home"));
                page.add_action("document-open-recent", _("Recent Files"), _("The files you opened lately"), () => go_to_place("recent"));
            } else if (kind == "recent") {
                page.app_icon_name = "document-open-recent";
                page.title = _("No Recent Files");
                page.subtitle = _("Files you open appear here for quick access");
                if (Environment.get_user_special_dir(UserDirectory.DOCUMENTS) != null) {
                    page.add_action("folder-documents", _("Open Documents"), _("Browse your documents folder"), () => go_to_place("documents"));
                }
                if (Environment.get_user_special_dir(UserDirectory.DOWNLOAD) != null) {
                    page.add_action("folder-download", _("Open Downloads"), _("Find the files you downloaded"), () => go_to_place("downloads"));
                }
                page.add_action("user-home", _("Open Home"), _("Go back to your personal folder"), () => go_to_place("home"));
            } else {
                page.app_icon_name = "folder";
                page.title = _("This Folder Is Empty");
                page.subtitle = writable ? _("Drop files here or add something new") : _("There is nothing in this folder");
                if (writable) {
                    page.add_action_with_caption("folder", _("New Folder"), _("Create a folder inside this one"),
                        accelerator_get_label(Gdk.Key.n, Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK), () => show_new_folder_dialog());
                }
                if (can_paste) {
                    page.add_action_with_caption("edit-paste", _("Paste"),
                        ngettext("Put the copied item here", "Put the %u copied items here", clipboard_files.length).printf(clipboard_files.length),
                        accelerator_get_label(Gdk.Key.v, Gdk.ModifierType.CONTROL_MASK), () => paste_files());
                }
                if (!picker_mode) {
                    page.add_action("dev.sinty.leafs", _("Open Terminal Here"), _("Start a terminal in this folder"), () => launch_terminal());
                }
                if (!at_home) {
                    page.add_action("user-home", _("Go Home"), _("Go back to your personal folder"), () => go_to_place("home"));
                }
            }
            return page;
        }

        private void sync_empty_state() {
            if (view_stack_ref == null) return;
            bool is_empty = file_store == null || file_store.get_n_items() == 0;
            if (is_empty && current_folder != null) {
                string uri = current_folder.get_uri();
                if (uri.has_prefix("trash://")) {
                    show_empty_state("trash");
                } else if (uri.has_prefix("recent://")) {
                    show_empty_state("recent");
                } else if (current_search != "") {
                    show_empty_state("search");
                } else {
                    show_empty_state("folder");
                }
            } else {
                string mode = settings.get_string("view-mode");
                view_stack_ref.visible_child_name =
                    (mode == "column") ? "column"
                    : (mode == "grid") ? "grid"
                    : "list";
            }
        }

        private bool _global_menu_name_requested = false;

        private void ensure_global_menu_name() {
            if (_global_menu_name_requested) return;
            var conn = get_dbus_connection();
            if (conn == null) return;
            _global_menu_name_requested = true;
            Bus.own_name_on_connection(conn, application_id, BusNameOwnerFlags.NONE, null, null);
        }

        private SimpleAction? act_open = null;
        private SimpleAction? act_rename = null;
        private SimpleAction? act_trash = null;
        private SimpleAction? act_empty_trash = null;
        private SimpleAction? act_cut = null;
        private SimpleAction? act_copy = null;
        private SimpleAction? act_paste = null;
        private SimpleAction? act_back = null;
        private SimpleAction? act_forward = null;
        private SimpleAction? act_up = null;
        private SimpleAction? act_share = null;
        private SimpleAction? act_copy_link = null;

        private void setup_menu() {
            var menu = new GLib.Menu();

            var file_menu = new GLib.Menu();
            var f1 = new GLib.Menu();
            f1.append(_("New Window"), "app.new-window");
            f1.append(_("New Folder…"), "app.new-folder");
            file_menu.append_section(null, f1);
            var f2 = new GLib.Menu();
            f2.append(_("Open"), "app.open");
            f2.append(_("Open Terminal Here"), "app.open-terminal");
            file_menu.append_section(null, f2);
            var f3 = new GLib.Menu();
            f3.append(_("Rename"), "app.rename");
            f3.append(_("Move to Trash"), "app.trash");
            f3.append(_("Empty Trash"), "app.empty-trash");
            file_menu.append_section(null, f3);
            var f4 = new GLib.Menu();
            f4.append(_("Share…"), "app.share");
            f4.append(_("Properties"), "app.properties");
            file_menu.append_section(null, f4);
            var f5 = new GLib.Menu();
            f5.append(_("Close Window"), "win.close");
            f5.append(_("Quit"), "app.quit");
            file_menu.append_section(null, f5);
            menu.append_submenu(_("File"), file_menu);

            var edit_menu = new GLib.Menu();
            var e1 = new GLib.Menu();
            e1.append(_("Cut"), "app.cut");
            e1.append(_("Copy"), "app.copy");
            e1.append(_("Paste"), "app.paste");
            edit_menu.append_section(null, e1);
            var e2 = new GLib.Menu();
            e2.append(_("Select All"), "app.select-all");
            e2.append(_("Find"), "app.find");
            edit_menu.append_section(null, e2);
            var e3 = new GLib.Menu();
            e3.append(_("Settings"), "app.settings");
            edit_menu.append_section(null, e3);
            menu.append_submenu(_("Edit"), edit_menu);

            var view_menu = new GLib.Menu();
            var v1 = new GLib.Menu();
            v1.append(_("Grid View"), "app.view-mode('grid')");
            v1.append(_("List View"), "app.view-mode('list')");
            v1.append(_("Column View"), "app.view-mode('column')");
            view_menu.append_section(null, v1);
            var v2 = new GLib.Menu();
            var sort_menu = new GLib.Menu();
            var s1 = new GLib.Menu();
            s1.append(_("Name"), "app.sort-by('name')");
            s1.append(_("Size"), "app.sort-by('size')");
            s1.append(_("Type"), "app.sort-by('type')");
            s1.append(_("Date Modified"), "app.sort-by('date')");
            sort_menu.append_section(null, s1);
            var s2 = new GLib.Menu();
            s2.append(_("Reverse Order"), "app.sort-descending");
            sort_menu.append_section(null, s2);
            v2.append_submenu(_("Sort By"), sort_menu);
            v2.append(_("Show Hidden Files"), "app.show-hidden");
            view_menu.append_section(null, v2);
            var v3 = new GLib.Menu();
            v3.append(_("Zoom In"), "app.zoom-in");
            v3.append(_("Zoom Out"), "app.zoom-out");
            v3.append(_("Actual Size"), "app.zoom-reset");
            view_menu.append_section(null, v3);
            var v4 = new GLib.Menu();
            v4.append(_("Reload"), "app.reload");
            v4.append(_("Show Sidebar"), "win.toggle-sidebar");
            view_menu.append_section(null, v4);
            menu.append_submenu(_("View"), view_menu);

            var go_menu = new GLib.Menu();
            var g1 = new GLib.Menu();
            g1.append(_("Back"), "app.go-back");
            g1.append(_("Forward"), "app.go-forward");
            g1.append(_("Enclosing Folder"), "app.go-up");
            g1.append(_("Enter Location"), "app.location");
            go_menu.append_section(null, g1);
            var g2 = new GLib.Menu();
            g2.append(_("Recent"), "app.go-to('recent')");
            g2.append(_("Home"), "app.go-to('home')");
            g2.append(_("Documents"), "app.go-to('documents')");
            g2.append(_("Downloads"), "app.go-to('downloads')");
            g2.append(_("Pictures"), "app.go-to('pictures')");
            g2.append(_("Music"), "app.go-to('music')");
            g2.append(_("Videos"), "app.go-to('videos')");
            go_menu.append_section(null, g2);
            var g3 = new GLib.Menu();
            g3.append(_("Trash"), "app.go-to('trash')");
            g3.append(_("Network"), "app.go-to('network')");
            go_menu.append_section(null, g3);
            menu.append_submenu(_("Go"), go_menu);

            set_menubar(menu);
            set_accels_for_action("win.toggle-sidebar", { "F9" });
            set_accels_for_action("win.close", { "<Control>w" });
            set_accels_for_action("app.new-window", { "<Control>n" });
            set_accels_for_action("app.new-folder", { "<Control><Shift>n" });
            set_accels_for_action("app.rename", { "F2" });
            set_accels_for_action("app.cut", { "<Control>x" });
            set_accels_for_action("app.copy", { "<Control>c" });
            set_accels_for_action("app.paste", { "<Control>v" });
            set_accels_for_action("app.select-all", { "<Control>a" });
            set_accels_for_action("app.find", { "<Control>f" });
            set_accels_for_action("app.settings", { "<Control>comma" });
            set_accels_for_action("app.show-hidden", { "<Control>h" });
            set_accels_for_action("app.zoom-in", { "<Control>plus", "<Control>equal", "<Control>KP_Add" });
            set_accels_for_action("app.zoom-out", { "<Control>minus", "<Control>KP_Subtract" });
            set_accels_for_action("app.zoom-reset", { "<Control>0", "<Control>KP_0" });
            set_accels_for_action("app.reload", { "F5" });
            set_accels_for_action("app.go-back", { "<Alt>Left" });
            set_accels_for_action("app.go-forward", { "<Alt>Right" });
            set_accels_for_action("app.go-up", { "<Alt>Up" });
            set_accels_for_action("app.location", { "<Control>l", "<Control>p" });
            set_accels_for_action("app.go-to::home", { "<Alt>Home" });

            // Actions
            var act_new_win = new SimpleAction("new-window", null);
            act_new_win.activate.connect(open_new_window);
            add_action(act_new_win);

            var act_new_folder = new SimpleAction("new-folder", null);
            act_new_folder.activate.connect(() => show_new_folder_dialog());
            add_action(act_new_folder);

            act_open = new SimpleAction("open", null);
            act_open.activate.connect(open_selected);
            add_action(act_open);

            var act_term = new SimpleAction("open-terminal", null);
            act_term.activate.connect(launch_terminal);
            add_action(act_term);

            act_rename = new SimpleAction("rename", null);
            act_rename.activate.connect(() => rename_selected());
            add_action(act_rename);

            act_trash = new SimpleAction("trash", null);
            act_trash.activate.connect(trash_selected);
            add_action(act_trash);

            act_empty_trash = new SimpleAction("empty-trash", null);
            act_empty_trash.activate.connect(empty_trash);
            add_action(act_empty_trash);

            act_share = new SimpleAction("share", null);
            act_share.activate.connect(() => share_files(selected_files()));
            add_action(act_share);

            act_copy_link = new SimpleAction("copy-link", null);
            act_copy_link.activate.connect(() => copy_link_files(selected_files()));
            add_action(act_copy_link);

            var act_share_files = new SimpleAction("share-files", new GLib.VariantType("as"));
            act_share_files.activate.connect((param) => {
                File[] files = {};
                foreach (string uri in param.get_strv()) files += File.new_for_uri(uri);
                share_files(files);
            });
            add_action(act_share_files);

            var act_props = new SimpleAction("properties", null);
            act_props.activate.connect(() => show_properties(null));
            add_action(act_props);

            var act_quit = new SimpleAction("quit", null);
            act_quit.activate.connect(() => {
                _cleanup_temp_archive_dirs();
                quit();
            });
            add_action(act_quit);

            act_cut = new SimpleAction("cut", null);
            act_cut.activate.connect(() => {
                if (!editable_clipboard("clipboard.cut")) copy_selected(true);
            });
            add_action(act_cut);

            act_copy = new SimpleAction("copy", null);
            act_copy.activate.connect(() => {
                if (!editable_clipboard("clipboard.copy")) copy_selected(false);
            });
            add_action(act_copy);

            act_paste = new SimpleAction("paste", null);
            act_paste.activate.connect(() => {
                if (!editable_clipboard("clipboard.paste")) paste_files();
            });
            add_action(act_paste);

            var act_select_all = new SimpleAction("select-all", null);
            act_select_all.activate.connect(select_all_files);
            add_action(act_select_all);

            var act_find = new SimpleAction("find", null);
            act_find.activate.connect(open_search);
            add_action(act_find);

            var act_settings = new SimpleAction("settings", null);
            act_settings.activate.connect(() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync(
                        BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings("dev.sinty.files");
                } catch (Error e) {
                    warning("Failed to open settings: %s", e.message);
                }
            });
            add_action(act_settings);

            var act_view = new SimpleAction.stateful("view-mode", GLib.VariantType.STRING,
                new GLib.Variant.string(settings.get_string("view-mode")));
            act_view.activate.connect((param) => {
                settings.set_string("view-mode", param.get_string());
            });
            settings.changed["view-mode"].connect(() => {
                act_view.set_state(new GLib.Variant.string(settings.get_string("view-mode")));
            });
            add_action(act_view);

            var act_sort = new SimpleAction.stateful("sort-by", GLib.VariantType.STRING,
                new GLib.Variant.string(settings.get_string("sort-method")));
            act_sort.activate.connect((param) => {
                settings.set_string("sort-method", param.get_string());
            });
            settings.changed["sort-method"].connect(() => {
                act_sort.set_state(new GLib.Variant.string(settings.get_string("sort-method")));
            });
            add_action(act_sort);

            var act_desc = new SimpleAction.stateful("sort-descending", null,
                new GLib.Variant.boolean(settings.get_string("sort-order") == "descending"));
            act_desc.activate.connect(() => {
                bool desc = settings.get_string("sort-order") == "descending";
                settings.set_string("sort-order", desc ? "ascending" : "descending");
            });
            settings.changed["sort-order"].connect(() => {
                act_desc.set_state(new GLib.Variant.boolean(settings.get_string("sort-order") == "descending"));
            });
            add_action(act_desc);

            var act_hidden = new SimpleAction.stateful("show-hidden", null,
                new GLib.Variant.boolean(settings.get_boolean("show-hidden")));
            act_hidden.activate.connect(() => {
                settings.set_boolean("show-hidden", !settings.get_boolean("show-hidden"));
            });
            settings.changed["show-hidden"].connect(() => {
                act_hidden.set_state(new GLib.Variant.boolean(settings.get_boolean("show-hidden")));
            });
            add_action(act_hidden);

            var act_zoom_in = new SimpleAction("zoom-in", null);
            act_zoom_in.activate.connect(() => settings.set_int("icon-size", int.min(128, settings.get_int("icon-size") + 8)));
            add_action(act_zoom_in);

            var act_zoom_out = new SimpleAction("zoom-out", null);
            act_zoom_out.activate.connect(() => settings.set_int("icon-size", int.max(24, settings.get_int("icon-size") - 8)));
            add_action(act_zoom_out);

            var act_zoom_reset = new SimpleAction("zoom-reset", null);
            act_zoom_reset.activate.connect(() => settings.set_int("icon-size", 48));
            add_action(act_zoom_reset);

            var act_reload = new SimpleAction("reload", null);
            act_reload.activate.connect(() => {
                if (current_folder != null) navigate_to.begin(current_folder);
            });
            add_action(act_reload);

            act_back = new SimpleAction("go-back", null);
            act_back.activate.connect(go_back);
            add_action(act_back);

            act_forward = new SimpleAction("go-forward", null);
            act_forward.activate.connect(go_forward);
            add_action(act_forward);

            act_up = new SimpleAction("go-up", null);
            act_up.activate.connect(go_up);
            add_action(act_up);

            var act_location = new SimpleAction("location", null);
            act_location.activate.connect(open_location_entry);
            add_action(act_location);

            var act_go_to = new SimpleAction("go-to", GLib.VariantType.STRING);
            act_go_to.activate.connect((param) => go_to_place(param.get_string()));
            add_action(act_go_to);

            update_menu_actions();
        }

        private void update_menu_actions() {
            if (act_open == null) return;
            bool in_trash = current_folder != null && current_folder.get_uri().has_prefix("trash://");
            bool has_sel = file_view != null && get_selected_items().length > 0;
            act_open.set_enabled(has_sel && !in_trash);
            act_rename.set_enabled(has_sel && !in_trash);
            act_trash.set_enabled(has_sel && !in_trash);
            act_cut.set_enabled(has_sel && !in_trash);
            act_copy.set_enabled(has_sel && !in_trash);
            act_share.set_enabled(has_sel && !in_trash);
            act_copy_link.set_enabled(has_sel && !in_trash && !selection_has_folder());
            if (share_btn != null) share_btn.visible = has_sel && !in_trash;
            act_paste.set_enabled(clipboard_files.length > 0 && current_folder != null && !in_trash);
            act_empty_trash.set_enabled(in_trash);
            act_back.set_enabled(nav_index > 0);
            act_forward.set_enabled(nav_index < (int)nav_history.length - 1);
            act_up.set_enabled(current_folder != null && current_folder.get_parent() != null);
        }

        private File[] selected_files() {
            File[] files = {};
            if (file_view == null) return files;
            var selected = get_selected_items();
            for (int i = 0; i < selected.length; i++) files += selected.get(i).file;
            return files;
        }

        private bool selection_has_folder() {
            var selected = get_selected_items();
            for (int i = 0; i < selected.length; i++)
                if (selected.get(i).is_folder) return true;
            return false;
        }

        private File[] menu_target_files(FileItem item) {
            var selected = get_selected_items();
            for (int i = 0; i < selected.length; i++) {
                if (selected.get(i).file.equal(item.file)) return selected_files();
            }
            return { item.file };
        }

        private bool menu_targets_folder(FileItem item) {
            var selected = get_selected_items();
            bool in_selection = false;
            for (int i = 0; i < selected.length; i++)
                if (selected.get(i).file.equal(item.file)) in_selection = true;
            return in_selection ? selection_has_folder() : item.is_folder;
        }

        private void share_files(File[] files) {
            if (files.length == 0) return;
            Gtk.Window? parent = active_window != null && active_window.get_mapped() ? active_window : null;
            Singularity.Share.present(parent, new Singularity.ShareContent.for_files(files), this);
        }

        private void copy_link_files(File[] files) {
            if (files.length == 0 || active_window == null) return;
            Singularity.Share.copy_link(active_window, files);
        }

        private void open_new_window() {
            try {
                string? path = current_folder?.get_path();
                if (path != null) {
                    Process.spawn_command_line_async("singularity-files " + GLib.Shell.quote(path));
                } else {
                    Process.spawn_command_line_async("singularity-files");
                }
            } catch (Error e) { warning("new window: %s", e.message); }
        }

        private void open_selected() {
            var selected = get_selected_items();
            for (int i = 0; i < selected.length; i++) {
                var item = selected.get(i);
                if (item.is_folder) {
                    navigate_user(item.file);
                    return;
                }
                launch_file(item.file);
            }
        }

        private bool rename_selected() {
            var col_fi = _column_selected_item();
            if (col_fi != null) {
                start_inline_rename(col_fi);
                return true;
            }
            var selected = get_selected_items();
            if (selected.length > 0) {
                start_inline_rename(selected.get(0));
                return true;
            }
            return false;
        }

        private void trash_selected() {
            var selected = get_selected_items();
            if (selected.length == 0) return;
            GLib.File[] picked = {};
            for (int i = 0; i < selected.length; i++) picked += selected.get(i).file;
            if (Files.CloudMountActions.covers(picked)) {
                Files.CloudMountActions.confirm_delete(active_window, picked, () => {
                    if (current_folder != null) navigate_to.begin(current_folder);
                });
                return;
            }
            ensure_ops_manager();
            var files = new GLib.File[selected.length];
            for (int i = 0; i < selected.length; i++)
                files[i] = selected.get(i).file;
            var op = _ops.start_trash(files);
            op.completed.connect(() => {
                if (current_folder != null) navigate_to.begin(current_folder);
            });
        }

        private void empty_trash() {
            try {
                var trash = File.new_for_uri("trash://");
                var e = trash.enumerate_children("standard::*", FileQueryInfoFlags.NONE, null);
                FileInfo? fi;
                while ((fi = e.next_file(null)) != null) {
                    var child = trash.get_child(fi.get_name());
                    child.delete(null);
                }
                navigate_to.begin(File.new_for_uri("trash://"));
            } catch (Error e) {
                warning("Empty trash failed: %s", e.message);
            }
        }

        private void copy_selected(bool cut) {
            var selected = get_selected_items();
            if (selected.length == 0) return;
            bool was_cut = clipboard_is_cut;
            set_clipboard(selected, cut);
            if ((cut || was_cut) && current_folder != null) navigate_to.begin(current_folder);
        }

        private bool editable_clipboard(string action) {
            var win = get_active_window();
            var focus = win != null ? win.get_focus() : null;
            if (!(focus is Editable)) return false;
            if (action == "select-all") ((Editable) focus).select_region(0, -1);
            else focus.activate_action(action, null);
            return true;
        }

        private void select_all_files() {
            if (editable_clipboard("select-all")) return;
            var sel = file_view.model as SelectionModel;
            if (sel != null) sel.select_all();
        }

        private void open_search() {
            if (path_bar_stack == null || picker_mode) return;
            if (path_bar_stack.visible_child_name != "search") {
                current_search = "";
                search_entry_widget.text = "";
                path_bar_stack.visible_child_name = "search";
            }
            search_entry_widget.grab_focus();
        }

        private void open_location_entry() {
            if (path_bar_stack == null || path_bar_stack.visible_child_name == "entry") return;
            if (current_folder != null) {
                path_entry_widget.text = current_folder.get_path() ?? "";
            }
            path_bar_stack.visible_child_name = "entry";
            path_entry_widget.grab_focus();
            path_entry_widget.set_position(-1);
        }

        private void go_to_place(string place) {
            string? path = null;
            switch (place) {
                case "recent": path = "recent://"; break;
                case "home": path = Environment.get_home_dir(); break;
                case "documents": path = Environment.get_user_special_dir(UserDirectory.DOCUMENTS); break;
                case "downloads": path = Environment.get_user_special_dir(UserDirectory.DOWNLOAD); break;
                case "pictures": path = Environment.get_user_special_dir(UserDirectory.PICTURES); break;
                case "music": path = Environment.get_user_special_dir(UserDirectory.MUSIC); break;
                case "videos": path = Environment.get_user_special_dir(UserDirectory.VIDEOS); break;
                case "trash": path = "trash://"; break;
                case "network": path = "smb://"; break;
            }
            if (path == null) return;
            if (path.contains("://")) {
                clear_search();
                navigate_to_uri(path);
            } else {
                navigate_user(File.new_for_path(path));
            }
        }

        public override int command_line(ApplicationCommandLine command_line) {
            var args = command_line.get_arguments();
            _startup_folder = null;
            for (int i = 0; i < args.length; i++) {
                if (args[i] == "--picker") picker_mode = true;
                else if (args[i] == "--portal-mode") { portal_mode = true; picker_mode = true; }
                else if (args[i] == "--save") save_mode = true;
                else if (args[i] == "--directory") directory_mode = true;
                else if (args[i] == "--multiple") multiple_mode = true;
                else if (args[i].has_prefix("--title=")) picker_title = args[i].substring(8);
                else if (args[i].has_prefix("--current-name=")) picker_current_name = args[i].substring(15);
                else if (args[i].has_prefix("--current-folder=")) {
                    var folder = File.new_for_commandline_arg(args[i].substring(17));
                    if (folder.query_exists(null)) _startup_folder = folder;
                }
                else if (args[i].has_prefix("--accept-label=")) picker_accept_label = args[i].substring(15);
                else if (i > 0 && !args[i].has_prefix("--")) {
                    // Positional argument: a folder to open. Accept a path or
                    // a file:// URI; relative paths resolve against the CWD
                    // the command line was invoked from.
                    var f = args[i].has_prefix("file://")
                        ? GLib.File.new_for_uri(args[i])
                        : GLib.File.new_for_commandline_arg_and_cwd(
                              args[i], command_line.get_cwd());
                    if (!f.query_exists(null)) continue;
                    if (f.query_file_type(FileQueryInfoFlags.NONE, null) == FileType.DIRECTORY) {
                        _startup_folder = f;
                    } else {
                        _startup_folder = f.get_parent();
                        _startup_archive = is_archive_location(f) ? f : null;
                    }
                }
            }
            activate();
            return 0;
        }

        // Folder to open on launch, set from a positional command-line arg.
        private GLib.File? _startup_folder = null;
        private GLib.File? _startup_archive = null;

        private static bool is_archive_location(GLib.File f) {
            try {
                var info = f.query_info(FileAttribute.STANDARD_CONTENT_TYPE, FileQueryInfoFlags.NONE);
                if (Files.Archives.ArchiveFormats.is_archive_type(info.get_content_type())) return true;
            } catch (Error e) {
            }
            return Files.Archives.ArchiveFormats.is_archive_name(f.get_basename());
        }

        private void open_startup_archive() {
            var f = _startup_archive;
            _startup_archive = null;
            if (f == null) return;
            try {
                var info = f.query_info("standard::*,time::modified", FileQueryInfoFlags.NONE);
                open_archive_as_folder(new FileItem(f, info));
            } catch (Error e) {
                show_archive_error(f.get_basename(), e.message);
            }
        }

        private const string FILES_CSS = """
.files-ops-banner {
    background-color: alpha(@text_color, 0.06);
    border-radius: 10px;
    padding: 6px 10px;
    box-shadow: 0 -1px 4px alpha(black, 0.08);
}
.files-ops-progress {
    min-height: 10px;
    min-width: 120px;
}
.files-ops-progress > trough {
    min-height: 10px;
    border-radius: 999px;
    background-color: alpha(@text_color, 0.15);
}
.files-ops-progress > trough > progress {
    min-height: 10px;
    border-radius: 999px;
    background-color: @accent_bg_color;
    background-image: none;
}

.files-conflict-card {
    padding: 12px;
    border-radius: 14px;
    background-color: alpha(@window_fg_color, 0.05);
}

.files-conflict-preview {
    border-radius: 10px;
    background-color: alpha(@window_fg_color, 0.04);
}

.files-conflict-badge {
    padding: 1px 8px;
    border-radius: 999px;
    font-size: 11px;
    font-weight: bold;
    background-color: alpha(@accent_bg_color, 0.18);
    color: @accent_color;
}

.files-cloud-line > .singularity-sidebar-row {
    padding-right: 4px;
}

.files-cloud-eject {
    padding: 4px;
    min-width: 24px;
    min-height: 24px;
    border-radius: 8px;
}

.files-template-card {
    border-radius: 12px;
    padding: 0;
}
.files-template-body {
    border-radius: 12px;
    padding: 12px 4px 10px 4px;
}
.files-template-card:checked > .files-template-body {
    background-color: alpha(@accent_color, 0.14);
    box-shadow: inset 0 0 0 2px @accent_color;
}
.files-template-card:checked label {
    color: @text_color;
}
""";

        private void load_files_css() {
            var provider = new Gtk.CssProvider();
            provider.load_from_data(FILES_CSS.data);
            var display = Gdk.Display.get_default();
            if (display != null)
                Gtk.StyleContext.add_provider_for_display(
                    display, provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        protected override void shutdown() {
            _cleanup_temp_archive_dirs();
            base.shutdown();
        }

        protected override void startup() {
            base.startup();

            load_files_css();
            Files.Archives.ArchivePaths.remove_tree(archive_cache_root());

            var source = SettingsSchemaSource.get_default();
            if (source.lookup("dev.sinty.files", true) == null) {
                try {
                    string exe_path = FileUtils.read_link("/proc/self/exe");
                    var exe_dir = File.new_for_path(exe_path).get_parent();
                    var schema_file = exe_dir.get_child("data").get_child("gschemas.compiled");
                    if (schema_file.query_exists()) {
                        var compiled_source = new SettingsSchemaSource.from_directory(schema_file.get_parent().get_path(), source, true);
                        var schema = compiled_source.lookup("dev.sinty.files", true);
                        if (schema != null) {
                            settings = new GLib.Settings.full(schema, null, null);
                            message("Loaded development schemas from %s", schema_file.get_path());
                        }
                    }
                } catch (Error e) {
                    warning("Failed to load development schemas: %s", e.message);
                }
            }
            if (settings == null) {
                settings = new GLib.Settings("dev.sinty.files");
            }
            // The menu builds actions whose initial state is read from the
            // settings, so it cannot be assembled before they exist.
            setup_menu();
            grid_icon_size = settings.get_int("icon-size");
            settings.changed.connect((key) => {
                if (key == "show-hidden") {
                    if (current_folder != null) navigate_to.begin(current_folder);
                } else if (key == "view-mode") {
                    update_view_mode();
                } else if (key == "sort-method" || key == "sort-order") {
                    sort_files();
                } else if (key == "show-previews") {
                    if (current_folder != null) navigate_to.begin(current_folder);
                } else if (key == "icon-size") {
                    grid_icon_size = settings.get_int("icon-size");
                    // Walk visible grid cells and update pixel_size directly (realtime)
                    apply_grid_icon_size();
                }
            });
        }

        protected override void activate() {
            if (!picker_mode && !portal_mode) ensure_global_menu_name();
            string title = "Files";
            if (picker_mode) {
                title = save_mode ? "Save File" : directory_mode ? "Select Folder" : "Select File";
            }
            if (picker_title != null) {
                title = picker_title;
            }

            FilesWindow? files_win = null;
            Singularity.Widgets.Window window;
            Gtk.Builder? builder = null;

            if (!picker_mode) {
                files_win = new FilesWindow(this);
                window = files_win;
            } else {
                window = new Singularity.Widgets.Window(this);
                builder = new Gtk.Builder.from_resource("/dev/sinty/files/ui/picker.ui");
            }

            active_window = window;
            window.close_request.connect(() => {
                navigation_generation++;
                if (folder_refresh_id != 0) {
                    Source.remove(folder_refresh_id);
                    folder_refresh_id = 0;
                }
                if (folder_monitor != null) {
                    folder_monitor.cancel();
                    folder_monitor = null;
                }
                return false;
            });
            window.set_title(title);
            window.set_default_size(950, 650);
            var act_close = new SimpleAction("close", null);
            act_close.activate.connect(() => window.close());
            window.add_action(act_close);

            // Empty handler: the real one is wired later with settings persistence.
            var sidebar_btn = window.add_bubble_icon("sidebar-show-symbolic", _("Toggle Sidebar (F9)"), () => {});
            sidebar_btn.visible = !picker_mode;
            // Back/Forward navigation buttons (non-picker only)
            if (!picker_mode) {
                back_btn = window.add_bubble_icon("go-previous-symbolic", _("Back"), () => go_back());
                back_btn.visible = false;
                fwd_btn = window.add_bubble_icon("go-next-symbolic", _("Forward"), () => go_forward());
                fwd_btn.visible = false;
            }
            if (picker_mode) {
                var cancel_btn = new Button.with_label(_("Cancel"));
                cancel_btn.clicked.connect(() => {
                    window.close();
                    if (portal_mode) quit();
                });
                window.add_bubble_widget(cancel_btn);
            }
            // Path bar wrapped in a Stack so we can swap it with an Entry (press "/")
            path_bar = new Box(Orientation.HORIZONTAL, 4);
            path_bar_stack = new Stack();
            path_bar_stack.hhomogeneous = false;
            path_bar_stack.vhomogeneous = false;
            path_bar_stack.transition_type = StackTransitionType.NONE;
            path_bar_stack.add_named(path_bar, "bar");
            path_entry_widget = new Entry();
            path_entry_widget.width_chars = 40;
            path_entry_widget.hexpand = true;
            path_bar_stack.add_named(path_entry_widget, "entry");
            path_bar_stack.visible_child_name = "bar";
            // Search entry
            search_entry_widget = new Entry();
            search_entry_widget.placeholder_text = _("Search…");
            search_entry_widget.width_chars = 30;
            search_entry_widget.hexpand = true;
            search_entry_widget.set_icon_from_icon_name(EntryIconPosition.PRIMARY, "system-search-symbolic");
            path_bar_stack.add_named(search_entry_widget, "search");
            var search_entry_key = new EventControllerKey();
            search_entry_key.set_propagation_phase(PropagationPhase.CAPTURE);
            search_entry_key.key_pressed.connect((kv, kc, mstate) => {
                if (kv == Gdk.Key.Return || kv == Gdk.Key.KP_Enter) {
                    // Open the selected item if any
                    var sel = file_view.model as SelectionModel;
                    if (sel != null) {
                        for (uint i = 0; i < file_store.get_n_items(); i++) {
                            if (sel.is_selected(i)) {
                                var item = (FileItem) file_store.get_item(i);
                                if (item.is_folder) {
                                    navigate_user(item.file);
                                } else {
                                    clear_search();
                                    launch_file(item.file);
                                }
                                return true;
                            }
                        }
                    }
                    clear_search();
                    return true;
                }
                if (kv == Gdk.Key.Escape) {
                    clear_search();
                    if (current_folder != null) navigate_to.begin(current_folder);
                    return true;
                }
                if (kv == Gdk.Key.Down || kv == Gdk.Key.Up) {
                    var sel = file_view.model as SelectionModel;
                    uint n = file_store.get_n_items();
                    if (sel != null && n > 0) {
                        uint current = n - 1;
                        for (uint i = 0; i < n; i++) {
                            if (sel.is_selected(i)) { current = i; break; }
                        }
                        uint next;
                        if (kv == Gdk.Key.Down)
                            next = (current + 1) % n;
                        else
                            next = current > 0 ? current - 1 : n - 1;
                        sel.select_item(next, true);
                    }
                    return true;
                }
                return false;
            });
            search_entry_widget.add_controller(search_entry_key);
            search_entry_widget.changed.connect(() => {
                current_search = search_entry_widget.text;
                if (current_folder != null) navigate_to.begin(current_folder);
            });
            // Fixed-width Box so the path bar clips on overflow.
            var path_bubble = new Box(Orientation.HORIZONTAL, 0);
            path_bubble.add_css_class("files-path-bubble");
            path_bubble.hexpand = false;
            path_bubble.overflow = Gtk.Overflow.HIDDEN;
            path_bubble.append(path_bar_stack);
            window.add_bubble_widget(path_bubble);

            path_bar_stack.notify["visible-child-name"].connect(() => {
                bool input_active = path_bar_stack.visible_child_name != "bar";
                if (nav_box_ref != null) nav_box_ref.visible = !input_active;
                if (toolbar_term_btn != null) toolbar_term_btn.visible = !input_active;
                if (toolbar_search_btn != null) toolbar_search_btn.visible = !input_active;
            });

            var entry_key_ctrl = new EventControllerKey();
            entry_key_ctrl.key_pressed.connect((kv, kc, mstate) => {
                if (kv == Gdk.Key.Return || kv == Gdk.Key.KP_Enter) {
                    string text = path_entry_widget.text.strip();
                    if (text.has_prefix("~/")) {
                        text = Environment.get_home_dir() + text.substring(1);
                    } else if (text == "~") {
                        text = Environment.get_home_dir();
                    }
                    if (path_completion_popover != null) path_completion_popover.popdown();
                    var target_file = File.new_for_path(text);
                    if (target_file.query_exists(null)) {
                        navigate_user(target_file);
                    }
                    path_bar_stack.visible_child_name = "bar";
                    return true;
                }
                if (kv == Gdk.Key.Escape) {
                    if (path_completion_popover != null) path_completion_popover.popdown();
                    path_bar_stack.visible_child_name = "bar";
                    return true;
                }
                return false;
            });
            path_entry_widget.add_controller(entry_key_ctrl);
            // Path completion popover: anchor to path_bar_stack (stable position)
            path_completion_popover = new Popover();
            path_completion_popover.set_parent(path_bar_stack);
            path_completion_popover.has_arrow = false;
            path_completion_popover.position = Gtk.PositionType.BOTTOM;
            path_completion_popover.halign = Gtk.Align.FILL;
            path_completion_popover.width_request = 380;
            var comp_scroll = new ScrolledWindow();
            comp_scroll.hscrollbar_policy = PolicyType.NEVER;
            comp_scroll.max_content_height = 200;
            comp_scroll.propagate_natural_height = true;
            path_completion_list = new ListBox();
            path_completion_list.selection_mode = SelectionMode.SINGLE;
            comp_scroll.set_child(path_completion_list);
            path_completion_popover.set_child(comp_scroll);
            path_completion_list.row_activated.connect((row) => {
                string? completion = row.get_data<string>("path-completion");
                if (completion != null) {
                    path_entry_widget.text = completion + "/";
                    path_entry_widget.set_position(-1);
                    update_path_completions();
                }
            });
            path_entry_widget.changed.connect(update_path_completions);

            if (picker_mode) {
                Button select_btn;
                if (picker_accept_label != null) {
                    select_btn = new Button.with_mnemonic(picker_accept_label);
                } else {
                    select_btn = new Button.with_label(save_mode ? _("Save") : directory_mode ? _("Select") : _("Open"));
                }
                select_btn.add_css_class("suggested-action");
                select_btn.clicked.connect(() => submit_picker_selection());
                window.add_bubble_widget(select_btn);
            } else {
                var search_btn = new Button.from_icon_name("system-search-symbolic");
                search_btn.add_css_class("flat");
                search_btn.tooltip_text = _("Search");
                search_btn.clicked.connect(() => {
                    if (path_bar_stack.visible_child_name != "search") {
                        current_search = "";
                        search_entry_widget.text = "";
                        path_bar_stack.visible_child_name = "search";
                        search_entry_widget.grab_focus();
                    } else {
                        current_search = "";
                        path_bar_stack.visible_child_name = "bar";
                        if (current_folder != null) navigate_to.begin(current_folder);
                    }
                });
                window.add_bubble_widget(search_btn);
                toolbar_search_btn = search_btn;
            }

            if (!picker_mode) {
                var content_scroll = files_win.content_scroll;
                var sidebar = files_win.sidebar_scroll;
                files_win.files_ui_root.remove(content_scroll);
                files_win.files_ui_root.remove(sidebar);
                setup_file_view(content_scroll);
                swipe_nav = new Singularity.Widgets.SwipeNavigation(build_content_with_ops_banner(content_scroll));
                swipe_nav.back.connect(go_back);
                swipe_nav.forward.connect(go_forward);
                window.set_content(swipe_nav);
                var places_box = files_win.places_box;
                add_place_button(places_box, "Recent", "recent://", "document-open-recent-symbolic");
                places_box.append(new Separator(Orientation.HORIZONTAL));
                add_place_button(places_box, "Home", Environment.get_home_dir(), "user-home-symbolic");
                add_place_button(places_box, "Documents", Environment.get_user_special_dir(UserDirectory.DOCUMENTS), "folder-documents-symbolic");
                add_place_button(places_box, "Downloads", Environment.get_user_special_dir(UserDirectory.DOWNLOAD), "folder-download-symbolic");
                add_place_button(places_box, "Pictures", Environment.get_user_special_dir(UserDirectory.PICTURES), "folder-pictures-symbolic");
                add_place_button(places_box, "Music", Environment.get_user_special_dir(UserDirectory.MUSIC), "folder-music-symbolic");
                add_place_button(places_box, "Videos", Environment.get_user_special_dir(UserDirectory.VIDEOS), "folder-videos-symbolic");
                places_box.append(new Separator(Orientation.HORIZONTAL));
                add_place_button(places_box, "Trash", "trash://", "user-trash-symbolic");
                _watch_trash_state();
                add_place_button(places_box, "Network", "smb://", "network-workgroup-symbolic");

                // ush integration: browse the Linux sandbox home (ush) like a disk.
                string? ush_home = ush_linux_home();
                if (ush_home != null) {
                    places_box.append(new Separator(Orientation.HORIZONTAL));
                    add_place_button(places_box, "Linux files", ush_home, "ush-penguin-symbolic");
                }
                // dsh integration (same as above but for the development environment)
                string? dev_home = ush_dev_home();
                if (dev_home != null) {
                    add_place_button(places_box, "Developer files", dev_home, "applications-engineering-symbolic");
                }

                // Dynamic bookmarks section
                _places_box = places_box;
                _bookmarks_section = new Box(Orientation.VERTICAL, 2);
                places_box.append(_bookmarks_section);
                rebuild_bookmarks_section();

                // Dynamic disks section (replaces hard-coded Root + Devices)
                _devices_section = new Box(Orientation.VERTICAL, 2);
                places_box.append(_devices_section);
                rebuild_devices_section();

                _cloud_view = new Files.CloudView(window, view_stack_ref, path_bar, settings);
                _cloud_view.open_file.connect(launch_file);
                _cloud_view.locations.mount_activated.connect((path) => {
                    clear_search();
                    navigate_user(File.new_for_path(path));
                });
                Singularity.Accounts.CloudMounts.get_default().changed.connect(() => rebuild_bookmarks_section());
                _cloud_view.activated.connect(() => {
                    clear_search();
                    current_folder = null;
                    ((SelectionModel) file_view.model).unselect_all();
                    update_menu_actions();
                    if (empty_trash_btn != null) empty_trash_btn.visible = false;
                    if (_file_count_lbl != null) _file_count_lbl.label = "";
                    mark_disks_sidebar_active();
                    if (_disks_sidebar_btn != null) _disks_sidebar_btn.remove_css_class("sidebar-nav-active");
                });
                places_box.append(_cloud_view.sidebar_section);

                // Watch bookmarks file for changes
                setup_bookmarks_file_monitor();

                // Watch VolumeMonitor for mount changes
                _volume_monitor = GLib.VolumeMonitor.get();
                _volume_monitor.mount_added.connect((m) => { rebuild_devices_section(); });
                _volume_monitor.mount_removed.connect((m) => { rebuild_devices_section(); });
                _volume_monitor.volume_added.connect((v) => { rebuild_devices_section(); });
                _volume_monitor.volume_removed.connect((v) => { rebuild_devices_section(); });

                // Drag-to-bookmark: drop a folder URI onto the sidebar
                var drop = new Gtk.DropTarget(GLib.Type.INVALID, Gdk.DragAction.COPY);
                drop.set_gtypes({ typeof(string) });
                drop.drop.connect((target, value, x, y) => {
                    string uri = value.get_string();
                    if (uri == null) return false;
                    uri = uri.strip().split("\n")[0].strip();
                    if (!uri.has_prefix("file://")) return false;
                    try {
                        string path = GLib.Filename.from_uri(uri);
                        if (!GLib.FileUtils.test(path, GLib.FileTest.IS_DIR)) return false;
                        add_bookmark(path);
                        return true;
                    } catch { return false; }
                });
                places_box.add_controller(drop);

                // Connect to Server is now accessible via Network page - removed from sidebar
                window.set_sidebar(sidebar);
                bool show_sidebar = settings.get_boolean("show-sidebar");
                window.set_sidebar_visible(show_sidebar);
                var act_sidebar = new SimpleAction("toggle-sidebar", null);
                act_sidebar.activate.connect(() => {
                    bool new_state = !window.get_sidebar_visible();
                    window.set_sidebar_visible(new_state);
                    settings.set_boolean("show-sidebar", new_state);
                });
                window.add_action(act_sidebar);
                sidebar_btn.action_name = "win.toggle-sidebar";

                // Store stack ref
                var stack_in_content = content_scroll.get_child() as Stack;
                if (stack_in_content != null) view_stack_ref = stack_in_content;
            } else {
                // Picker mode: content + compact bookmarks sidebar
                var ui_root = builder.get_object("files_picker_ui_root") as Box;
                var content_scroll = builder.get_object("content_scroll") as ScrolledWindow;
                var picker_sidebar = builder.get_object("picker_sidebar") as ScrolledWindow;
                ui_root.remove(content_scroll);
                ui_root.remove(picker_sidebar);
                setup_file_view(content_scroll);
                window.set_content(content_scroll);
                var stack_in_content = content_scroll.get_child() as Stack;
                if (stack_in_content != null) view_stack_ref = stack_in_content;

                var picker_places = builder.get_object("picker_places") as Box;
                add_place_button(picker_places, "Home", Environment.get_home_dir(), "user-home-symbolic");
                add_place_button(picker_places, "Documents", Environment.get_user_special_dir(UserDirectory.DOCUMENTS), "folder-documents-symbolic");
                add_place_button(picker_places, "Downloads", Environment.get_user_special_dir(UserDirectory.DOWNLOAD), "folder-download-symbolic");
                add_place_button(picker_places, "Pictures", Environment.get_user_special_dir(UserDirectory.PICTURES), "folder-pictures-symbolic");
                add_place_button(picker_places, "Music", Environment.get_user_special_dir(UserDirectory.MUSIC), "folder-music-symbolic");
                add_place_button(picker_places, "Videos", Environment.get_user_special_dir(UserDirectory.VIDEOS), "folder-videos-symbolic");
                // Dynamic bookmarks in picker - NO static separator here,
                // rebuild_bookmarks_section() adds its own only when there are entries
                _places_box = picker_places;
                _bookmarks_section = new Box(Orientation.VERTICAL, 2);
                picker_places.append(_bookmarks_section);
                rebuild_bookmarks_section();
                setup_bookmarks_file_monitor();
                _picker_devices_section = new Box(Orientation.VERTICAL, 2);
                picker_places.append(_picker_devices_section);
                rebuild_picker_devices_section();
                _volume_monitor = GLib.VolumeMonitor.get();
                _volume_monitor.mount_added.connect((m) => { rebuild_picker_devices_section(); });
                _volume_monitor.mount_removed.connect((m) => { rebuild_picker_devices_section(); });
                _volume_monitor.volume_added.connect((v) => { rebuild_picker_devices_section(); });
                _volume_monitor.volume_removed.connect((v) => { rebuild_picker_devices_section(); });
                window.set_sidebar(picker_sidebar);
                window.set_sidebar_visible(true);
            }

            // View cycle button in toolbar (single button, cycles list->grid->column)
            if (view_stack_ref != null) {
                string mode = settings.get_string("view-mode");
                view_stack_ref.visible_child_name = mode;

                var view_btn = new Button();
                view_btn.has_frame = false;
                view_btn.add_css_class("toolbar-button");
                view_btn.tooltip_text = _("Toggle View (Ctrl+Shift+V)");
                // Icon reflects CURRENT mode
                view_btn.icon_name = (mode == "grid") ? "view-grid-symbolic"
                    : (mode == "column") ? "view-paged-symbolic" : "view-list-symbolic";
                view_btn.clicked.connect(() => {
                    string cur = settings.get_string("view-mode");
                    string next = (cur == "list") ? "grid" : (cur == "grid") ? "column" : "list";
                    settings.set_string("view-mode", next);
                });
                settings.changed["view-mode"].connect(() => {
                    string m = settings.get_string("view-mode");
                    view_btn.icon_name = (m == "grid") ? "view-grid-symbolic"
                        : (m == "column") ? "view-paged-symbolic" : "view-list-symbolic";
                });
                window.add_bubble_widget(view_btn);

                var zoom_out_btn = new Button.from_icon_name("zoom-out-symbolic");
                zoom_out_btn.has_frame = false;
                zoom_out_btn.add_css_class("toolbar-button");
                zoom_out_btn.tooltip_text = _("Smaller Icons (Ctrl+Minus)");
                zoom_out_btn.clicked.connect(() => {
                    settings.set_int("icon-size", int.max(24, settings.get_int("icon-size") - 8));
                });
                window.add_bubble_widget(zoom_out_btn);

                var zoom_in_btn = new Button.from_icon_name("zoom-in-symbolic");
                zoom_in_btn.has_frame = false;
                zoom_in_btn.add_css_class("toolbar-button");
                zoom_in_btn.tooltip_text = _("Bigger Icons (Ctrl+Plus)");
                zoom_in_btn.clicked.connect(() => {
                    settings.set_int("icon-size", int.min(128, settings.get_int("icon-size") + 8));
                });
                window.add_bubble_widget(zoom_in_btn);

                bool zoom_visible = settings.get_string("view-mode") == "grid";
                zoom_out_btn.visible = zoom_visible;
                zoom_in_btn.visible = zoom_visible;
                settings.changed["view-mode"].connect(() => {
                    bool g = settings.get_string("view-mode") == "grid";
                    zoom_out_btn.visible = g;
                    zoom_in_btn.visible = g;
                });

                var sb = new Button.from_icon_name("singularity-share-symbolic");
                sb.has_frame = false;
                sb.add_css_class("toolbar-button");
                sb.tooltip_text = _("Share");
                sb.action_name = "app.share";
                sb.visible = false;
                window.add_bubble_widget(sb);
                share_btn = sb;

                // Empty Trash button - shown only when in trash://
                var etb = new Button.from_icon_name("user-trash-full-symbolic");
                etb.has_frame = false;
                etb.add_css_class("toolbar-button");
                etb.tooltip_text = _("Empty Trash");
                etb.visible = false;
                etb.clicked.connect(empty_trash);
                window.add_bubble_widget(etb);
                empty_trash_btn = etb;

                view_stack_ref.notify["visible-child-name"].connect(() => {
                    string child = view_stack_ref.visible_child_name;
                    if (child == "list" || child == "grid" || child == "column") {
                        settings.set_string("view-mode", child);
                        if (child == "column" && current_folder != null) {
                            // Reset column browser completely on each switch-in
                            if (_col_browser != null) _col_browser.clear();
                            _col_folders = {};
                            _col_count = 0;
                            load_column_pane(0, current_folder);
                        }
                    }
                });
            }

            var win_key = new EventControllerKey();
            win_key.set_propagation_phase(PropagationPhase.CAPTURE);
            win_key.key_pressed.connect(on_key_pressed);
            ((Gtk.Widget)window).add_controller(win_key);

            GLib.File start_folder;
            if (_startup_folder != null) {
                // Explicit folder passed on the command line wins.
                start_folder = _startup_folder;
            } else {
                string last_folder_uri = settings.get_string("last-folder");
                if (last_folder_uri != "" && GLib.File.new_for_uri(last_folder_uri).query_exists(null)) {
                    start_folder = GLib.File.new_for_uri(last_folder_uri);
                } else {
                    start_folder = File.new_for_path(Environment.get_home_dir());
                }
            }
            navigate_user(start_folder);
            if (!picker_mode) open_startup_archive();

            // Filename entry at bottom for save mode
            if (picker_mode && save_mode) {
                var filename_box = new Box(Orientation.HORIZONTAL, 8);
                filename_box.margin_start = 12;
                filename_box.margin_end = 12;
                filename_box.margin_top = 4;
                filename_box.margin_bottom = 8;
                var fn_label = new Label(_("Name:"));
                fn_label.xalign = 0;
                filename_entry = new Entry();
                filename_entry.hexpand = true;
                filename_entry.placeholder_text = _("Enter file name");
                if (picker_current_name != null) filename_entry.text = picker_current_name;
                filename_entry.activate.connect(() => submit_picker_selection());
                filename_box.append(fn_label);
                filename_box.append(filename_entry);
                window.content_area.append(filename_box);
            }

            if (picker_mode) {
                var esc_ctrl = new EventControllerKey();
                esc_ctrl.propagation_phase = Gtk.PropagationPhase.CAPTURE;
                esc_ctrl.key_pressed.connect((kv, kc, mstate) => {
                    if (kv == Gdk.Key.Escape) {
                        if (path_bar_stack != null &&
                            path_bar_stack.visible_child_name == "search") {
                            clear_search();
                            if (current_folder != null) navigate_to.begin(current_folder);
                            return true;
                        }
                        window.close();
                        if (portal_mode) quit();
                        return true;
                    }
                    return false;
                });
                ((Gtk.Widget)window).add_controller(esc_ctrl);
            }

            window.present();
            if (picker_mode && save_mode && filename_entry != null) {
                filename_entry.grab_focus();
            }
        }

        private void setup_file_view(ScrolledWindow container) {
            file_store = new GLib.ListStore(typeof(FileItem));
            // Keep the bottom-corner count label in sync with the folder's item count.
            file_store.items_changed.connect((pos, removed, added) => {
                _update_file_count_label();
            });
            // Always use MultiSelection so Ctrl+Click, Shift+Click and Ctrl+A work.
            // Picker mode (single-file) still works: the submit button reads whatever's selected.
            SelectionModel selection = new MultiSelection(file_store);
            selection.selection_changed.connect(() => update_menu_actions());
            var stack = new Stack();
            stack.transition_type = StackTransitionType.CROSSFADE;
            var list_widget = new Singularity.Widgets.DataListView();
            file_view = list_widget.column_view;
            list_widget.set_selection_model(selection);
            file_view.add_css_class("file-view");
            var factory_name = new SignalListItemFactory();
            factory_name.setup.connect((item) => {
                var list_item = (ListItem)item;
                var box = new Box(Orientation.HORIZONTAL, 12);
                var img = new Image();
                img.pixel_size = 24;
                var label = new Label("");
                box.append(img);
                box.append(label);
                box.set_data<Image>("thumb-img", img);
                // Drag and drop source for list view
                var drag_src = new DragSource();
                drag_src.actions = Gdk.DragAction.COPY | Gdk.DragAction.MOVE;
                drag_src.prepare.connect((x, y) => {
                    var fi = box.get_data<FileItem>("file-item");
                    if (fi == null) return null;
                    var uri = fi.file.get_uri();
                    var file_list = new Gdk.FileList.from_array({ fi.file });
                    var files_prov = new Gdk.ContentProvider.for_value(file_list);
                    var uri_prov   = new Gdk.ContentProvider.for_bytes("text/uri-list", new GLib.Bytes((uri + "\r\n").data));
                    var plain_prov = new Gdk.ContentProvider.for_bytes("text/plain",    new GLib.Bytes(uri.data));
                    return new Gdk.ContentProvider.union({ files_prov, uri_prov, plain_prov });
                });
                box.add_controller(drag_src);
                Singularity.Animation.DragLift.attach(drag_src, box);
                list_item.set_child(box);
            });
            factory_name.bind.connect((item) => {
                var list_item = (ListItem)item;
                var box = (Box)list_item.get_child();
                var img = box.get_data<Image>("thumb-img");
                var label = (Label)img.get_next_sibling();
                var file_item = (FileItem)list_item.get_item();
                // Store file item for right-click gesture lookup
                box.set_data<FileItem>("file-item", file_item);
                label.label = file_item.name;
                bind_thumbnail(img, null, file_item, 24, true);
                // Cut visual feedback
                bool is_cut = clipboard_is_cut && clipboard_has(file_item.file);
                if (is_cut) box.add_css_class("cut"); else box.remove_css_class("cut");
            });
            var col_name = new ColumnViewColumn("Name", factory_name);
            col_name.expand = true;
            col_name.resizable = true;
            file_view.append_column(col_name);

            var factory_author = new SignalListItemFactory();
            factory_author.setup.connect((item) => {
                var list_item = (ListItem)item;
                var row = new Box(Orientation.HORIZONTAL, 6);
                row.halign = Align.START;
                var av = new Singularity.Widgets.Avatar(20);
                av.visible = false;
                var label = new Label("");
                label.add_css_class("dim-label");
                row.append(av);
                row.append(label);
                row.set_data<Singularity.Widgets.Avatar>("author-av", av);
                row.set_data<Label>("author-lbl", label);
                list_item.set_child(row);
            });
            factory_author.bind.connect((item) => {
                var list_item = (ListItem)item;
                var row = (Box)list_item.get_child();
                var av = row.get_data<Singularity.Widgets.Avatar>("author-av");
                var label = row.get_data<Label>("author-lbl");
                var file_item = (FileItem)list_item.get_item();
                string user = file_item.info.get_attribute_string("owner::user") ?? "";
                label.label = user;
                string? apath = avatar_path_for_user(user);
                if (apath != null) {
                    av.set_from_file(apath);
                    av.visible = true;
                } else {
                    av.visible = false;
                }
            });
            col_author = new ColumnViewColumn("Author", factory_author);
            col_author.resizable = true;
            col_author.fixed_width = 150;
            file_view.insert_column(1, col_author);

            var factory_size = new SignalListItemFactory();
            factory_size.setup.connect((item) => {
                var list_item = (ListItem)item;
                var label = new Label("");
                label.halign = Align.END;
                list_item.set_child(label);
            });
            factory_size.bind.connect((item) => {
                var list_item = (ListItem)item;
                var label = (Label)list_item.get_child();
                var file_item = (FileItem)list_item.get_item();
                if (file_item.info.get_file_type() == FileType.DIRECTORY
                        || !file_item.info.has_attribute(FileAttribute.STANDARD_SIZE)) {
                    label.label = "--";
                } else {
                    label.label = format_size(file_item.info.get_size());
                }
            });
            col_size = new ColumnViewColumn("Size", factory_size);
            col_size.resizable = true;
            file_view.append_column(col_size);
            // Type column
            var factory_type = new SignalListItemFactory();
            factory_type.setup.connect((item) => {
                var list_item = (ListItem)item;
                var label = new Label("");
                label.halign = Align.START;
                label.add_css_class("dim-label");
                list_item.set_child(label);
            });
            factory_type.bind.connect((item) => {
                var list_item = (ListItem)item;
                var label = (Label)list_item.get_child();
                var file_item = (FileItem)list_item.get_item();
                if (file_item.info.get_file_type() == FileType.DIRECTORY) {
                    label.label = _("Folder");
                } else {
                    string? ctype = file_item.info.get_content_type();
                    label.label = ctype != null ? GLib.ContentType.get_description(ctype) : "";
                }
            });
            col_type = new ColumnViewColumn("Type", factory_type);
            col_type.fixed_width = 140;
            col_type.resizable = true;
            file_view.append_column(col_type);
            // Modified column
            var factory_modified = new SignalListItemFactory();
            factory_modified.setup.connect((item) => {
                var list_item = (ListItem)item;
                var label = new Label("");
                label.halign = Align.END;
                label.add_css_class("dim-label");
                list_item.set_child(label);
            });
            factory_modified.bind.connect((item) => {
                var list_item = (ListItem)item;
                var label = (Label)list_item.get_child();
                var file_item = (FileItem)list_item.get_item();
                var mtime = file_item.info.get_modification_date_time();
                if (mtime != null) {
                    mtime = mtime.to_local();
                    var now = new GLib.DateTime.now_local();
                    var diff = now.difference(mtime) / GLib.TimeSpan.DAY;
                    if (diff == 0)
                        label.label = mtime.format(_("%H:%M"));
                    else if (diff < 365)
                        label.label = mtime.format(_("%b %d"));
                    else
                        label.label = mtime.format(_("%Y-%m-%d"));
                } else {
                    label.label = "";
                }
            });
            col_modified = new ColumnViewColumn("Modified", factory_modified);
            col_modified.fixed_width = 90;
            col_modified.resizable = true;
            file_view.append_column(col_modified);

            // Sorters make the column headers clickable. The actual ordering is
            // still applied by sort_files() (it keeps folders first and honours
            // the saved sort settings), so here we just map the clicked column
            // and direction onto the sort settings and re-sort.
            col_name.set_sorter(new Gtk.CustomSorter((a, b) =>
                ((FileItem) a).name.collate(((FileItem) b).name)));
            col_size.set_sorter(new Gtk.CustomSorter((a, b) => {
                int64 sa = ((FileItem) a).info.get_size();
                int64 sb = ((FileItem) b).info.get_size();
                return sa < sb ? -1 : (sa > sb ? 1 : 0);
            }));
            col_type.set_sorter(new Gtk.CustomSorter((a, b) =>
                (((FileItem) a).info.get_content_type() ?? "").collate(
                 ((FileItem) b).info.get_content_type() ?? "")));
            col_modified.set_sorter(new Gtk.CustomSorter((a, b) => {
                var da = ((FileItem) a).info.get_modification_date_time();
                var db = ((FileItem) b).info.get_modification_date_time();
                if (da == null || db == null) return 0;
                return da.compare(db);
            }));
            var col_sorter = file_view.sorter as Gtk.ColumnViewSorter;
            if (col_sorter != null) {
                col_sorter.changed.connect(() => {
                    var pcol = col_sorter.get_primary_sort_column();
                    if (pcol == null) return;
                    string method = "name";
                    if (pcol == col_size) method = "size";
                    else if (pcol == col_type) method = "type";
                    else if (pcol == col_modified) method = "date";
                    bool asc = col_sorter.get_primary_sort_order() == Gtk.SortType.ASCENDING;
                    settings.set_string("sort-method", method);
                    settings.set_string("sort-order", asc ? "ascending" : "descending");
                    sort_files();
                });
            }
            // Right-click on column headers to toggle column visibility
            var header_gesture = new GestureClick();
            header_gesture.button = 3;
            header_gesture.pressed.connect((n, x, y) => {
                if (y < 36) show_column_menu(file_view, x, y);
            });
            file_view.add_controller(header_gesture);
            var row_menu_gesture = new GestureClick();
            row_menu_gesture.button = 3;
            row_menu_gesture.set_propagation_phase(PropagationPhase.CAPTURE);
            row_menu_gesture.pressed.connect((n, x, y) => {
                var fi = list_item_at(x, y);
                if (fi == null) return;
                row_menu_gesture.set_state(EventSequenceState.CLAIMED);
                select_for_menu(fi);
                show_context_menu(file_view, fi, x, y);
            });
            file_view.add_controller(row_menu_gesture);
            list_widget.row_activated.connect((pos) => {
                on_item_activated(pos);
            });
            list_widget.background_right_clicked.connect((x, y) => {
                show_background_context_menu(list_widget.scroll, x, y);
            });
            stack.add_titled(list_widget, "list", "List");
            var grid_widget = new Singularity.Widgets.DataGridView();
            var grid_view = grid_widget.grid_view;
            _grid_view = grid_view;
            grid_view.factory = new SignalListItemFactory();
            grid_widget.set_selection_model(selection);
            grid_view.add_css_class("file-grid");
            grid_widget.max_columns = 8;
            grid_widget.min_columns = 2;
            var grid_factory = (SignalListItemFactory)grid_view.factory;
            grid_factory.setup.connect((item) => {
                var list_item = (ListItem)item;
                var box = new Box(Orientation.VERTICAL, 6);
                box.add_css_class("file-grid-item");
                box.halign = Align.CENTER;
                box.valign = Align.START;
                box.hexpand = false;
                box.vexpand = false;
                var img = new Image();
                img.pixel_size = 48;
                img.add_css_class("file-icon");
                // Spinner overlay shown while thumbnail loads
                var spinner = new Spinner();
                spinner.halign = Align.CENTER;
                spinner.valign = Align.CENTER;
                spinner.visible = false;
                // Scissors badge shown when file is in cut clipboard
                var cut_badge = new Image();
                cut_badge.icon_name = "edit-cut-symbolic";
                cut_badge.pixel_size = 14;
                cut_badge.halign = Align.END;
                cut_badge.valign = Align.END;
                cut_badge.visible = false;
                cut_badge.add_css_class("cut-badge");
                var thumb_overlay = new Overlay();
                thumb_overlay.set_child(img);
                thumb_overlay.add_overlay(spinner);
                thumb_overlay.add_overlay(cut_badge);
                var owner_av = new Singularity.Widgets.Avatar(22);
                owner_av.halign = Align.END;
                owner_av.valign = Align.END;
                owner_av.margin_end = 2;
                owner_av.margin_bottom = 2;
                owner_av.visible = false;
                thumb_overlay.add_overlay(owner_av);
                var label = new Label("");
                label.ellipsize = Pango.EllipsizeMode.END;
                label.wrap = true;
                label.wrap_mode = Pango.WrapMode.WORD_CHAR;
                label.lines = 2;
                label.max_width_chars = 12;
                label.justify = Justification.CENTER;
                box.append(thumb_overlay);
                box.append(label);
                // Store widget refs so bind doesn't rely on fragile child ordering
                box.set_data<Image>("thumb-img", img);
                box.set_data<Spinner>("thumb-spinner", spinner);
                box.set_data<Image>("cut-badge-img", cut_badge);
                box.set_data<Singularity.Widgets.Avatar>("owner-av", owner_av);
                // Right-click context menu for grid view
                var gesture = new GestureClick();
                gesture.button = 3;
                gesture.pressed.connect((n, x, y) => {
                    var fi = box.get_data<FileItem>("file-item");
                    if (fi != null) show_context_menu(box, fi, x, y);
                });
                box.add_controller(gesture);
                // Drag and drop source - COPY and MOVE for external apps too
                var drag_src = new DragSource();
                drag_src.actions = Gdk.DragAction.COPY | Gdk.DragAction.MOVE;
                drag_src.prepare.connect((x, y) => {
                    var fi = box.get_data<FileItem>("file-item");
                    if (fi == null) return null;
                    var uri = fi.file.get_uri();
                    var file_list = new Gdk.FileList.from_array({ fi.file });
                    var files_prov = new Gdk.ContentProvider.for_value(file_list);
                    var uri_prov   = new Gdk.ContentProvider.for_bytes("text/uri-list", new GLib.Bytes((uri + "\r\n").data));
                    var plain_prov = new Gdk.ContentProvider.for_bytes("text/plain",    new GLib.Bytes(uri.data));
                    return new Gdk.ContentProvider.union({ files_prov, uri_prov, plain_prov });
                });
                box.add_controller(drag_src);
                Singularity.Animation.DragLift.attach(drag_src, box);
                list_item.set_child(box);
            });
            grid_factory.bind.connect((item) => {
                var list_item = (ListItem)item;
                var box = (Box)list_item.get_child();
                var img = box.get_data<Image>("thumb-img");
                var spinner = box.get_data<Spinner>("thumb-spinner");
                var cut_badge = box.get_data<Image>("cut-badge-img");
                var thumb_overlay = (Overlay)box.get_first_child();
                var label = (Label)thumb_overlay.get_next_sibling();
                var file_item = (FileItem)list_item.get_item();
                // Store file item for right-click gesture lookup
                box.set_data<FileItem>("file-item", file_item);
                label.label = file_item.name;
                // Apply current icon size (may change via Ctrl+/-/0).
                img.pixel_size = grid_icon_size;
                // Reset spinner state on every rebind (widget recycling)
                spinner.spinning = false;
                spinner.visible = false;
                bind_thumbnail(img, spinner, file_item, grid_icon_size, false);
                // Cut visual feedback
                bool is_cut = clipboard_is_cut && clipboard_has(file_item.file);
                cut_badge.visible = is_cut;
                if (is_cut) box.add_css_class("cut"); else box.remove_css_class("cut");
                // Owner avatar badge (folders owned by a user with a picture)
                var owner_av = box.get_data<Singularity.Widgets.Avatar>("owner-av");
                if (owner_av != null) {
                    string? apath = (file_item.info.get_file_type() == FileType.DIRECTORY)
                        ? avatar_path_for_user(file_item.info.get_attribute_string("owner::user") ?? "")
                        : null;
                    if (apath != null) {
                        owner_av.set_from_file(apath);
                        owner_av.visible = true;
                    } else {
                        owner_av.visible = false;
                    }
                }
            });
            grid_factory.unbind.connect((item) => {
                var list_item = (ListItem)item;
                var box = (Box)list_item.get_child();
                var img = box.get_data<Image>("thumb-img");
                var spinner = box.get_data<Spinner>("thumb-spinner");
                var cut_badge = box.get_data<Image>("cut-badge-img");
                if (img != null) img.set_data<string>("thumb-for-path", "");
                if (spinner != null) { spinner.spinning = false; spinner.visible = false; }
                if (cut_badge != null) cut_badge.visible = false;
                var owner_av = box.get_data<Singularity.Widgets.Avatar>("owner-av");
                if (owner_av != null) owner_av.visible = false;
                box.remove_css_class("cut");
            });
            grid_view.activate.connect((pos) => {
                on_item_activated(pos);
            });
            var key_controller_list = new EventControllerKey();
            key_controller_list.set_propagation_phase(PropagationPhase.CAPTURE);
            key_controller_list.key_pressed.connect(on_key_pressed);
            file_view.add_controller(key_controller_list);
            var key_controller_grid = new EventControllerKey();
            key_controller_grid.set_propagation_phase(PropagationPhase.CAPTURE);
            key_controller_grid.key_pressed.connect(on_key_pressed);
            grid_view.add_controller(key_controller_grid);
            grid_widget.background_right_clicked.connect((x, y) => {
                show_background_context_menu(grid_widget.scroll, x, y);
            });
            stack.add_titled(grid_widget, "grid", "Grid");
            _empty_holder = new Box(Orientation.VERTICAL, 0);
            _empty_holder.hexpand = true;
            _empty_holder.vexpand = true;
            _empty_key = "";
            stack.add_named(_empty_holder, "empty");

            var empty_menu_gesture = new GestureClick();
            empty_menu_gesture.button = 3;
            empty_menu_gesture.pressed.connect((n, x, y) => {
                if (current_folder != null && file_store.get_n_items() == 0) {
                    show_background_context_menu(stack, x, y);
                }
            });
            stack.add_controller(empty_menu_gesture);

            var network_empty = new Singularity.Widgets.StatusPage();
            network_empty.icon_name = "network-workgroup-symbolic";
            network_empty.title = _("No Network Shares Found");
            network_empty.description = "No Samba/SMB shares were discovered on the local network.\nUse \"Connect to Server\" at the top of this page to connect to a specific address.";
            stack.add_named(network_empty, "network-empty");

            _col_browser = new Singularity.Widgets.ColumnBrowser();
            stack.add_named(_col_browser, "column");

            // Disks page - also wrapped with toolbar spacer
            var disks_wrapper = new Box(Orientation.VERTICAL, 0);
            disks_wrapper.hexpand = true;
            disks_wrapper.vexpand = true;
            var disks_scroll = new ScrolledWindow();
            disks_scroll.hscrollbar_policy = PolicyType.NEVER;
            disks_scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
            disks_scroll.vexpand = true;
            var disks_fb = new FlowBox();
            disks_fb.homogeneous = true;
            disks_fb.column_spacing = 16;
            disks_fb.row_spacing = 16;
            disks_fb.margin_top = 16;
            disks_fb.margin_bottom = 16;
            disks_fb.margin_start = 16;
            disks_fb.margin_end = 16;
            disks_fb.max_children_per_line = 6;
            disks_fb.min_children_per_line = 2;
            disks_fb.selection_mode = SelectionMode.NONE;
            disks_scroll.set_child(disks_fb);
            Singularity.Widgets.apply_titlebar_inset(disks_scroll);
            disks_wrapper.append(disks_scroll);
            stack.add_named(disks_wrapper, "disks");
            _disks_page_box = disks_fb;

            container.set_child(stack);
            container.set_data<Stack>("view_stack", stack);
            // Store direct reference so toolbar setup (which runs after activate) can find it
            view_stack_ref = stack;
            string mode = settings.get_string("view-mode");
            stack.visible_child_name = mode;
            // Starting in column view shows the "column" page with no panes loaded;
            // defer the load until the folder is known.
            if (mode == "column") {
                GLib.Idle.add(() => {
                    if (current_folder != null) {
                        update_view_mode();
                    }
                    return GLib.Source.REMOVE;
                });
            }
        }
        [DBus (name = "dev.sinty.shell.Preview")]
        private interface PreviewService : Object {
            public abstract void show_preview (string uri) throws Error;
            public abstract void show_previews (string[] uris, int index, string origin) throws Error;
            public abstract void close_preview () throws Error;
        }

        // ush integration: host-only broker interface (the guest can't reach the
        // session bus). trust_dir/untrust_dir back "Share with Linux".
        [DBus (name = "io.github.singularityos_lab.ush.Broker1")]
        private interface UshBroker : Object {
            public abstract void trust_dir (string path) throws Error;
            public abstract void untrust_dir (string path) throws Error;
            public abstract bool is_dir_trusted (string path) throws Error;
            public abstract string list_dev_dirs () throws Error;
        }

        // host paths shared with Linux, read straight from the broker policy file.
        private string[] ush_list_shared_dirs() {
            string path = Path.build_filename(Environment.get_home_dir(),
                ".local", "share", "ush", "policy.json");
            string[] result = {};
            try {
                var parser = new Json.Parser();
                parser.load_from_file(path);
                var root = parser.get_root();
                if (root == null) return {};
                var arr = root.get_array();
                if (arr == null) return {};
                for (uint i = 0; i < arr.get_length(); i++) {
                    var obj = arr.get_object_element(i);
                    if (obj == null) continue;
                    if (obj.get_string_member_with_default("category", "") != "devdir") continue;
                    if (obj.get_string_member_with_default("decision", "") != "allow") continue;
                    string res = obj.get_string_member_with_default("resource", "");
                    if (res != "") result += res;
                }
            } catch (Error e) {
                return {};
            }
            return result;
        }

        // ush guest home (its private layer), or null if ush isn't installed.
        private string? ush_linux_home() {
            string p = Path.build_filename(Environment.get_home_dir(),
                ".local", "share", "ush", "layers", "persistent", "home");
            if (FileUtils.test(p, FileTest.IS_DIR))
                return p;
            return null;
        }

        // dsh developer home, or null until the dev environment is first launched.
        private string? ush_dev_home() {
            string p = Path.build_filename(Environment.get_home_dir(),
                ".local", "share", "ush", "layers", "persistent", "dev-home");
            if (FileUtils.test(p, FileTest.IS_DIR))
                return p;
            return null;
        }

        // dir to share for a menu item (the folder, or a file's parent); null
        // inside ush storage itself.
        private string? ush_share_target(FileItem item) {
            if (ush_linux_home() == null)
                return null;
            string? fpath = item.file.get_path();
            if (fpath == null)
                return null;
            string ush_root = Path.build_filename(Environment.get_home_dir(),
                ".local", "share", "ush");
            if (fpath == ush_root || fpath.has_prefix(ush_root + "/"))
                return null;
            return item.is_folder ? fpath : Path.get_dirname(fpath);
        }

        private UshBroker? ush_broker_proxy() {
            try {
                return Bus.get_proxy_sync<UshBroker>(BusType.SESSION,
                    "io.github.singularityos_lab.ush.Broker",
                    "/io/github/singularityos_lab/ush/Broker");
            } catch (Error e) {
                warning("ush: broker proxy failed: %s", e.message);
                return null;
            }
        }

        private bool ush_is_dir_trusted(string path) {
            var b = ush_broker_proxy();
            if (b == null) return false;
            try {
                return b.is_dir_trusted(path);
            } catch (Error e) {
                return false;
            }
        }

        private void ush_set_dir_shared(string path, bool shared) {
            var b = ush_broker_proxy();
            if (b == null) {
                warning("ush: broker unavailable; is ush-broker running?");
                return;
            }
            try {
                if (shared) b.trust_dir(path);
                else b.untrust_dir(path);
            } catch (Error e) {
                warning("ush: share toggle failed: %s", e.message);
                return;
            }
            var notif = new Notification(shared ? _("Shared with Linux") : _("Stopped sharing with Linux"));
            notif.set_body(shared
                ? _("The ush shell can now read and write %s.").printf(path)
                : _("The ush shell will no longer access %s.").printf(path));
            notif.set_icon(new ThemedIcon("ush-penguin"));
            this.send_notification("ush-share", notif);
        }

        private bool on_key_pressed(uint keyval, uint keycode, Gdk.ModifierType state) {
            if (_cloud_view != null && _cloud_view.active) return false;
            bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;

            if (!ctrl && keyval == Gdk.Key.F5 && current_folder != null) {
                navigate_to.begin(current_folder);
                return true;
            }

            // When a text entry is focused (e.g. the save-mode filename field),
            // let plain typing through instead of consuming it here. This
            // capture-phase handler otherwise swallows Space and printable keys
            // before the entry sees them.
            if (!ctrl) {
                var focusw = active_window != null ? active_window.get_focus() : null;
                if (focusw is Gtk.Editable || focusw is Gtk.Text) {
                    unichar uc = Gdk.keyval_to_unicode(keyval);
                    if (keyval == Gdk.Key.space || uc > 0x20) return false;
                }
            }

            // Enter/Return in picker mode - submit selection
            if (picker_mode && !ctrl && (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter)) {
                submit_picker_selection();
                return true;
            }

            // ESC in picker mode - two-level: clear search first, then close
            if (picker_mode && keyval == Gdk.Key.Escape) {
                if (path_bar_stack != null &&
                    path_bar_stack.visible_child_name == "search") {
                    clear_search();
                    if (current_folder != null) navigate_to.begin(current_folder);
                    return true;
                }
                if (active_window != null) active_window.close();
                if (portal_mode) quit();
                return true;
            }

            // ESC in non-picker mode - clear search first, then cancel cut
            if (!picker_mode && keyval == Gdk.Key.Escape &&
                path_bar_stack != null && path_bar_stack.visible_child_name == "search") {
                clear_search();
                if (current_folder != null) navigate_to.begin(current_folder);
                return true;
            }

            // ESC - cancel cut mode
            if (!picker_mode && keyval == Gdk.Key.Escape && clipboard_is_cut) {
                clipboard_is_cut = false;
                clipboard_files = new GLib.GenericArray<File>();
                update_menu_actions();
                if (current_folder != null) navigate_to.begin(current_folder);
                return true;
            }

            // Ctrl+P opens the path-entry palette (same effect as "/").
            if (ctrl && keyval == Gdk.Key.p) {
                open_location_entry();
                return true;
            }

            // Ctrl+A - select all
            if (ctrl && keyval == Gdk.Key.a) {
                select_all_files();
                return true;
            }

            // Ctrl+C - copy selected file to clipboard
            if (ctrl && keyval == Gdk.Key.c) {
                copy_selected(false);
                return true;
            }
            // Ctrl+X / Ctrl+K - cut selected file
            if (ctrl && (keyval == Gdk.Key.x || keyval == Gdk.Key.k)) {
                copy_selected(true);
                return true;
            }
            // Ctrl+V - paste
            if (ctrl && keyval == Gdk.Key.v) {
                paste_files();
                return true;
            }
            // Delete / KP_Delete - move selected file to trash (async via ops manager)
            if (!ctrl && (keyval == Gdk.Key.Delete || keyval == Gdk.Key.KP_Delete)) {
                trash_selected();
                return true;
            }
            // "/" - focus path entry
            if (!ctrl && keyval == Gdk.Key.slash) {
                if (path_bar_stack != null && path_bar_stack.visible_child_name == "bar") {
                    if (current_folder != null) {
                        path_entry_widget.text = current_folder.get_path() ?? "";
                    }
                    path_bar_stack.visible_child_name = "entry";
                    path_entry_widget.grab_focus();
                    path_entry_widget.set_position(-1);
                    update_path_completions();
                    return true;
                }
                return false;
            }
            // "~" - focus path entry pre-filled with home dir
            if (keyval == Gdk.Key.asciitilde && path_bar_stack != null && path_bar_stack.visible_child_name == "bar") {
                path_entry_widget.text = Environment.get_home_dir() + "/";
                path_bar_stack.visible_child_name = "entry";
                path_entry_widget.grab_focus();
                path_entry_widget.set_position(-1);
                update_path_completions();
                return true;
            }
            // Printable character, open search mode (excludes Space which is handled below)
            if (!ctrl && path_bar_stack != null && path_bar_stack.visible_child_name == "bar" && file_view_has_focus()) {
                unichar uc = Gdk.keyval_to_unicode(keyval);
                if (uc > 0x20 && uc != 0x7F && settings.get_string("typing-in-folder") == "select") {
                    type_ahead(uc);
                    return true;
                }
                if (uc > 0x20 && uc != 0x7F) {
                    current_search = uc.to_string();
                    search_entry_widget.text = current_search;
                    path_bar_stack.visible_child_name = "search";
                    search_entry_widget.grab_focus();
                    search_entry_widget.set_position(-1);
                    if (current_folder != null) navigate_to.begin(current_folder);
                    return true;
                }
            }
            // Ctrl+N - new window (spawn separate process to avoid shared state)
            if (ctrl && (state & Gdk.ModifierType.SHIFT_MASK) == 0 && keyval == Gdk.Key.n) {
                open_new_window();
                return true;
            }
            // Ctrl+Shift+N - new folder
            if (ctrl && (state & Gdk.ModifierType.SHIFT_MASK) != 0 && (keyval == Gdk.Key.n || keyval == Gdk.Key.N)) {
                show_new_folder_dialog();
                return true;
            }
            // F2 renames the selected row. Column mode tracks selection per pane
            // (separate from file_view's model), so check there first.
            if (!ctrl && keyval == Gdk.Key.F2) {
                if (rename_selected()) return true;
            }
            // Space - quick preview (independent of show-previews thumbnail setting)
            if (!ctrl && keyval == Gdk.Key.space) {
                var selected = get_selected_items();
                if (selected.length > 0) {
                    trigger_preview(selected.get(0).file.get_uri());
                    return true;
                }
                return true; // consume Space even with no selection to avoid GTK default
            }
            // Ctrl+H - toggle hidden files
            if (ctrl && keyval == Gdk.Key.h) {
                bool current = settings.get_boolean("show-hidden");
                settings.set_boolean("show-hidden", !current);
                return true;
            }
            // Ctrl+Shift+V - cycle view mode (list, grid, column)
            if (ctrl && (state & Gdk.ModifierType.SHIFT_MASK) != 0 && (keyval == Gdk.Key.v || keyval == Gdk.Key.V)) {
                string cur = settings.get_string("view-mode");
                string next = (cur == "list") ? "grid" : (cur == "grid") ? "column" : "list";
                settings.set_string("view-mode", next);
                return true;
            }
            // Ctrl+Plus / Ctrl+Equal - increase grid icon size
            if (ctrl && (keyval == Gdk.Key.plus || keyval == Gdk.Key.equal || keyval == Gdk.Key.KP_Add)) {
                int sz = int.min(128, settings.get_int("icon-size") + 8);
                settings.set_int("icon-size", sz);
                return true;
            }
            // Ctrl+Minus - decrease grid icon size
            if (ctrl && (keyval == Gdk.Key.minus || keyval == Gdk.Key.KP_Subtract)) {
                int sz = int.max(24, settings.get_int("icon-size") - 8);
                settings.set_int("icon-size", sz);
                return true;
            }
            // Ctrl+0 - reset grid icon size to default
            if (ctrl && (keyval == Gdk.Key.@0 || keyval == Gdk.Key.KP_0)) {
                settings.set_int("icon-size", 48);
                return true;
            }
            return false;
        }

        private void type_ahead(unichar uc) {
            _type_ahead += uc.to_string();
            if (_type_ahead_timeout != 0) Source.remove(_type_ahead_timeout);
            _type_ahead_timeout = Timeout.add(1000, () => {
                _type_ahead_timeout = 0;
                _type_ahead = "";
                return Source.REMOVE;
            });
            string needle = _type_ahead.casefold();
            int prefix_match = -1;
            int inner_match = -1;
            for (uint i = 0; i < file_store.get_n_items(); i++) {
                string name = ((FileItem) file_store.get_item(i)).name.casefold();
                if (name.has_prefix(needle)) {
                    prefix_match = (int) i;
                    break;
                }
                if (inner_match < 0 && name.contains(needle)) inner_match = (int) i;
            }
            int match = prefix_match >= 0 ? prefix_match : inner_match;
            if (match < 0) return;
            var flags = ListScrollFlags.FOCUS | ListScrollFlags.SELECT;
            if (settings.get_string("view-mode") == "grid" && _grid_view != null) {
                _grid_view.scroll_to(match, flags, null);
            } else {
                file_view.scroll_to(match, null, flags, null);
            }
        }

        private bool file_view_has_focus() {
            if (active_window == null) return false;
            var focus = active_window.get_focus();
            if (focus == null) return false;

            if (file_view != null && widget_contains(file_view, focus)) return true;
            if (_grid_view != null && widget_contains(_grid_view, focus)) return true;
            if (_col_browser != null && widget_contains(_col_browser, focus)) return true;

            return false;
        }

        private static bool widget_contains(Widget root, Widget child) {
            Widget? current = child;
            while (current != null) {
                if (current == root) return true;
                current = current.get_parent();
            }
            return false;
        }

        private string? avatar_path_for_user(string user) {
            if (user == "") return null;
            string p = "/var/lib/AccountsService/icons/" + user;
            if (FileUtils.test(p, FileTest.EXISTS)) return p;
            return null;
        }

        private bool clipboard_has(File f) {
            for (int i = 0; i < clipboard_files.length; i++)
                if (clipboard_files.get(i).get_uri() == f.get_uri()) return true;
            return false;
        }

        private void set_clipboard(GenericArray<FileItem> items, bool cut) {
            clipboard_files = new GLib.GenericArray<File>();
            for (int i = 0; i < items.length; i++)
                clipboard_files.add(items.get(i).file);
            clipboard_is_cut = cut;
            update_menu_actions();
        }

        private void clipboard_set_for_menu(FileItem item, bool cut) {
            var selected = get_selected_items();
            bool item_selected = false;
            for (int i = 0; i < selected.length; i++)
                if (selected.get(i).file.get_uri() == item.file.get_uri()) { item_selected = true; break; }
            if (selected.length > 1 && item_selected) {
                set_clipboard(selected, cut);
            } else {
                clipboard_files = new GLib.GenericArray<File>();
                clipboard_files.add(item.file);
                clipboard_is_cut = cut;
            }
            update_menu_actions();
        }

        private void paste_files() {
            if (clipboard_files.length == 0 || current_folder == null) return;
            ensure_ops_manager();
            bool was_cut = clipboard_is_cut;
            var srcs = new GLib.File[clipboard_files.length];
            for (int i = 0; i < clipboard_files.length; i++) srcs[i] = clipboard_files.get(i);
            var op = _ops.start_transfer(srcs, current_folder, was_cut);
            if (was_cut) {
                clipboard_files = new GLib.GenericArray<File>();
                clipboard_is_cut = false;
                update_menu_actions();
            }
            op.completed.connect(() => {
                if (current_folder != null) navigate_to.begin(current_folder);
            });
            navigate_to.begin(current_folder);
        }

        private void ensure_ops_manager() {
            if (_ops == null) {
                _ops = new Files.FileOpsManager();
                _ops.state_changed.connect(() => update_ops_banner());
                _ops.conflict.connect((request) => {
                    new Files.ConflictDialog(this, request, _ops.active_count()).present();
                });
                _ops.password_needed.connect((request) => {
                    var dlg = new Files.Archives.ArchivePasswordDialog(this, active_window, request.archive_name, request.retry);
                    dlg.answered.connect((pw) => request.answer(pw));
                    dlg.open_dialog();
                });
            }
        }

        // ── Operations banner ─────────────────────────────────────────────────
        private Gtk.Widget build_content_with_ops_banner(Gtk.Widget content) {
            ensure_ops_manager();

            var outer = new Gtk.Box(Orientation.VERTICAL, 0);
            content.hexpand = true;
            content.vexpand = true;

            _archive_banner = new Singularity.Widgets.Banner("", Singularity.Widgets.BannerStyle.INFO);
            _archive_banner.icon_name = "package-x-generic-symbolic";
            _archive_banner.button_label = _("Extract…");
            _archive_banner.button_clicked.connect(() => extract_current_archive());
            _archive_banner.visible = false;
            _archive_banner.margin_start = 12;
            _archive_banner.margin_end = 12;
            _archive_banner.margin_bottom = 6;

            // The file-count label snaps to the opposite corner on hover
            // so the pointer never covers it.
            var count_overlay = new Gtk.Overlay();
            count_overlay.set_child(content);
            _file_count_lbl = new Gtk.Label("");
            _file_count_lbl.add_css_class("dim-label");
            _file_count_lbl.add_css_class("caption");
            _file_count_lbl.add_css_class("files-count-overlay");
            _file_count_lbl.halign = Align.END;
            _file_count_lbl.valign = Align.END;
            _file_count_lbl.margin_start = 12;
            _file_count_lbl.margin_end   = 12;
            _file_count_lbl.margin_bottom = 8;
            _file_count_lbl.can_target = false;
            count_overlay.add_overlay(_file_count_lbl);

            var motion = new Gtk.EventControllerMotion();
            motion.motion.connect((x, y) => {
                int w = count_overlay.get_width();
                int h = count_overlay.get_height();
                // Bottom-right rectangle the label occupies; when the cursor
                // enters it the label hops left.
                bool in_br = (x > w - 220 && y > h - 56);
                _file_count_lbl.halign = in_br ? Align.START : Align.END;
            });
            count_overlay.add_controller(motion);

            outer.append(count_overlay);
            outer.append(_archive_banner);

            _ops_banner = new Gtk.Revealer();
            _ops_banner.transition_type = Gtk.RevealerTransitionType.SLIDE_UP;
            _ops_banner.transition_duration = 180;
            _ops_banner.reveal_child = false;

            var bar = new Gtk.Box(Orientation.HORIZONTAL, 10);
            bar.add_css_class("files-ops-banner");
            bar.margin_start = 12;
            bar.margin_end = 12;
            bar.margin_top = 6;
            bar.margin_bottom = 6;

            var icon = new Gtk.Image.from_icon_name("emblem-synchronizing-symbolic");
            icon.pixel_size = 18;
            bar.append(icon);

            _ops_label = new Gtk.Label("");
            _ops_label.halign = Align.START;
            _ops_label.hexpand = false;
            _ops_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            _ops_label.max_width_chars = 40;
            bar.append(_ops_label);

            _ops_progress_bar = new Gtk.ProgressBar();
            _ops_progress_bar.hexpand = true;
            _ops_progress_bar.valign = Align.CENTER;
            _ops_progress_bar.add_css_class("files-ops-progress");
            bar.append(_ops_progress_bar);

            _ops_cancel_btn = new Gtk.Button.from_icon_name("process-stop-symbolic");
            _ops_cancel_btn.add_css_class("flat");
            _ops_cancel_btn.tooltip_text = _("Cancel all operations");
            _ops_cancel_btn.clicked.connect(() => {
                if (_ops == null) return;
                foreach (var op in _ops.ops) {
                    if (!op.finished) op.cancellable.cancel();
                }
            });
            bar.append(_ops_cancel_btn);

            _ops_banner.set_child(bar);
            outer.append(_ops_banner);
            return outer;
        }

        private void update_ops_banner() {
            if (_ops == null || _ops_banner == null) return;
            int active = _ops.active_count();
            bool reveal = active > 0;
            bool has_recent_finished = false;
            foreach (var op in _ops.ops) if (op.finished) { has_recent_finished = true; break; }
            if (!reveal && has_recent_finished) reveal = true;

            _ops_banner.reveal_child = reveal;
            if (!reveal) return;

            double frac = _ops.aggregate_fraction();
            _ops_progress_bar.fraction = frac.clamp(0, 1);

            string label_text;
            if (active == 0 && has_recent_finished) {
                int skipped = 0;
                foreach (var o in _ops.ops) skipped += o.skipped;
                label_text = skipped > 0
                    ? _("Done, %s").printf(ngettext("%d item skipped", "%d items skipped", skipped).printf(skipped))
                    : "Done";
            } else if (_ops.ops.size == 1) {
                var op = _ops.ops[0];
                label_text = op.errored
                    ? "Failed: " + (op.error_message ?? "")
                    : (op.waiting ? _("%s, waiting for your choice").printf(op.display_name) : op.display_name);
                if (op.finished && op.skipped > 0)
                    label_text += ", " + ngettext("%d item skipped", "%d items skipped", op.skipped).printf(op.skipped);
            } else {
                label_text = "%d file operations".printf(active);
            }
            _ops_label.label = label_text;
        }

        private void show_background_context_menu(Widget widget, double mx, double my) {
            var menu = new Singularity.Widgets.ContextMenu(widget);
            Gdk.Rectangle rect = { (int)mx, (int)my, 1, 1 };
            menu.set_pointing_to(rect);
            menu.add_item(_("New Folder…"), "folder-new-symbolic", () => {
                show_new_folder_dialog();
            });
            append_new_document_menu(menu);
            if (clipboard_files.length > 0) {
                menu.add_separator();
                menu.add_item("Paste", "edit-paste-symbolic", () => {
                    paste_files();
                });
            }
            menu.add_separator();
            menu.add_item("Open Terminal Here", "utilities-terminal-symbolic", () => {
                launch_terminal();
            });
            menu.add_item("Copy Path", "edit-copy-symbolic", () => {
                if (current_folder != null) {
                    string? p = current_folder.get_path();
                    if (p == null) p = current_folder.get_uri();
                    if (p != null) widget.get_clipboard().set_text(p);
                }
            });
            var sel = get_selected_items();
            if (sel.length > 0) {
                menu.add_separator();
                menu.add_item("Compress Selected…", "package-x-generic-symbolic", () => {
                    compress_selected_files(widget);
                });
            }
            release_on_close(menu);
            menu.popup();
        }

        private void show_new_folder_dialog() {
            if (current_folder == null) return;
            var folder = current_folder;
            var dialog = new Files.NewFolderDialog((Gtk.Application) this, (Gtk.Window) file_view.get_root(), folder);
            dialog.created.connect((f) => reveal_new_item.begin(folder, f, false));
            dialog.open_dialog();
        }

        private async void reveal_new_item(File folder, File item, bool rename) {
            if (current_folder == null || !current_folder.equal(folder)) return;
            yield navigate_to(folder);
            for (uint i = 0; i < file_store.get_n_items(); i++) {
                var fi = (FileItem) file_store.get_item(i);
                if (!fi.file.equal(item)) continue;
                var flags = ListScrollFlags.FOCUS | ListScrollFlags.SELECT;
                if (settings.get_string("view-mode") == "grid" && _grid_view != null) {
                    _grid_view.scroll_to(i, flags, null);
                } else {
                    file_view.scroll_to(i, null, flags, null);
                }
                if (rename) {
                    Idle.add(() => {
                        start_inline_rename(fi);
                        return Source.REMOVE;
                    });
                }
                return;
            }
        }

        private void append_new_document_menu(Singularity.Widgets.ContextMenu menu) {
            var dir = Files.FolderTemplates.user_dir();
            if (dir == null) return;
            var sub = menu.add_submenu(_("New Document"), "document-new-symbolic");
            var docs = Files.FolderTemplates.document_templates(dir);
            foreach (var info in docs.data) {
                string file_name = info.get_name();
                string label = file_name;
                int dot = file_name.last_index_of_char('.');
                if (dot > 0) label = file_name.substring(0, dot);
                bool uncertain;
                string ctype = ContentType.guess(file_name, null, out uncertain);
                string? generic = ContentType.get_generic_icon_name(ctype);
                var source = dir.get_child(file_name);
                sub.add_item(label, (generic ?? "text-x-generic") + "-symbolic", () => create_document_from(source));
            }
            if (docs.length > 0) sub.add_separator();
            sub.add_item(_("Open Templates Folder"), "folder-templates-symbolic", () => {
                try {
                    dir.make_directory_with_parents(null);
                } catch (Error e) {
                }
                navigate_user(dir);
            });
            release_on_close(sub);
        }

        private void create_document_from(File source) {
            if (current_folder == null) return;
            var folder = current_folder;
            string name = Files.FolderNames.unique_file(source.get_basename(), (n) => Files.FolderNames.lookup_in(folder, n));
            var target = folder.get_child(name);
            source.copy_async.begin(target, FileCopyFlags.NONE, Priority.DEFAULT, null, null, (obj, res) => {
                try {
                    source.copy_async.end(res);
                    reveal_new_item.begin(folder, target, true);
                } catch (Error e) {
                    show_toast(_("Could not create %s: %s").printf(name, e.message));
                }
            });
        }

        private void save_as_folder_template(File folder) {
            var templates = Files.FolderTemplates.user_dir();
            if (templates == null) return;
            var dialog = new ConfirmDialog(this, _("Save as Folder Template"), "folder-templates",
                _("“%s” will be offered as a template in New Folder. Save only its folders, or its files too?").printf(folder.get_basename()),
                _("Folders Only"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.set_secondary(_("Folders and Files"));
            if (active_window != null) dialog.transient_for = active_window;
            dialog.response.connect((r) => {
                if (r == ConfirmDialog.Response.CANCEL) return;
                bool with_files = r == ConfirmDialog.Response.SECONDARY;
                run_save_template.begin(folder, templates, with_files, (obj, res) => {
                    string? err = run_save_template.end(res);
                    if (err == null) show_toast(_("Saved “%s” as a folder template").printf(folder.get_basename()));
                    else show_toast(_("Could not save the template: %s").printf(err));
                });
            });
            dialog.present();
        }

        private static async string? run_save_template(File folder, File templates, bool with_files) {
            SourceFunc resume = run_save_template.callback;
            string? err = null;
            new Thread<bool>("save-template", () => {
                try {
                    Files.FolderTemplates.save_folder(folder, templates, with_files);
                } catch (Error e) {
                    err = e.message;
                }
                Idle.add((owned) resume);
                return true;
            });
            yield;
            return err;
        }

        private void show_toast(string text) {
            if (active_window != null) active_window.add_toast(new Singularity.Widgets.Toast(text));
        }

        private static bool is_archive_file(string? ctype) {
            return Files.Archives.ArchiveFormats.is_archive_type(ctype);
        }

        private static bool is_image_file(FileItem item) {
            string? ctype = item.info.get_content_type();
            return ctype != null && ctype.has_prefix("image/");
        }

        private void set_as_wallpaper(FileItem item) {
            var desktop_settings = Singularity.Core.safe_settings("dev.sinty.desktop");
            if (desktop_settings == null) return;
            desktop_settings.set_string("background-picture-uri", item.file.get_uri());
        }

        private bool is_archive_item(FileItem item) {
            if (is_archive_file(item.info.get_content_type())) return true;
            if (item.is_folder) return false;
            return Files.Archives.ArchiveFormats.from_name(item.name) != Files.Archives.ArchiveKind.UNKNOWN;
        }

        private string archive_cache_root() {
            return GLib.Path.build_filename(GLib.Environment.get_user_cache_dir(), "singularity-files", "archives");
        }

        private string? archive_root_for(string? path) {
            if (path == null) return null;
            foreach (var root in _archive_views.get_keys()) {
                if (path == root || path.has_prefix(root + "/")) return root;
            }
            return null;
        }

        private void open_archive_as_folder(FileItem item) {
            string? src = item.file.get_path();
            if (src == null) return;
            string key = GLib.Checksum.compute_for_string(GLib.ChecksumType.SHA256,
                "%s:%lld:%lld".printf(src, item.info.get_size(),
                    item.info.get_modification_date_time() != null ? item.info.get_modification_date_time().to_unix() : 0));
            string dest = GLib.Path.build_filename(archive_cache_root(), key.substring(0, 24));
            if (_archive_views.contains(dest) && GLib.FileUtils.test(dest, GLib.FileTest.IS_DIR)) {
                navigate_user(File.new_for_path(dest));
                return;
            }
            Files.Archives.ArchivePaths.remove_tree(dest);
            ensure_ops_manager();
            var extractor = new Files.Archives.ArchiveExtractor(src, dest);
            extractor.read_only = true;
            extractor.use_trash = false;
            var op = _ops.start_extract(extractor, _("Opening %s").printf(item.name));
            op.completed.connect(() => {
                if (op.errored || op.cancellable.is_cancelled()) {
                    Files.Archives.ArchivePaths.remove_tree(dest);
                    if (op.errored) show_archive_error(item.name, op.error_message);
                    return;
                }
                _archive_views.insert(dest, src);
                _temp_archive_dirs += dest;
                navigate_user(File.new_for_path(dest));
                if (extractor.rejected > 0) show_toast(unsafe_text(extractor.rejected));
            });
        }

        private string unsafe_text(int count) {
            return ngettext("%d unsafe item was not extracted", "%d unsafe items were not extracted", count).printf(count);
        }

        private void show_archive_error(string name, string? message) {
            var dlg = new ConfirmDialog.message(this, _("Cannot Open \"%s\"").printf(name), "dialog-error",
                message ?? _("The archive is damaged or uses a format that is not supported."));
            dlg.transient_for = active_window;
            dlg.present();
        }

        private void run_extract(FileItem item, string dest_dir, bool here) {
            string? src = item.file.get_path();
            if (src == null) return;
            ensure_ops_manager();
            var extractor = new Files.Archives.ArchiveExtractor(src, dest_dir);
            var op = _ops.start_extract(extractor, _("Extracting %s").printf(item.name));
            op.completed.connect(() => {
                if (op.errored) {
                    if (here) Files.Archives.ArchivePaths.remove_tree(dest_dir);
                    show_archive_error(item.name, op.error_message);
                    return;
                }
                if (op.cancellable.is_cancelled()) {
                    if (here) Files.Archives.ArchivePaths.remove_tree(dest_dir);
                    return;
                }
                string result = here ? Files.Archives.ArchiveExtractor.flatten_single_child(dest_dir) : dest_dir;
                if (extractor.rejected > 0) show_toast(unsafe_text(extractor.rejected));
                if (current_folder != null) navigate_to.begin(current_folder);
                if (!here && active_window != null) {
                    var toast = new Singularity.Widgets.Toast(_("Extracted to \"%s\"").printf(GLib.Path.get_basename(result)));
                    toast.button_label = _("Show");
                    toast.button_clicked.connect(() => navigate_user(File.new_for_path(result)));
                    active_window.add_toast(toast);
                }
            });
        }

        private void extract_archive_here(FileItem item) {
            string? src = item.file.get_path();
            if (src == null) return;
            if (archive_root_for(src) != null) {
                extract_archive_to(file_view, item);
                return;
            }
            run_extract(item, Files.Archives.ArchiveExtractor.extract_here_folder(src), true);
        }

        private void extract_archive_to(Widget widget, FileItem item) {
            var dialog = new FileDialog();
            dialog.title = _("Extract To");
            dialog.accept_label = _("Extract");
            dialog.initial_folder = item.file.get_parent();
            dialog.select_folder.begin(active_window, null, (obj, res) => {
                try {
                    var dest_file = dialog.select_folder.end(res);
                    string? dest = dest_file.get_path();
                    if (dest == null) return;
                    run_extract(item, dest, false);
                } catch (Error e) {
                }
            });
        }

        private void extract_current_archive() {
            if (current_folder == null) return;
            string? root = archive_root_for(current_folder.get_path());
            if (root == null) return;
            string archive = _archive_views.get(root);
            var file = File.new_for_path(archive);
            try {
                var info = file.query_info("standard::name,standard::display-name,standard::type,standard::size,standard::content-type,time::modified",
                    FileQueryInfoFlags.NONE, null);
                extract_archive_to(file_view, new FileItem(file, info));
            } catch (Error e) {
                show_archive_error(file.get_basename(), e.message);
            }
        }

        private void compress_selected_files(Widget widget) {
            var selected = get_selected_items();
            if (selected.length == 0 || current_folder == null) return;
            if (current_folder.get_path() == null || archive_root_for(current_folder.get_path()) != null) return;
            string[] sources = {};
            foreach (var fi in selected) {
                string? p = fi.file.get_path();
                if (p != null) sources += p;
            }
            if (sources.length == 0) return;
            string default_name = selected.length == 1
                ? Files.Archives.ArchiveFormats.stem(selected[0].name)
                : _("Archive");
            var dialog = new Files.Archives.CreateArchiveDialog(this, active_window, current_folder, sources, default_name);
            dialog.create_requested.connect((creator) => {
                ensure_ops_manager();
                var op = _ops.start_create(creator);
                var folder = current_folder;
                op.completed.connect(() => {
                    if (op.errored) {
                        show_archive_error(GLib.Path.get_basename(creator.output_path), op.error_message);
                        return;
                    }
                    if (op.cancellable.is_cancelled()) return;
                    if (folder != null && op.result_path != null) {
                        reveal_new_item.begin(folder, File.new_for_path(op.result_path), false);
                    }
                    if (creator.outputs.length > 1) {
                        show_toast(ngettext("Saved in %d part", "Saved in %d parts", creator.outputs.length).printf(creator.outputs.length));
                    }
                });
            });
            dialog.open_dialog();
        }

        private void add_archive_properties(Grid grid, int row, File file) {
            string? path = file.get_path();
            if (path == null) return;
            var rows = new Gee.ArrayList<Label>();
            string[] captions = { _("Contents:"), _("Compressed:"), _("Uncompressed:"), _("Ratio:"), _("Format:") };
            for (int i = 0; i < captions.length; i++) {
                var lbl = new Label(captions[i]);
                lbl.halign = Align.END;
                lbl.add_css_class("dim-label");
                lbl.add_css_class("caption");
                grid.attach(lbl, 0, row + i);
                var val = new Label(i == 0 ? _("Reading the archive…") : "");
                val.halign = Align.START;
                val.wrap = true;
                val.max_width_chars = 28;
                val.selectable = true;
                grid.attach(val, 1, row + i);
                rows.add(val);
            }
            var cancel = new Cancellable();
            grid.destroy.connect(() => cancel.cancel());
            new Thread<bool>("files-archive-props", () => {
                Files.Archives.ArchiveListing? listing = null;
                string? err = null;
                try {
                    listing = Files.Archives.ArchiveReader.list(path, null, cancel);
                } catch (Error e) {
                    err = e.message;
                }
                GLib.Idle.add(() => {
                    if (listing == null) {
                        rows[0].label = err ?? _("Cannot read the archive.");
                        return GLib.Source.REMOVE;
                    }
                    string files = ngettext("%d file", "%d files", listing.files).printf(listing.files);
                    string folders = ngettext("%d folder", "%d folders", listing.folders).printf(listing.folders);
                    rows[0].label = listing.folders > 0 ? "%s, %s".printf(files, folders) : files;
                    rows[1].label = listing.volumes > 1
                        ? ngettext("%s in %d part", "%s in %d parts", listing.volumes).printf(GLib.format_size(listing.compressed), listing.volumes)
                        : GLib.format_size(listing.compressed);
                    rows[2].label = GLib.format_size(listing.uncompressed);
                    rows[3].label = Files.Archives.ArchiveFormats.ratio_text(listing.compressed, listing.uncompressed);
                    string format = listing.kind.label();
                    if (listing.format_name != "") format = "%s, %s".printf(format, listing.format_name);
                    if (listing.encrypted) format = _("%s, protected with a password").printf(format);
                    rows[4].label = format;
                    return GLib.Source.REMOVE;
                });
                return true;
            });
        }

        private void _cleanup_temp_archive_dirs() {
            foreach (var d in _temp_archive_dirs) {
                Files.Archives.ArchivePaths.remove_tree(d);
            }
            _temp_archive_dirs = {};
            _archive_views.remove_all();
        }

        private FileItem? list_item_at(double x, double y) {
            Widget? w = file_view.pick(x, y, PickFlags.DEFAULT);
            while (w != null && w != file_view) {
                if (w.get_css_name() == "row") {
                    for (var cell = w.get_first_child(); cell != null; cell = cell.get_next_sibling()) {
                        var child = cell.get_first_child();
                        if (child == null) continue;
                        var fi = child.get_data<FileItem>("file-item");
                        if (fi != null) return fi;
                    }
                    return null;
                }
                w = w.get_parent();
            }
            return null;
        }

        private void select_for_menu(FileItem item) {
            var sel = file_view.model as SelectionModel;
            if (sel == null) return;
            for (uint i = 0; i < file_store.get_n_items(); i++) {
                if (file_store.get_item(i) == item) {
                    if (!sel.is_selected(i)) sel.select_item(i, true);
                    return;
                }
            }
        }

        private void show_context_menu(Widget widget, FileItem item, double mx = -1, double my = -1) {
            var menu = new Singularity.Widgets.ContextMenu(widget);
            if (mx >= 0 && my >= 0) {
                Gdk.Rectangle rect = { (int)mx, (int)my, 1, 1 };
                menu.set_pointing_to(rect);
            }
            bool in_trash = (current_folder != null && current_folder.get_uri().has_prefix("trash://"));
            if (in_trash) {
                menu.add_item("Restore", "edit-undo-symbolic", () => {
                    try {
                        string? orig = item.info.get_attribute_as_string("trash::orig-path");
                        if (orig != null) {
                            var dest = File.new_for_path(orig);
                            item.file.move(dest, FileCopyFlags.NONE, null, null);
                        }
                        if (current_folder != null) navigate_to.begin(current_folder);
                    } catch (Error e) {
                        warning("Restore failed: %s", e.message);
                    }
                });
                menu.add_item("Delete Permanently", "edit-delete-symbolic", () => {
                    try {
                        item.file.delete(null);
                        if (current_folder != null) navigate_to.begin(current_folder);
                    } catch (Error e) {
                        warning("Permanent delete failed: %s", e.message);
                    }
                });
            } else {
                menu.add_item("Open", "document-open-symbolic", () => {
                    if (item.is_folder) navigate_user(item.file);
                    else launch_file(item.file);
                });
                if (!item.is_folder) {
                    string? item_ctype = item.info.get_content_type();
                    if (is_archive_file(item_ctype) || is_archive_item(item)) {
                        menu.add_item(_("Open as Folder"), "folder-open-symbolic", () => {
                            open_archive_as_folder(item);
                        });
                        menu.add_item(_("Extract Here"), "package-x-generic-symbolic", () => {
                            extract_archive_here(item);
                        });
                        menu.add_item(_("Extract To…"), "folder-download-symbolic", () => {
                            extract_archive_to(widget, item);
                        });
                        menu.add_separator();
                    }
                    menu.add_item(_("Open With…"), "preferences-other-symbolic", () => {
                        GLib.Idle.add(() => {
                            FileOpener.open_with(item.file, active_window);
                            return GLib.Source.REMOVE;
                        });
                    });
                    if (is_runnable(item.file)) {
                        menu.add_item("Run as Program", "system-run-symbolic", () => {
                            run_program(item.file);
                        });
                    }
                    if (is_image_file(item)) {
                        menu.add_item("Set as Wallpaper", "preferences-desktop-wallpaper-symbolic", () => {
                            set_as_wallpaper(item);
                        });
                    }
                }
                append_plugin_file_actions(menu, item);
                Files.CloudMountActions.append_offline_item(menu, menu_target_files(item));
                if (archive_root_for(current_folder != null ? current_folder.get_path() : null) == null) {
                    menu.add_item(_("Compress…"), "package-x-generic-symbolic", () => {
                        compress_selected_files(widget);
                    });
                }
                menu.add_item("Rename", "document-edit-symbolic", () => {
                    start_inline_rename(item);
                });
                menu.add_separator();
                menu.add_item(_("Share…"), "singularity-share-symbolic", () => {
                    share_files(menu_target_files(item));
                });
                if (!menu_targets_folder(item)) {
                    menu.add_item(_("Copy Link"), "insert-link-symbolic", () => {
                        copy_link_files(menu_target_files(item));
                    });
                }
                menu.add_item("Copy", "edit-copy-symbolic", () => {
                    clipboard_set_for_menu(item, false);
                });
                menu.add_item("Cut", "edit-cut-symbolic", () => {
                    clipboard_set_for_menu(item, true);
                    if (current_folder != null) navigate_to.begin(current_folder);
                });
                menu.add_separator();
                if (Files.CloudMountActions.covers(menu_target_files(item))) {
                    menu.add_item(_("Delete…"), "edit-delete-symbolic", () => {
                        Files.CloudMountActions.confirm_delete(active_window, menu_target_files(item), () => {
                            if (current_folder != null) navigate_to.begin(current_folder);
                        });
                    });
                } else {
                    menu.add_item("Move to Trash", "user-trash-symbolic", () => {
                        try {
                            item.file.trash(null);
                            if (current_folder != null) navigate_to.begin(current_folder);
                        } catch (Error e) {
                            warning("Trash failed: %s", e.message);
                        }
                    });
                }
                if (item.is_folder) {
                    string? fpath = item.file.get_path();
                    if (fpath != null) {
                        bool bookmarked = is_bookmarked(fpath);
                        menu.add_separator();
                        menu.add_item(
                            bookmarked ? "Remove from Bookmarks" : "Add to Bookmarks",
                            bookmarked ? "user-bookmarks-symbolic" : "bookmark-new-symbolic",
                            () => {
                                if (bookmarked) remove_bookmark(fpath);
                                else add_bookmark(fpath);
                            }
                        );
                        menu.add_item(_("Save as Folder Template…"), "folder-templates-symbolic", () => {
                            save_as_folder_template(item.file);
                        });
                    }
                }
            }
            // ush integration: share this folder with Linux (shown only with ush).
            string? share_path = ush_share_target(item);
            if (share_path != null) {
                menu.add_separator();
                if (ush_is_dir_trusted(share_path)) {
                    menu.add_item("Stop sharing with Linux", "drive-harddisk-symbolic", () => {
                        ush_set_dir_shared(share_path, false);
                    });
                } else {
                    menu.add_item("Share with Linux", "drive-harddisk-symbolic", () => {
                        ush_set_dir_shared(share_path, true);
                    });
                }
            }

            menu.add_separator();
            menu.add_item("Properties", "document-properties-symbolic", () => {
                show_properties(item);
            });
            release_on_close(menu);
            menu.popup();
        }

        private void release_on_close(Popover popover) {
            popover.closed.connect(on_popover_closed);
        }

        private void on_popover_closed(Popover popover) {
            popover.closed.disconnect(on_popover_closed);
            Idle.add(() => {
                popover.unparent();
                return Source.REMOVE;
            });
        }

        private void append_plugin_file_actions(Singularity.Widgets.ContextMenu menu, FileItem item) {
            var selected = get_selected_items();
            bool in_selection = false;
            foreach (var s in selected.data) {
                if (s.file.equal(item.file)) in_selection = true;
            }
            GLib.File[] files = {};
            string?[] types = {};
            if (in_selection) {
                foreach (var t in selected.data) {
                    files += t.file;
                    types += t.info.get_content_type();
                }
            } else {
                files += item.file;
                types += item.info.get_content_type();
            }
            var actions = FilesPluginManager.get_default().actions_for(files, types);
            if (actions.length == 0) return;
            menu.add_separator();
            foreach (var action in actions) {
                var captured = action;
                GLib.File[] captured_files = files;
                menu.add_item(action.label, action.icon_name, () => captured.activate(captured_files));
            }
            menu.add_separator();
        }

        private void show_column_menu(Widget widget, double mx, double my) {
            var popover = new Popover();
            popover.set_parent(widget);
            popover.has_arrow = false;
            Gdk.Rectangle rect = { (int)mx, (int)my, 1, 1 };
            popover.set_pointing_to(rect);
            var box = new Box(Orientation.VERTICAL, 4);
            box.margin_top = 6;
            box.margin_bottom = 6;
            box.margin_start = 8;
            box.margin_end = 8;
            var lbl = new Label(_("Show columns"));
            lbl.halign = Align.START;
            lbl.add_css_class("caption");
            lbl.margin_bottom = 4;
            box.append(lbl);
            string[] col_names = { "Author", "Size", "Type", "Modified" };
            ColumnViewColumn[] cols = { col_author, col_size, col_type, col_modified };
            for (int i = 0; i < col_names.length; i++) {
                var chk = new CheckButton.with_label(col_names[i]);
                chk.active = cols[i].visible;
                int idx = i;
                chk.toggled.connect(() => { cols[idx].visible = chk.active; });
                box.append(chk);
            }
            popover.set_child(box);
            release_on_close(popover);
            popover.popup();
        }

        // ── Inline rename ──────────────────────────────────────────────────
        //
        // Swaps the row's name Label for an Entry in any view mode. Enter
        // commits, Escape cancels, focus-leave commits. If the row isn't in
        // the visible tree (scrolled off-screen, widget recycled), falls back
        // to the modal dialog.

        private FileItem? _rename_target  = null;
        private Entry?    _rename_entry   = null;
        private Label?    _rename_label   = null;
        private Box?      _rename_row_box = null;

        private void start_inline_rename(FileItem fi) {
            if (_rename_target != null) commit_inline_rename();

            string mode = settings.get_string("view-mode");
            Widget? root = null;
            if      (mode == "list")   root = (Widget) file_view;
            else if (mode == "grid")   root = (Widget) _grid_view;
            else if (mode == "column") root = (Widget) _col_browser;
            if (root == null) { show_rename_dialog(fi); return; }

            var holder = _find_widget_with_file_item(root, fi);
            if (holder == null) { show_rename_dialog(fi); return; }
            var label = _find_descendant_label(holder);
            if (label == null) { show_rename_dialog(fi); return; }
            var row_box = label.get_parent() as Box;
            if (row_box == null) { show_rename_dialog(fi); return; }

            var entry = new Entry();
            entry.text = fi.name;
            entry.hexpand = true;
            entry.add_css_class("inline-rename");

            Widget? prev = label.get_prev_sibling();
            row_box.remove(label);
            if (prev != null) row_box.insert_child_after(entry, prev);
            else              row_box.prepend(entry);

            _rename_target  = fi;
            _rename_entry   = entry;
            _rename_label   = label;
            _rename_row_box = row_box;

            int stem = Files.FolderNames.stem_length(fi.name, fi.is_folder);
            Idle.add(() => {
                entry.grab_focus_without_selecting();
                entry.select_region(0, stem);
                return false;
            });

            var key = new EventControllerKey();
            key.set_propagation_phase(PropagationPhase.CAPTURE);
            key.key_pressed.connect((kv, kc, mstate) => {
                if (kv == Gdk.Key.Return || kv == Gdk.Key.KP_Enter) {
                    commit_inline_rename();
                    return true;
                }
                if (kv == Gdk.Key.Escape) {
                    cancel_inline_rename();
                    return true;
                }
                return false;
            });
            entry.add_controller(key);

            var focus = new EventControllerFocus();
            focus.leave.connect(() => {
                if (_rename_entry == entry) commit_inline_rename();
            });
            entry.add_controller(focus);
        }

        private void commit_inline_rename() {
            var entry = _rename_entry;
            var fi    = _rename_target;
            if (entry == null || fi == null) return;
            string new_name = entry.text.strip();
            _restore_inline_label();
            if (new_name != "" && new_name != fi.name) {
                try {
                    fi.file.set_display_name(new_name, null);
                    if (current_folder != null) navigate_to.begin(current_folder);
                } catch (Error e) {
                    warning("Inline rename failed: %s", e.message);
                }
            }
        }

        private void cancel_inline_rename() {
            _restore_inline_label();
        }

        private void _restore_inline_label() {
            if (_rename_entry != null && _rename_label != null && _rename_row_box != null) {
                Widget? prev = _rename_entry.get_prev_sibling();
                _rename_row_box.remove(_rename_entry);
                if (prev != null) _rename_row_box.insert_child_after(_rename_label, prev);
                else              _rename_row_box.prepend(_rename_label);
            }
            _rename_entry   = null;
            _rename_label   = null;
            _rename_row_box = null;
            _rename_target  = null;
        }

        // Walk column panes from the rightmost backwards looking for a
        // selected row, return its FileItem. Returns null in non-column
        // mode or when nothing is selected.
        private FileItem? _column_selected_item() {
            if (_col_browser == null) return null;
            string mode = settings.get_string("view-mode");
            if (mode != "column") return null;
            for (int i = _col_browser.pane_count - 1; i >= 0; i--) {
                var pane = _col_browser.get_pane(i);
                if (pane == null) continue;
                var sel = pane.list_box.get_selected_row();
                if (sel != null) {
                    var fi = sel.get_data<FileItem>("col-file-item");
                    if (fi != null) return fi;
                }
            }
            return null;
        }

        private void _update_file_count_label() {
            if (_file_count_lbl == null || file_store == null) return;
            uint n = file_store.get_n_items();
            _file_count_lbl.label = (n == 1)
                ? "1 item"
                : "%u items".printf(n);
        }

        private Widget? _find_widget_with_file_item(Widget w, FileItem target) {
            // Column and list/grid build separate FileItem instances for the
            // same file, so compare by URI to match a target across views.
            string target_uri = target.file.get_uri();
            var a = w.get_data<FileItem>("file-item");
            if (a != null && a.file.get_uri() == target_uri) return w;
            var b = w.get_data<FileItem>("col-file-item");
            if (b != null && b.file.get_uri() == target_uri) return w;
            Widget? c = w.get_first_child();
            while (c != null) {
                var found = _find_widget_with_file_item(c, target);
                if (found != null) return found;
                c = c.get_next_sibling();
            }
            return null;
        }

        private Label? _find_descendant_label(Widget w) {
            if (w is Label) return (Label) w;
            Widget? c = w.get_first_child();
            while (c != null) {
                var l = _find_descendant_label(c);
                if (l != null) return l;
                c = c.get_next_sibling();
            }
            return null;
        }

        private void show_rename_dialog(FileItem item) {
            var dialog = new Singularity.Widgets.AppDialog((Gtk.Application) this, true);
            dialog.set_title(item.is_folder ? _("Rename Folder") : _("Rename File"));
            dialog.transient_for = (Gtk.Window) file_view.get_root();
            dialog.set_default_size(440, -1);
            dialog.resizable = false;
            var parent = item.file.get_parent();

            var body = new Box(Orientation.VERTICAL, 6);
            body.margin_start = body.margin_end = 24;
            body.margin_top = 6;
            body.margin_bottom = 8;

            var entry = new Entry();
            entry.text = item.name;
            entry.hexpand = true;
            Singularity.Widgets.ContextMenu.attach_editable(entry);
            body.append(entry);

            var message = new Box(Orientation.HORIZONTAL, 6);
            message.height_request = 20;
            var message_icon = new Image();
            message_icon.pixel_size = 16;
            message.append(message_icon);
            var message_label = new Label("");
            message_label.xalign = 0;
            message_label.wrap = true;
            message_label.hexpand = true;
            message_label.add_css_class("caption");
            message.append(message_label);
            body.append(message);
            dialog.content_box.append(body);

            var bar = new Box(Orientation.HORIZONTAL, 8);
            bar.margin_start = bar.margin_end = 18;
            bar.margin_bottom = 16;
            bar.margin_top = 4;
            bar.halign = Align.END;
            bar.append(dialog.add_cancel_button());
            var ok_btn = new Button.with_label(_("Rename"));
            ok_btn.add_css_class("suggested-action");
            bar.append(ok_btn);
            dialog.content_box.append(bar);
            dialog.default_widget = ok_btn;

            Files.NameLookup lookup = (n) => {
                if (n == item.name || parent == null) return FileType.UNKNOWN;
                return Files.FolderNames.lookup_in(parent, n);
            };
            entry.changed.connect(() => {
                var state = Files.FolderNames.check(entry.text, lookup);
                bool error = state.blocks() && state != Files.NameState.EMPTY;
                message_label.label = Files.FolderNames.message(state, entry.text);
                message_icon.visible = message_label.label != "";
                message_icon.icon_name = error ? "dialog-error-symbolic" : "dialog-information-symbolic";
                foreach (var w in new Widget[] { message_label, message_icon, entry }) {
                    w.remove_css_class("error");
                    w.remove_css_class("dim-label");
                }
                message_label.add_css_class(error ? "error" : "dim-label");
                message_icon.add_css_class(error ? "error" : "dim-label");
                if (error) entry.add_css_class("error");
                ok_btn.sensitive = !state.blocks();
            });
            ok_btn.clicked.connect(() => {
                if (Files.FolderNames.check(entry.text, lookup).blocks()) return;
                string new_name = entry.text.strip();
                if (new_name != item.name) {
                    try {
                        item.file.set_display_name(new_name, null);
                        if (current_folder != null) navigate_to.begin(current_folder);
                    } catch (Error e) {
                        message_label.label = e.message;
                        message_label.remove_css_class("dim-label");
                        message_label.add_css_class("error");
                        message_icon.icon_name = "dialog-error-symbolic";
                        message_icon.visible = true;
                        return;
                    }
                }
                dialog.close();
            });
            entry.activate.connect(() => ok_btn.clicked());
            entry.changed();

            dialog.present();
            entry.grab_focus();
            entry.select_region(0, Files.FolderNames.stem_length(item.name, item.is_folder));
        }

        private void trigger_preview(string uri) {
            const int PREVIEW_NEIGHBOURS = 500;
            int position = -1;
            uint n = file_store.get_n_items();
            for (uint i = 0; i < n; i++) {
                var item = (FileItem) file_store.get_item(i);
                if (item.file.get_uri() == uri) {
                    position = (int) i;
                    break;
                }
            }
            string[] uris = {};
            int index = 0;
            if (position < 0) {
                uris += uri;
            } else {
                int first = int.max(0, position - PREVIEW_NEIGHBOURS);
                int last = int.min((int) n - 1, position + PREVIEW_NEIGHBOURS);
                for (int i = first; i <= last; i++) {
                    uris += ((FileItem) file_store.get_item(i)).file.get_uri();
                }
                index = position - first;
            }
            try {
                var preview = Bus.get_proxy_sync<PreviewService>(BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/shell/Preview");
                try {
                    preview.show_previews(uris, index, "dev.sinty.files");
                } catch (DBusError.UNKNOWN_METHOD e) {
                    preview.show_preview(uri);
                }
            } catch (Error e) {
                warning("Failed to trigger preview: %s", e.message);
            }
        }

        // Walk all visible GridView cell widgets and update icon pixel_size in-place.
        private void apply_grid_icon_size() {
            if (_grid_view == null) return;
            var cell = _grid_view.get_first_child();
            while (cell != null) {
                var box_widget = cell.get_first_child();
                if (box_widget is Box) {
                    var img = ((Box)box_widget).get_data<Image>("thumb-img");
                    if (img != null) img.pixel_size = grid_icon_size;
                }
                cell = cell.get_next_sibling();
            }
        }

        private GenericArray<FileItem> get_selected_items() {
            var result = new GenericArray<FileItem>();
            var selection_model = file_view.model as SelectionModel;
            if (selection_model == null) return result;

            var bitset = selection_model.get_selection();
            if (bitset.is_empty()) return result;

            var iter = new BitsetIter();
            uint index;
            if (iter.init_first(bitset, out index)) {
                do {
                    var item = file_store.get_item(index) as FileItem;
                    if (item != null) result.add(item);
                } while (iter.next(out index));
            }
            return result;
        }

        private void on_item_activated(uint position) {
            var file_item = (FileItem)file_store.get_item(position);
            // Virtual "Connect to Server" item in the Network page
            if (file_item.file.get_uri() == "x-singularity://connect-to-server") {
                show_connect_to_server_dialog();
                return;
            }
            if (file_item.info.get_file_type() == FileType.DIRECTORY) {
                navigate_user(file_item.file);
                if (save_mode && filename_entry != null) {
                    filename_entry.grab_focus();
                }
                return;
            }
            if (picker_mode) {
                // In picker mode double-clicking a file submits it directly
                if (!save_mode) {
                    submit_picker_selection();
                } else if (filename_entry != null) {
                    filename_entry.text = file_item.name;
                    filename_entry.grab_focus();
                }
                return;
            }
            // Open archives as browsable folders by extracting to a temp dir
            if (is_archive_item(file_item)) {
                open_archive_as_folder(file_item);
                return;
            }
            launch_file(file_item.file);
        }

        private void submit_picker_selection() {
            string uri = "";
            var selected = get_selected_items();

            if (save_mode && filename_entry != null && filename_entry.text.strip() != "") {
                // Build URI from current folder + typed filename
                string fname = filename_entry.text.strip();
                if (current_folder != null) {
                    uri = current_folder.get_child(fname).get_uri();
                }
            } else if (selected.length > 0) {
                var uris = new StringBuilder();
                for (int i = 0; i < selected.length; i++) {
                    var item = selected.get(i);
                    bool is_dir = item.info.get_file_type() == FileType.DIRECTORY;
                    if (is_dir == directory_mode) {
                        if (uris.len > 0) uris.append("\n");
                        uris.append(item.file.get_uri());
                        if (!multiple_mode) break;
                    }
                }
                uri = uris.str;
            } else if (_picker_selected_file != null) {
                // Column-browser selection (file_view's get_selected_items()
                // doesn't see it - we tracked it separately on row activate).
                bool is_dir = _picker_selected_info != null
                    && _picker_selected_info.get_file_type() == FileType.DIRECTORY;
                if (is_dir == directory_mode) {
                    uri = _picker_selected_file.get_uri();
                }
            }

            if (uri == "" && directory_mode && current_folder != null) {
                uri = current_folder.get_uri();
            }

            if (portal_mode) {
                string? result_file = Environment.get_variable("SINGULARITY_PORTAL_RESULT_FILE");
                if (result_file != null && uri != "") {
                    try {
                        FileUtils.set_contents(result_file, uri + "\n");
                    } catch (Error e) {
                        warning("Failed to write portal result: %s", e.message);
                    }
                }
                if (active_window != null) active_window.close();
                quit();
            } else {
                if (uri != "") print("%s\n", uri);
                if (active_window != null) active_window.close();
            }
        }

        private string get_bookmarks_file_path() {
            string our_dir  = GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".config", "singularity");
            string our_file = GLib.Path.build_filename(our_dir, "bookmarks");
            if (!GLib.FileUtils.test(our_file, GLib.FileTest.EXISTS)) {
                string gtk_file = GLib.Path.build_filename(
                    GLib.Environment.get_home_dir(), ".config", "gtk-3.0", "bookmarks");
                if (GLib.FileUtils.test(gtk_file, GLib.FileTest.EXISTS)) {
                    string contents = "";
                    try { GLib.FileUtils.get_contents(gtk_file, out contents); } catch {}
                    if (contents != "") {
                        GLib.DirUtils.create_with_parents(our_dir, 0755);
                        try { GLib.FileUtils.set_contents(our_file, contents); } catch {}
                    }
                }
            }
            return our_file;
        }

        private Bookmark[] load_gtk_bookmarks() {
            Bookmark[] result = {};
            string bm_file = get_bookmarks_file_path();
            try {
                string contents;
                GLib.FileUtils.get_contents(bm_file, out contents);
                foreach (string raw_line in contents.split("\n")) {
                    string line = raw_line.strip();
                    if (line == "") continue;
                    string[] parts = line.split(" ", 2);
                    string uri = parts[0];
                    if (!uri.has_prefix("file://")) continue;
                    try {
                        string path = GLib.Filename.from_uri(uri);
                        if (!GLib.FileUtils.test(path, GLib.FileTest.IS_DIR)) continue;
                        string label = (parts.length > 1 && parts[1].strip() != "")
                            ? parts[1].strip()
                            : GLib.Path.get_basename(path);
                        result += Bookmark() { path = path, label = label };
                    } catch {}
                }
            } catch {}
            return result;
        }

        public void add_bookmark(string path) {
            string bm_file = get_bookmarks_file_path();
            try {
                string uri = GLib.Filename.to_uri(path);
                string existing = "";
                try { GLib.FileUtils.get_contents(bm_file, out existing); } catch {}
                if (existing.contains(uri)) return;
                string label = GLib.Path.get_basename(path);
                GLib.DirUtils.create_with_parents(GLib.Path.get_dirname(bm_file), 0755);
                GLib.FileUtils.set_contents(bm_file, existing + "%s %s\n".printf(uri, label));
            } catch (Error e) { warning("add_bookmark: %s", e.message); }
        }

        public void remove_bookmark(string path) {
            string bm_file = get_bookmarks_file_path();
            try {
                string uri = GLib.Filename.to_uri(path);
                string existing = "";
                try { GLib.FileUtils.get_contents(bm_file, out existing); } catch {}
                var lines = new GLib.StringBuilder();
                foreach (string raw in existing.split("\n")) {
                    if (raw.strip() == "" || raw.strip().has_prefix(uri)) continue;
                    lines.append(raw + "\n");
                }
                GLib.FileUtils.set_contents(bm_file, lines.str);
            } catch (Error e) { warning("remove_bookmark: %s", e.message); }
        }

        public bool is_bookmarked(string path) {
            string bm_file = get_bookmarks_file_path();
            string existing = "";
            try { GLib.FileUtils.get_contents(bm_file, out existing); } catch {}
            try { return existing.contains(GLib.Filename.to_uri(path)); } catch { return false; }
        }

        private void rebuild_bookmarks_section() {
            if (_bookmarks_section == null) return;
            Gtk.Widget? child = _bookmarks_section.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                _bookmarks_section.remove(child);
                child = next;
            }
            var bookmarks = load_gtk_bookmarks();
            int shown_bookmarks = 0;
            foreach (var bm in bookmarks) {
                if (picker_mode || !Files.CloudLocations.is_cloud_path(bm.path)) shown_bookmarks++;
            }
            if (shown_bookmarks > 0) {
                _bookmarks_section.append(new Separator(Orientation.HORIZONTAL));
                _bookmarks_section.append(new Singularity.Widgets.SidebarSectionLabel("Bookmarks"));
                foreach (var bm in bookmarks) {
                    if (!picker_mode && Files.CloudLocations.is_cloud_path(bm.path)) continue;
                    add_bookmark_button(_bookmarks_section, bm.label, bm.path);
                }
            }
        }

        // Sidebar bookmark button with right-click context menu (remove bookmark).
        private void add_bookmark_button(Box box, string name, string path) {
            var btn = new Button();
            btn.halign = Align.FILL;
            btn.has_frame = false;
            var row = new Box(Orientation.HORIZONTAL, 12);
            var img = new Image.from_icon_name("folder-symbolic");
            img.pixel_size = 16;
            row.append(img);
            row.append(new Label(name));
            btn.set_child(row);
            btn.clicked.connect(() => {
                navigate_user(File.new_for_path(path));
            });
            // Right-click: remove from bookmarks
            var gesture = new GestureClick();
            gesture.button = 3;
            gesture.pressed.connect((n, x, y) => {
                var menu = new Singularity.Widgets.ContextMenu(btn);
                Gdk.Rectangle rect = { (int)x, (int)y, 1, 1 };
                menu.set_pointing_to(rect);
                menu.add_item("Remove Bookmark", "list-remove-symbolic", () => {
                    remove_bookmark(path);
                });
                release_on_close(menu);
                menu.popup();
                gesture.set_state(EventSequenceState.CLAIMED);
            });
            btn.add_controller(gesture);
            add_sidebar_folder_drop(btn, path);
            box.append(btn);
        }

        private void rebuild_devices_section() {
            if (_devices_section == null) return;
            Gtk.Widget? child = _devices_section.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                _devices_section.remove(child);
                child = next;
            }

            _devices_section.append(new Separator(Orientation.HORIZONTAL));
            _devices_section.append(new Singularity.Widgets.SidebarSectionLabel("Devices"));

            // Single "Disks" entry - opens the dedicated disks page
            var disks_btn = new Button();
            disks_btn.add_css_class("flat");
            var disks_row = new Box(Orientation.HORIZONTAL, 8);
            var disks_img = new Image.from_icon_name("drive-multidisk-symbolic");
            disks_img.pixel_size = 16;
            disks_row.append(disks_img);
            disks_row.append(new Label(_("Disks")));
            disks_btn.set_child(disks_row);
            disks_btn.clicked.connect(show_disks_page);
            _disks_sidebar_btn = disks_btn;
            _devices_section.append(disks_btn);
        }

        private void rebuild_picker_devices_section() {
            if (_picker_devices_section == null) return;
            Gtk.Widget? child = _picker_devices_section.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                _picker_devices_section.remove(child);
                child = next;
            }
            bool any = false;
            enumerate_storage((name, icon, path, volume) => {
                if (!any) {
                    _picker_devices_section.append(new Separator(Orientation.HORIZONTAL));
                    _picker_devices_section.append(new Singularity.Widgets.SidebarSectionLabel(_("Devices")));
                    any = true;
                }
                if (path != null) {
                    add_disk_button(_picker_devices_section, name, path, icon);
                } else if (volume != null) {
                    var btn = new Singularity.Widgets.SidebarRow(icon, name);
                    btn.clicked.connect(() => mount_volume_and_navigate(volume));
                    _picker_devices_section.append(btn);
                }
            });
        }

        // Disk button with async space bar showing used/total.
        private void add_disk_button(Box box, string name, string path, string icon) {
            var btn = new Button();
            btn.halign = Align.FILL;
            btn.has_frame = false;
            var outer = new Box(Orientation.VERTICAL, 2);
            outer.margin_top = 2;
            outer.margin_bottom = 2;
            var row = new Box(Orientation.HORIZONTAL, 8);
            var img = new Image.from_icon_name(icon);
            img.pixel_size = 16;
            row.append(img);
            var lbl = new Label(name);
            lbl.hexpand = true;
            lbl.xalign = 0f;
            lbl.ellipsize = Pango.EllipsizeMode.END;
            row.append(lbl);
            outer.append(row);
            // Space bar (initially hidden, shown once we have size info)
            var bar = new LevelBar();
            bar.min_value = 0;
            bar.max_value = 1;
            bar.value = 0;
            bar.margin_start = 24;
            bar.margin_end = 4;
            bar.add_css_class("disk-usage-bar");
            bar.visible = false;
            outer.append(bar);
            btn.set_child(outer);
            btn.clicked.connect(() => {
                navigate_user(File.new_for_path(path));
            });
            box.append(btn);
            // Async: query filesystem size/free
            var f = File.new_for_path(path);
            f.query_filesystem_info_async.begin("filesystem::size,filesystem::free",
                Priority.DEFAULT, null, (obj, res) => {
                    try {
                        var info = f.query_filesystem_info_async.end(res);
                        uint64 total = info.get_attribute_uint64("filesystem::size");
                        uint64 free_b = info.get_attribute_uint64("filesystem::free");
                        if (total > 0) {
                            double used_frac = (double)(total - free_b) / (double)total;
                            bar.value = used_frac;
                            bar.visible = true;
                            // Color: >90% red, >75% yellow, else default
                            if (used_frac > 0.9) {
                                bar.remove_css_class("disk-usage-moderate");
                                bar.add_css_class("disk-usage-high");
                            } else if (used_frac > 0.75) {
                                bar.remove_css_class("disk-usage-high");
                                bar.add_css_class("disk-usage-moderate");
                            }
                        }
                    } catch {}
                });
        }

        private void setup_bookmarks_file_monitor() {
            // Ensure our bookmarks dir/file exists so monitor can watch it
            string bm_path = get_bookmarks_file_path();
            var dir = GLib.File.new_for_path(GLib.Path.get_dirname(bm_path));
            if (!dir.query_exists()) {
                try { dir.make_directory_with_parents(); } catch {}
            }
            var bm_file = GLib.File.new_for_path(bm_path);
            try {
                _bookmarks_file_monitor = bm_file.monitor_file(GLib.FileMonitorFlags.NONE, null);
                _bookmarks_file_monitor.changed.connect((f, of, event) => {
                    if (event == GLib.FileMonitorEvent.CHANGES_DONE_HINT ||
                        event == GLib.FileMonitorEvent.CREATED ||
                        event == GLib.FileMonitorEvent.DELETED) {
                        rebuild_bookmarks_section();
                    }
                });
            } catch (Error e) {
                warning("Failed to monitor bookmarks file: %s", e.message);
            }
        }

        private FileItem connect_server_item() {
            var info = new GLib.FileInfo();
            info.set_name(_("Connect to Server"));
            info.set_display_name(_("Connect to Server"));
            info.set_file_type(GLib.FileType.UNKNOWN);
            info.set_icon(new GLib.ThemedIcon("network-server"));
            return new FileItem(GLib.File.new_for_uri("x-singularity://connect-to-server"), info);
        }

        private void show_connect_to_server_dialog() {
            var dialog = new ConnectToServerDialog((Gtk.Application)this);
            if (active_window != null) dialog.transient_for = active_window;
            dialog.present();
            dialog.connect_requested.connect((uri) => {
                clear_search();
                navigate_to_uri(uri);
            });
        }

        private void add_place_button(Box box, string name, string? path, string icon) {
            if (path == null) return;
            var btn = new Singularity.Widgets.SidebarRow(icon, name);
            // Normalize key: use uri string for uri paths, absolute path for local dirs
            string key = path.contains("://") ? path : File.new_for_path(path).get_uri();
            _place_buttons[key] = btn;
            btn.clicked.connect(() => {
                if (path.contains("://")) {
                    clear_search();
                    navigate_to_uri(path);
                } else {
                    navigate_user(File.new_for_path(path));
                }
            });
            if (!path.contains("://")) add_sidebar_folder_drop(btn, path);
            box.append(btn);
        }

        private void add_sidebar_folder_drop(Widget widget, string destination_path) {
            var destination = File.new_for_path(destination_path);
            var drop = new DropTarget(typeof(Gdk.FileList),
                Gdk.DragAction.COPY | Gdk.DragAction.MOVE);
            unowned DropTarget drop_ref = drop;
            drop.set_gtypes({ typeof(Gdk.FileList), typeof(GLib.File), typeof(string) });
            drop.drop.connect((value, x, y) => {
                var sources = new Gee.ArrayList<GLib.File>();
                if (value.holds(typeof(Gdk.FileList))) {
                    var files = (Gdk.FileList) value.get_boxed();
                    foreach (unowned GLib.File file in files.get_files()) sources.add(file);
                } else if (value.holds(typeof(GLib.File))) {
                    var file = (GLib.File) value.get_object();
                    if (file != null) sources.add(file);
                } else if (value.holds(typeof(string))) {
                    foreach (string line in value.get_string().split("\n")) {
                        string uri = line.strip();
                        if (uri.has_prefix("file://")) sources.add(File.new_for_uri(uri));
                        else if (uri.has_prefix("/")) sources.add(File.new_for_path(uri));
                    }
                }
                if (sources.size == 0 || destination.get_path() == null ||
                    destination.query_file_type(FileQueryInfoFlags.NONE) != FileType.DIRECTORY)
                    return false;
                foreach (var source in sources) {
                    var parent = source.get_parent();
                    if (source.get_path() == null || source.equal(destination) ||
                        (parent != null && parent.equal(destination))) return false;
                }
                bool move = false;
                var current_drop = drop_ref.get_current_drop();
                if (current_drop != null) {
                    var drag = current_drop.get_drag();
                    move = drag != null && drag.get_selected_action() == Gdk.DragAction.MOVE;
                }
                ensure_ops_manager();
                var op = _ops.start_transfer(sources.to_array(), destination, move);
                op.completed.connect(() => {
                    if (current_folder != null) navigate_to.begin(current_folder);
                });
                return true;
            });
            widget.add_controller(drop);
        }

        // Highlight the sidebar button whose path is the closest ancestor of (or equal to) `folder`.
        private void sync_sidebar_active(File folder) {
            if (_cloud_view != null) {
                _cloud_view.locations.sync_active_path(folder);
                if (_cloud_view.locations.active_id != "") {
                    foreach (var entry in _place_buttons.entries) entry.value.remove_css_class("sidebar-nav-active");
                    if (_disks_sidebar_btn != null) _disks_sidebar_btn.remove_css_class("sidebar-nav-active");
                    return;
                }
            }
            string current_uri = folder.get_uri();
            string best_key = "";
            int best_len = -1;
            foreach (var entry in _place_buttons.entries) {
                string k = entry.key;
                // Normalize for prefix comparison: ensure trailing slash
                string k_slash = k.has_suffix("/") ? k : k + "/";
                string cur_slash = current_uri.has_suffix("/") ? current_uri : current_uri + "/";
                if (cur_slash == k_slash || cur_slash.has_prefix(k_slash)) {
                    if (k.length > best_len) {
                        best_len = k.length;
                        best_key = k;
                    }
                }
            }
            foreach (var entry in _place_buttons.entries) {
                var b = entry.value;
                if (entry.key == best_key) {
                    b.add_css_class("sidebar-nav-active");
                } else {
                    b.remove_css_class("sidebar-nav-active");
                }
            }
            if (_disks_sidebar_btn != null) _disks_sidebar_btn.remove_css_class("sidebar-nav-active");
        }

        private void mark_disks_sidebar_active() {
            foreach (var entry in _place_buttons.entries)
                entry.value.remove_css_class("sidebar-nav-active");
            if (_disks_sidebar_btn != null) _disks_sidebar_btn.add_css_class("sidebar-nav-active");
        }

        private void clear_search() {
            if (current_search == "" &&
                (path_bar_stack == null || path_bar_stack.visible_child_name != "search")) return;
            current_search = "";
            if (search_entry_widget != null) search_entry_widget.text = "";
            if (path_bar_stack != null) path_bar_stack.visible_child_name = "bar";
        }

        private void update_nav_buttons() {
            if (back_btn != null) back_btn.visible = nav_index > 0;
            if (fwd_btn != null)  fwd_btn.visible  = nav_index < (int)nav_history.length - 1;
            if (swipe_nav != null) {
                swipe_nav.can_go_back = nav_index > 0;
                swipe_nav.can_go_forward = nav_index < (int)nav_history.length - 1;
            }
            update_menu_actions();
        }

        private void go_back() {
            if (nav_index <= 0) return;
            nav_index--;
            update_nav_buttons();
            navigate_to.begin(nav_history[nav_index]);
        }

        private void go_forward() {
            if (nav_index >= (int)nav_history.length - 1) return;
            nav_index++;
            update_nav_buttons();
            navigate_to.begin(nav_history[nav_index]);
        }

        private void navigate_user(File folder) {
            clear_search();
            // Truncate any forward history past the current position
            if (nav_index < (int)nav_history.length - 1)
                nav_history = nav_history[0:nav_index + 1];
            nav_history += folder;
            nav_index = (int)nav_history.length - 1;
            update_nav_buttons();
            navigate_to.begin(folder);
        }

        private Label make_path_separator() {
            var sep = new Label("/");
            sep.add_css_class("path-separator");
            return sep;
        }

        private void update_path_bar(File folder) {
            Widget child = path_bar.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                path_bar.remove(child);
                child = next;
            }
            string? archive_root = archive_root_for(folder.get_path());
            if (archive_root != null) {
                update_archive_path_bar(folder, archive_root);
                return;
            }
            string furi = folder.get_uri();
            if (furi.has_prefix("trash://")) {
                _append_path_root("user-trash-symbolic", "Trash", () => {
                    navigate_to_uri("trash://");
                });
                return;
            }
            if (furi.has_prefix("smb://")) {
                _append_path_root("network-workgroup-symbolic", "Network", () => {
                    navigate_to_uri("smb://");
                });
                return;
            }
            var path = folder.get_path();
            if (path == null) {
                _append_path_root("folder-symbolic", furi, () => {});
                return;
            }
            string home_dir = Environment.get_home_dir();
            bool in_home = (path == home_dir || path.has_prefix(home_dir + "/"));

            // Smart truncation against a fixed char budget: first collapse
            // segments to `home/../tailN`, then ellipsize per-segment labels.
            const int PATH_CHAR_BUDGET = 32;
            const int SEG_MAX_CHARS    = 14;

            if (in_home) {
                string rel = (path == home_dir) ? "" : path.substring(home_dir.length + 1);
                string[] rel_segs = (rel == "") ? new string[]{} : rel.split("/");

                // At the home root, show the user's display name beside the icon.
                string home_target = home_dir;
                var home_btn = new Button.from_icon_name("user-home-symbolic");
                home_btn.tooltip_text = _("Home");
                home_btn.add_css_class("flat");
                home_btn.add_css_class("path-button");
                home_btn.clicked.connect(() => navigate_user(File.new_for_path(home_target)));
                path_bar.append(home_btn);
                if (rel_segs.length == 0) {
                    string uname = Environment.get_real_name();
                    if (uname == null || uname == "" || uname == "Unknown")
                        uname = Environment.get_user_name();
                    if (uname != null && uname != "") {
                        var name_btn = new Button.with_label(uname);
                        name_btn.add_css_class("flat");
                        name_btn.add_css_class("path-button");
                        var lbl = name_btn.get_child() as Label;
                        if (lbl != null) {
                            lbl.ellipsize       = Pango.EllipsizeMode.END;
                            lbl.max_width_chars = 14;
                        }
                        name_btn.clicked.connect(() => navigate_user(File.new_for_path(home_target)));
                        path_bar.append(name_btn);
                    }
                    return;
                }

                int total_chars = 0;
                foreach (string s in rel_segs) total_chars += s.length + 1;
                bool truncate = rel_segs.length > 3 || total_chars > PATH_CHAR_BUDGET;
                int tail_n = 2;
                int start_idx = truncate ? int.max(0, rel_segs.length - tail_n) : 0;
                if (truncate) {
                    path_bar.append(make_path_separator());
                    var ellipsis = new Label("..");
                    ellipsis.add_css_class("dim-label");
                    path_bar.append(ellipsis);
                }
                for (int i = start_idx; i < rel_segs.length; i++) {
                    string seg_path = home_dir;
                    for (int j = 0; j <= i; j++) seg_path += "/" + rel_segs[j];
                    string target = seg_path;
                    path_bar.append(make_path_separator());
                    var btn = new Button.with_label(rel_segs[i]);
                    btn.add_css_class("flat");
                    btn.add_css_class("path-button");
                    var lbl = btn.get_child() as Label;
                    if (lbl != null) {
                        lbl.ellipsize       = Pango.EllipsizeMode.END;
                        lbl.max_width_chars = SEG_MAX_CHARS;
                    }
                    btn.clicked.connect(() => navigate_user(File.new_for_path(target)));
                    path_bar.append(btn);
                }
            } else {
                // Outside home: show / + segments with the same truncation rule.
                var all_parts = new GLib.Array<string>();
                var all_paths = new GLib.Array<string>();
                string cp = "";
                foreach (string part in path.split("/")) {
                    if (part == "") { cp = "/"; continue; }
                    cp = (cp == "/") ? "/" + part : cp + "/" + part;
                    all_parts.append_val(part);
                    all_paths.append_val(cp);
                }
                int total_chars = 0;
                for (int i = 0; i < (int)all_parts.length; i++) total_chars += all_parts.index(i).length + 1;
                bool truncate = all_parts.length > 3 || total_chars > PATH_CHAR_BUDGET;

                string root_target = "/";
                var root_btn = new Button.with_label("/");
                root_btn.add_css_class("flat");
                root_btn.add_css_class("path-button");
                root_btn.clicked.connect(() => navigate_user(File.new_for_path(root_target)));
                path_bar.append(root_btn);

                int tail_n = 2;
                int start_idx = truncate ? int.max(0, (int)all_parts.length - tail_n) : 0;
                if (truncate) {
                    path_bar.append(make_path_separator());
                    var ellipsis = new Label("..");
                    ellipsis.add_css_class("dim-label");
                    path_bar.append(ellipsis);
                }
                for (int i = start_idx; i < (int)all_parts.length; i++) {
                    string target = all_paths.index(i);
                    path_bar.append(make_path_separator());
                    var btn = new Button.with_label(all_parts.index(i));
                    btn.add_css_class("flat");
                    btn.add_css_class("path-button");
                    var lbl = btn.get_child() as Label;
                    if (lbl != null) {
                        lbl.ellipsize       = Pango.EllipsizeMode.END;
                        lbl.max_width_chars = SEG_MAX_CHARS;
                    }
                    btn.clicked.connect(() => navigate_user(File.new_for_path(target)));
                    path_bar.append(btn);
                }
            }
        }

        private void update_archive_path_bar(File folder, string root) {
            string archive = _archive_views.get(root);
            string root_target = root;
            var root_btn = new Button();
            var root_box = new Box(Orientation.HORIZONTAL, 6);
            root_box.append(new Image.from_icon_name("package-x-generic-symbolic"));
            var root_lbl = new Label(GLib.Path.get_basename(archive));
            root_lbl.ellipsize = Pango.EllipsizeMode.MIDDLE;
            root_lbl.max_width_chars = 18;
            root_box.append(root_lbl);
            root_btn.child = root_box;
            root_btn.tooltip_text = archive;
            root_btn.add_css_class("flat");
            root_btn.add_css_class("path-button");
            root_btn.clicked.connect(() => navigate_user(File.new_for_path(root_target)));
            path_bar.append(root_btn);
            string path = folder.get_path() ?? root;
            if (path == root) return;
            string[] segs = path.substring(root.length + 1).split("/");
            int start = segs.length > 3 ? segs.length - 2 : 0;
            if (start > 0) {
                path_bar.append(make_path_separator());
                var ellipsis = new Label("..");
                ellipsis.add_css_class("dim-label");
                path_bar.append(ellipsis);
            }
            for (int i = start; i < segs.length; i++) {
                string target = root;
                for (int j = 0; j <= i; j++) target += "/" + segs[j];
                path_bar.append(make_path_separator());
                var btn = new Button.with_label(segs[i]);
                btn.add_css_class("flat");
                btn.add_css_class("path-button");
                var lbl = btn.get_child() as Label;
                if (lbl != null) {
                    lbl.ellipsize = Pango.EllipsizeMode.END;
                    lbl.max_width_chars = 14;
                }
                btn.clicked.connect(() => navigate_user(File.new_for_path(target)));
                path_bar.append(btn);
            }
        }

        private void sync_archive_banner(File folder) {
            if (_archive_banner == null) return;
            string? root = archive_root_for(folder.get_path());
            if (root == null) {
                _archive_banner.visible = false;
                return;
            }
            _archive_banner.title = _("You are looking inside \"%s\". Its contents are read only until you extract them.").printf(
                GLib.Path.get_basename(_archive_views.get(root)));
            _archive_banner.visible = true;
        }

        private void update_path_completions() {
            if (path_completion_list == null || path_completion_popover == null) return;
            // Clear existing rows
            ListBoxRow? r = path_completion_list.get_row_at_index(0);
            while (r != null) {
                path_completion_list.remove(r);
                r = path_completion_list.get_row_at_index(0);
            }
            string text = path_entry_widget.text;
            if (text.has_prefix("~/")) {
                text = Environment.get_home_dir() + text.substring(1);
            } else if (text == "~") {
                text = Environment.get_home_dir();
            }
            if (text.length < 1) { path_completion_popover.popdown(); return; }
            // Split into dir part and prefix
            int last_slash = text.last_index_of_char('/');
            string dir_path = last_slash >= 0 ? text.substring(0, last_slash + 1) : "/";
            string prefix = last_slash >= 0 ? text.substring(last_slash + 1) : text;
            if (dir_path == "") dir_path = "/";
            var dir = File.new_for_path(dir_path);
            if (!dir.query_exists(null)) { path_completion_popover.popdown(); return; }
            try {
                var enumerator = dir.enumerate_children("standard::name,standard::type", FileQueryInfoFlags.NONE, null);
                int count = 0;
                FileInfo? info;
                while ((info = enumerator.next_file(null)) != null && count < 12) {
                    string name = info.get_name();
                    if (info.get_file_type() == FileType.DIRECTORY &&
                        (prefix == "" || name.has_prefix(prefix))) {
                        string full_path = dir_path + name;
                        var lrow = new ListBoxRow();
                        lrow.set_data<string>("path-completion", full_path);
                        var lbl = new Label(full_path);
                        lbl.halign = Align.START;
                        lbl.hexpand = true;
                        lbl.ellipsize = Pango.EllipsizeMode.START;
                        lbl.margin_start = 8;
                        lbl.margin_end = 8;
                        lbl.margin_top = 3;
                        lbl.margin_bottom = 3;
                        lrow.set_child(lbl);
                        path_completion_list.append(lrow);
                        count++;
                    }
                }
                if (count > 0) path_completion_popover.popup();
                else path_completion_popover.popdown();
            } catch (Error e) {
                path_completion_popover.popdown();
            }
        }

        /**
         * After populating file_store for a "special" URI (recent://, smb://),
         * switch the view stack to match the user's current view-mode. In
         * column mode this means rebuilding the first column too - since
         * those URIs don't enumerate via the generic FileEnumerator and need
         * to flow through their custom FileProvider in fill_column_pane.
         */
        private void sync_after_special_uri(File folder) {
            if (view_stack_ref == null) return;
            string mode = settings.get_string("view-mode");
            if (mode == "column") {
                view_stack_ref.visible_child_name = "column";
                if (_col_browser != null) _col_browser.clear();
                _col_folders = {};
                _col_count = 0;
                load_column_pane(0, folder);
            } else {
                view_stack_ref.visible_child_name = (mode == "grid") ? "grid" : "list";
            }
        }

        private void navigate_to_uri(string uri) {
            clear_search();
            if (uri == "recent://") {
                var provider = new RecentProvider();
                provider.enumerate.begin(uri, null, (obj, res) => {
                    try {
                        var items = provider.enumerate.end(res);
                        Object[] objects = new Object[items.length()];
                        int idx = 0;
                        foreach (var item in items) {
                            objects[idx++] = item;
                        }
                        file_store.splice(0, file_store.get_n_items(), objects);

                        Widget child = path_bar.get_first_child();
                        while (child != null) {
                            var next = child.get_next_sibling();
                            path_bar.remove(child);
                            child = next;
                        }
                        _append_path_root("document-open-recent-symbolic", "Recent", () => {
                            navigate_to_uri("recent://");
                        });
                        current_folder = null;
                        update_menu_actions();
                        if (empty_trash_btn != null) empty_trash_btn.visible = false;
                        // Highlight "Recent" in the sidebar
                        sync_sidebar_active(File.new_for_uri("recent://"));
                        sync_after_special_uri(File.new_for_uri("recent://"));
                        if (objects.length == 0 && settings.get_string("view-mode") != "column") show_empty_state("recent");
                    } catch (Error e) {
                        warning("Failed to load recent files: %s", e.message);
                    }
                });
            } else if (uri == "trash://") {
                navigate_to.begin(File.new_for_uri("trash://"));
            } else if (uri == "smb://") {
                // Show "Connect to Server" immediately, then enumerate network shares async
                file_store.splice(0, file_store.get_n_items(), { connect_server_item() });

                // Update path bar
                Widget child = path_bar.get_first_child();
                while (child != null) {
                    var next = child.get_next_sibling();
                    path_bar.remove(child);
                    child = next;
                }
                _append_path_root("network-workgroup-symbolic", "Network", () => {
                    navigate_to_uri("smb://");
                });
                current_folder = File.new_for_uri(uri);
                update_menu_actions();
                if (empty_trash_btn != null) empty_trash_btn.visible = false;
                sync_sidebar_active(current_folder);
                sync_after_special_uri(current_folder);

                // Now enumerate shares asynchronously and append them
                var provider = new SambaProvider();
                provider.enumerate.begin(uri, null, (obj, res) => {
                    try {
                        var items = provider.enumerate.end(res);
                        if (items.length() > 0) {
                            Object[] objects = new Object[items.length()];
                            int idx = 0;
                            foreach (var item in items) objects[idx++] = item;
                            // Append after Connect to Server
                            uint cur_n = file_store.get_n_items();
                            file_store.splice(cur_n, 0, objects);
                        }
                    } catch { }
                });
            }
        }

        private void sort_files() {
            string method = settings.get_string("sort-method");
            string order = settings.get_string("sort-order");
            bool ascending = (order == "ascending");
            file_store.sort((a, b) => {
                var item_a = (FileItem)a;
                var item_b = (FileItem)b;
                bool dir_a = item_a.info.get_file_type() == FileType.DIRECTORY;
                bool dir_b = item_b.info.get_file_type() == FileType.DIRECTORY;
                if (dir_a && !dir_b) return -1;
                if (!dir_a && dir_b) return 1;
                int result = 0;
                if (method == "size") {
                    int64 size_a = item_a.info.get_size();
                    int64 size_b = item_b.info.get_size();
                    if (size_a < size_b) result = -1;
                    else if (size_a > size_b) result = 1;
                } else if (method == "type") {
                    string type_a = item_a.info.get_content_type();
                    string type_b = item_b.info.get_content_type();
                    result = type_a.collate(type_b);
                } else if (method == "date") {
                    var date_a = item_a.info.get_modification_date_time();
                    var date_b = item_b.info.get_modification_date_time();
                    if (date_a != null && date_b != null) {
                        result = date_a.compare(date_b);
                    }
                } else {
                    result = item_a.name.collate(item_b.name);
                }
                return ascending ? result : -result;
            });
        }

        // Show a sorted snapshot of items into the store without starting folder monitor.
        // Used to display first-batch results before full enumeration completes.
        private void flush_items_to_store(GenericArray<FileItem> items, File folder) {
            string method = settings.get_string("sort-method");
            string order  = settings.get_string("sort-order");
            bool ascending = (order == "ascending");
            var snap = new GLib.ListStore(typeof(FileItem));
            for (int i = 0; i < items.length; i++) snap.append(items.get(i));
            snap.sort((a, b) => {
                var ia = (FileItem)a; var ib = (FileItem)b;
                bool da = ia.info.get_file_type() == FileType.DIRECTORY;
                bool db = ib.info.get_file_type() == FileType.DIRECTORY;
                if (da && !db) return -1; if (!da && db) return 1;
                int r = 0;
                if (method == "name") r = ia.name.collate(ib.name);
                else if (method == "size") {
                    int64 sa = ia.info.get_size(); int64 sb = ib.info.get_size();
                    r = (sa < sb) ? -1 : (sa > sb) ? 1 : 0;
                } else if (method == "type") {
                    r = (ia.info.get_content_type() ?? "").collate(ib.info.get_content_type() ?? "");
                } else if (method == "date") {
                    var ta = ia.info.get_modification_date_time();
                    var tb = ib.info.get_modification_date_time();
                    if (ta != null && tb != null) r = ta.compare(tb);
                }
                return ascending ? r : -r;
            });
            Object[] objs = new Object[snap.get_n_items()];
            for (uint i = 0; i < snap.get_n_items(); i++) objs[i] = snap.get_item(i);
            if (current_search != "") {
                string q = current_search.down();
                Object[] filtered = {};
                foreach (var obj in objs) if (((FileItem)obj).name.down().contains(q)) filtered += obj;
                objs = filtered;
            }
            file_store.splice(0, file_store.get_n_items(), objs);
            // Switch view to show the content immediately
            if (active_window != null) {
                var win = (Singularity.Widgets.Window)this.active_window;
                var scroll = win.content_area.get_first_child() as ScrolledWindow;
                if (scroll != null) {
                    var stack = scroll.get_data<Stack>("view_stack");
                    if (stack != null) {
                        string mode = settings.get_string("view-mode");
                        stack.set_visible_child_name((mode == "grid") ? "grid" : (mode == "column") ? "column" : "list");
                    }
                }
            }
        }

        private void bind_thumbnail(Image img, Spinner? spinner, FileItem file_item, int size, bool compact) {
            img.set_data<string>("thumb-for-path", "");
            img.set_from_gicon(file_item.info.get_icon());
            if (spinner != null) {
                spinner.spinning = false;
                spinner.visible = false;
            }
            if (!settings.get_boolean("show-previews")) return;
            string? fpath = file_item.file.get_path();
            if (fpath == null) return;
            string? content_type = file_item.info.get_content_type();
            string? cached = file_item.info.get_attribute_byte_string("thumbnail::path");
            if (file_item.info.has_attribute("thumbnail::is-valid")
                    && !file_item.info.get_attribute_boolean("thumbnail::is-valid")) {
                cached = null;
            }
            bool is_image = Files.ThumbnailStyle.for_content_type(content_type) == Files.ThumbnailStyle.PHOTO;
            if (cached == null && !is_image) {
                apply_plugin_icon(img, file_item, size, compact);
                return;
            }
            img.set_data<string>("thumb-for-path", fpath);
            if (spinner != null && cached == null) {
                img.set_from_icon_name("image-loading-symbolic");
                spinner.spinning = true;
                spinner.visible = true;
            }
            load_thumbnail_async(img, spinner, cached ?? fpath, fpath, size, content_type, file_item.info.get_icon(), compact);
        }

        private void load_thumbnail_async(Image img, Spinner? spinner, string source_path, string file_path,
                                          int size, string? content_type, GLib.Icon? fallback, bool compact) {
            int px = int.min(512, int.max(48, size * 2));
            new GLib.Thread<void>("thumb", () => {
                Gdk.Texture? texture = null;
                try {
                    var pb = new Gdk.Pixbuf.from_file_at_scale(source_path, px, px, true);
                    pb = pb.apply_embedded_orientation() ?? pb;
                    var format = pb.has_alpha ? Gdk.MemoryFormat.R8G8B8A8 : Gdk.MemoryFormat.R8G8B8;
                    texture = new Gdk.MemoryTexture(pb.width, pb.height, format, pb.read_pixel_bytes(), pb.rowstride);
                } catch (Error e) {}
                GLib.Idle.add(() => {
                    string? expected = img.get_data<string>("thumb-for-path");
                    if (expected != null && expected == file_path) {
                        if (texture != null)
                            img.set_from_paintable(Files.ThumbnailFrame.decorate(texture, content_type, file_path, compact));
                        else
                            img.set_from_gicon(fallback ?? new ThemedIcon("image-x-generic"));
                        if (spinner != null) {
                            spinner.spinning = false;
                            spinner.visible = false;
                        }
                    }
                    return GLib.Source.REMOVE;
                });
            });
        }

        private bool apply_plugin_icon(Image img, FileItem file_item, int size, bool compact) {
            var mgr = FilesPluginManager.get_default();
            if (!mgr.has_icon_providers()) return false;
            string? content_type = file_item.info.get_content_type();
            var provider = mgr.provider_for(file_item.file, content_type);
            if (provider == null) return false;
            string? fpath = file_item.file.get_path();
            if (fpath == null) return false;
            img.set_data<string>("thumb-for-path", fpath);
            provider.load_icon.begin(file_item.file, size, (obj, res) => {
                var paintable = provider.load_icon.end(res);
                if (paintable == null) return;
                string? expected = img.get_data<string>("thumb-for-path");
                if (expected != null && expected == fpath) {
                    img.set_from_paintable(Files.ThumbnailFrame.decorate(paintable, content_type, fpath, compact));
                }
            });
            return true;
        }

        private async void navigate_to(File folder) {
            if (folder_refresh_id != 0) {
                Source.remove(folder_refresh_id);
                folder_refresh_id = 0;
            }
            if (folder_monitor != null) {
                folder_monitor.cancel();
                folder_monitor = null;
            }
            uint generation = ++navigation_generation;
            try {
                // Request only the attributes we actually use; NOFOLLOW_SYMLINKS avoids
                // extra stat() calls on each symlink target.
                var enumerator = yield folder.enumerate_children_async(
                    "standard::name,standard::type,standard::size,standard::icon," +
                    "standard::is-hidden,standard::is-symlink,standard::content-type," +
                    "time::modified,thumbnail::path,thumbnail::is-valid,trash::orig-path,owner::user",
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT, null);
                if (generation != navigation_generation) return;
                current_folder = folder;
                update_menu_actions();
                string uri = folder.get_uri();
                // Toggle empty-trash button
                if (empty_trash_btn != null)
                    empty_trash_btn.visible = uri.has_prefix("trash://");
                if (uri.has_prefix("file://"))
                    settings.set_string("last-folder", uri);
                update_path_bar(folder);
                sync_archive_banner(folder);
                sync_sidebar_active(folder);

                // Navigation reaching here is always external (sidebar,
                // back/forward, breadcrumb, search, initial load); internal
                // column-row activations call load_column_pane directly. Reset
                // the strip so panes from the previous folder don't linger.
                if (view_stack_ref != null
                    && view_stack_ref.visible_child_name == "column") {
                    if (_col_browser != null) _col_browser.clear();
                    _col_folders = {};
                    _col_count = 0;
                    load_column_pane(0, folder);
                }
                bool show_hidden = settings.get_boolean("show-hidden");

                var items = new GenericArray<FileItem>();
                bool first_batch_shown = false;

                while (true) {
                    var files = yield enumerator.next_files_async(50, Priority.DEFAULT, null);
                    if (generation != navigation_generation) return;
                    if (files == null || files.length() == 0) break;

                    foreach (var info in files) {
                        if (!show_hidden && info.get_is_hidden()) continue;
                        var child_file = folder.get_child(info.get_name());
                        items.add(new FileItem(child_file, info));
                    }

                    // Show first batch immediately so the view feels instant.
                    if (!first_batch_shown && items.length >= 20) {
                        first_batch_shown = true;
                        flush_items_to_store(items, folder);
                    }
                }

                // ush integration: in Linux files, show the folders shared with
                // Linux at their real host path, replacing any same-named guest one.
                string? lh = ush_linux_home();
                if (lh != null && folder.get_path() == lh) {
                    var shared = ush_list_shared_dirs();
                    if (shared.length > 0) {
                        var names = new GenericArray<string>();
                        foreach (string sp in shared) names.add(File.new_for_path(sp).get_basename());
                        var kept = new GenericArray<FileItem>();
                        for (int i = 0; i < items.length; i++) {
                            string bn = items.get(i).file.get_basename();
                            bool shadowed = false;
                            for (int j = 0; j < names.length; j++)
                                if (names.get(j) == bn) { shadowed = true; break; }
                            if (!shadowed) kept.add(items.get(i));
                        }
                        items = kept;
                        foreach (string sp in shared) {
                            var sf = File.new_for_path(sp);
                            try {
                                var sinfo = sf.query_info(
                                    "standard::name,standard::type,standard::size,standard::icon," +
                                    "standard::content-type,time::modified",
                                    FileQueryInfoFlags.NONE, null);
                                items.add(new FileItem(sf, sinfo));
                            } catch (Error e) { }
                        }
                    }
                }

                // Use temporary ListStore for sorting as recommended for better Vala closure handling
                var temp_store = new GLib.ListStore(typeof(FileItem));
                for (int i = 0; i < items.length; i++) {
                    temp_store.append(items.get(i));
                }

                string method = settings.get_string("sort-method");
                string order = settings.get_string("sort-order");
                bool ascending = (order == "ascending");

                temp_store.sort((a, b) => {
                    var item_a = (FileItem)a;
                    var item_b = (FileItem)b;
                    bool dir_a = item_a.info.get_file_type() == FileType.DIRECTORY;
                    bool dir_b = item_b.info.get_file_type() == FileType.DIRECTORY;
                    if (dir_a && !dir_b) return -1;
                    if (!dir_a && dir_b) return 1;
                    int res = 0;
                    if (method == "size") {
                        int64 size_a = item_a.info.get_size();
                        int64 size_b = item_b.info.get_size();
                        if (size_a < size_b) res = -1;
                        else if (size_a > size_b) res = 1;
                    } else if (method == "type") {
                        string type_a = item_a.info.get_content_type() ?? "";
                        string type_b = item_b.info.get_content_type() ?? "";
                        res = type_a.collate(type_b);
                    } else if (method == "date") {
                        var date_a = item_a.info.get_modification_date_time();
                        var date_b = item_b.info.get_modification_date_time();
                        if (date_a != null && date_b != null) res = date_a.compare(date_b);
                    } else {
                        res = item_a.name.collate(item_b.name);
                    }
                    return ascending ? res : -res;
                });

                // Convert sorted temp_store to a regular array for splice
                Object[] objects = new Object[temp_store.get_n_items()];
                for (uint i = 0; i < temp_store.get_n_items(); i++) {
                    objects[i] = temp_store.get_item(i);
                }

                // Apply search filter if active
                if (current_search != "") {
                    string q = current_search.down();
                    Object[] filtered = {};
                    foreach (var obj in objects) {
                        if (((FileItem)obj).name.down().contains(q)) filtered += obj;
                    }
                    objects = filtered;
                }

                // Atomic update: remove everything and add everything in ONE signal
                file_store.splice(0, file_store.get_n_items(), objects);

                // Switch to the empty StatusPage (or back to the regular view).
                sync_empty_state();

                // Auto-select first result when search is active
                if (current_search != "" && file_store.get_n_items() > 0) {
                    var sel = file_view.model as SelectionModel;
                    if (sel != null)
                        GLib.Idle.add(() => { sel.select_item(0, true); return GLib.Source.REMOVE; });
                }

                update_nav_buttons();

                // (Re-)start folder monitor so the view refreshes on file changes
                try {
                    folder_monitor = folder.monitor_directory(FileMonitorFlags.NONE, null);
                    folder_monitor.changed.connect((src, dest, event) => {
                        if (generation != navigation_generation) return;
                        if (event == FileMonitorEvent.CREATED ||
                            event == FileMonitorEvent.DELETED ||
                            event == FileMonitorEvent.RENAMED ||
                            event == FileMonitorEvent.MOVED_IN ||
                            event == FileMonitorEvent.MOVED_OUT ||
                            event == FileMonitorEvent.CHANGES_DONE_HINT ||
                            event == FileMonitorEvent.ATTRIBUTE_CHANGED) {
                            if (folder_refresh_id != 0) {
                                Source.remove(folder_refresh_id);
                            }
                            folder_refresh_id = Timeout.add(100, () => {
                                folder_refresh_id = 0;
                                if (generation == navigation_generation &&
                                    current_folder != null && current_folder.equal(folder)) {
                                    navigate_to.begin(folder);
                                }
                                return Source.REMOVE;
                            });
                        }
                    });
                } catch (Error me) {
                    // Non-local filesystems may not support monitoring; ignore
                }

                if (active_window != null) {
                    var window = (Singularity.Widgets.Window)this.active_window;
                    var content_box = window.content_area;
                    var content = content_box.get_first_child() as ScrolledWindow;
                    if (content != null) {
                        var stack = content.get_data<Stack>("view_stack");
                        if (stack != null) {
                            string mode = settings.get_string("view-mode");
                            if (mode == "column") {
                                stack.visible_child_name = "column";
                                load_column_pane(0, folder);
                            } else if (file_store.get_n_items() == 0) {
                                stack.visible_child_name = "empty";
                            } else {
                                stack.visible_child_name = (mode == "grid") ? "grid" : "list";
                            }
                        }
                    }
                }
            } catch (Error e) {
                warning("Failed to enumerate %s: %s", folder.get_path(), e.message);
            }
        }

        private void go_up() {
            if (current_folder != null) {
                string? root = archive_root_for(current_folder.get_path());
                if (root != null && current_folder.get_path() == root) {
                    var archive_parent = File.new_for_path(_archive_views.get(root)).get_parent();
                    if (archive_parent != null) navigate_user(archive_parent);
                    return;
                }
                var parent = current_folder.get_parent();
                if (parent != null) {
                    navigate_user(parent);
                }
            }
        }

        private void _append_path_root(string icon_name, string label, owned PathRootAction action) {
            var btn = new Button.from_icon_name(icon_name);
            btn.add_css_class("flat");
            btn.add_css_class("path-button");
            btn.clicked.connect(() => action());
            path_bar.append(btn);
            var lbl_btn = new Button.with_label(label);
            lbl_btn.add_css_class("flat");
            lbl_btn.add_css_class("path-button");
            var inner = lbl_btn.get_child() as Label;
            if (inner != null) {
                inner.ellipsize = Pango.EllipsizeMode.END;
                inner.max_width_chars = 14;
            }
            lbl_btn.clicked.connect(() => action());
            path_bar.append(lbl_btn);
        }

        public delegate void PathRootAction();

        // ── Trash sidebar live icon (empty / full) ─────────────────
        private GLib.FileMonitor? _trash_monitor = null;

        private void _watch_trash_state() {
            // Monitor Trash so the icon flips when items are added/removed.
            _refresh_trash_icon();
            try {
                var trash = GLib.File.new_for_uri("trash://");
                _trash_monitor = trash.monitor_directory(
                    GLib.FileMonitorFlags.NONE, null);
                _trash_monitor.changed.connect((f, of, ev) => {
                    _refresh_trash_icon();
                });
            } catch (Error e) {
                warning("Trash monitor failed: %s", e.message);
            }
        }

        private void _refresh_trash_icon() {
            var btn = _place_buttons["trash:///"] ?? _place_buttons["trash://"];
            var row = btn as Singularity.Widgets.SidebarRow;
            if (row == null) return;
            bool full = false;
            try {
                var trash = GLib.File.new_for_uri("trash://");
                var en = trash.enumerate_children(
                    "standard::name", GLib.FileQueryInfoFlags.NONE, null);
                if (en.next_file(null) != null) full = true;
            } catch (Error e) {
                full = false;
            }
            row.update_icon_name(full ? "user-trash-full-symbolic"
                                      : "user-trash-symbolic");
        }

        private string icon_name_from_gicon(GLib.Icon? gi, string fallback) {
            if (gi is GLib.ThemedIcon) {
                var names = ((GLib.ThemedIcon) gi).get_names();
                foreach (var n in names) {
                    if (!n.has_suffix("-symbolic")) return n;
                }
                if (names.length > 0) {
                    string n = names[0];
                    if (n.has_suffix("-symbolic"))
                        return n.substring(0, n.length - "-symbolic".length);
                    return n;
                }
            }
            return fallback;
        }

        private void enumerate_storage(StorageEntryFunc fn) {
            var vm = GLib.VolumeMonitor.get();
            var seen = new GLib.GenericSet<string>(str_hash, str_equal);
            foreach (var vol in vm.get_volumes()) {
                var mount = vol.get_mount();
                string name = vol.get_name() ?? _("Volume");
                string icon = icon_name_from_gicon(vol.get_icon(), "drive-removable-media");
                if (mount != null) {
                    var mfile = mount.get_root();
                    string? mpath = mfile != null ? (mfile.get_path() ?? mfile.get_uri()) : null;
                    if (mpath == "/") continue;
                    if (mpath != null) seen.add(mpath);
                    fn(name, icon, mpath, null);
                } else if (vol.can_mount()) {
                    fn(name, icon, null, vol);
                }
            }
            foreach (var mount in vm.get_mounts()) {
                if (mount.get_volume() != null) continue;
                var mfile = mount.get_root();
                if (mfile == null) continue;
                string mpath = mfile.get_path() ?? mfile.get_uri();
                if (mpath == "/") continue;
                if (seen.contains(mpath)) continue;
                string name = mount.get_name() ?? GLib.Path.get_basename(mpath);
                string icon = icon_name_from_gicon(mount.get_icon(), "drive-removable-media");
                fn(name, icon, mpath, null);
            }
        }

        private void mount_volume_and_navigate(GLib.Volume vol) {
            var op = new Gtk.MountOperation(active_window);
            vol.mount.begin(GLib.MountMountFlags.NONE, op, null, (obj, res) => {
                try {
                    vol.mount.end(res);
                    var m = vol.get_mount();
                    if (m != null) {
                        var root = m.get_root();
                        if (root != null) navigate_user(root);
                    }
                } catch (Error e) {
                    warning("Failed to mount volume: %s", e.message);
                }
            });
        }

        private void show_disks_page() {
            if (_disks_page_box == null || view_stack_ref == null) return;
            Widget child = path_bar.get_first_child();
            while (child != null) {
                var n = child.get_next_sibling();
                path_bar.remove(child);
                child = n;
            }
            _append_path_root("drive-harddisk-symbolic", "Disks", () => show_disks_page());

            // Clear previous cards
            var fc = _disks_page_box.get_first_child();
            while (fc != null) {
                var next = fc.get_next_sibling();
                _disks_page_box.remove(fc);
                fc = next;
            }

            current_folder = null;
            update_menu_actions();
            if (empty_trash_btn != null) empty_trash_btn.visible = false;
            mark_disks_sidebar_active();

            add_disk_card(_disks_page_box, "File System", "/", "drive-harddisk");
            // ush integration: Linux files as a disk.
            string? ush_disk = ush_linux_home();
            if (ush_disk != null) {
                add_disk_card(_disks_page_box, "Linux files", ush_disk, "ush-penguin");
            }
            // dsh integration (same, dev environment)
            string? dev_disk = ush_dev_home();
            if (dev_disk != null) {
                add_disk_card(_disks_page_box, "Developer files", dev_disk, "applications-engineering");
            }
            enumerate_storage((name, icon, path, volume) => {
                if (path != null) {
                    add_disk_card(_disks_page_box, name, path, icon);
                } else if (volume != null) {
                    add_disk_card_volume(_disks_page_box, name, icon, volume);
                }
            });

            view_stack_ref.visible_child_name = "disks";
        }

        private void add_disk_card(FlowBox box, string name, string path, string icon) {
            // Fixed-size card button: 160×170 px
            var btn = new Button();
            btn.has_frame = true;
            btn.add_css_class("disk-card");
            btn.set_size_request(160, 160);
            var vbox = new Box(Orientation.VERTICAL, 8);
            vbox.margin_top = 14;
            vbox.margin_bottom = 12;
            vbox.margin_start = 12;
            vbox.margin_end = 12;

            // Use non-symbolic icon (64px) with fallback
            var img = new Image();
            img.pixel_size = 56;
            img.halign = Align.CENTER;
            img.set_from_icon_name(icon);
            vbox.append(img);

            var lbl = new Label(name);
            lbl.halign = Align.CENTER;
            lbl.ellipsize = Pango.EllipsizeMode.END;
            lbl.max_width_chars = 12;
            vbox.append(lbl);

            var bar = new LevelBar();
            bar.min_value = 0;
            bar.max_value = 1;
            bar.value = 0;
            bar.add_css_class("disk-usage-bar");
            vbox.append(bar);

            var size_lbl = new Label("");
            size_lbl.add_css_class("dim-label");
            size_lbl.halign = Align.CENTER;
            size_lbl.ellipsize = Pango.EllipsizeMode.END;
            size_lbl.max_width_chars = 14;
            vbox.append(size_lbl);

            btn.set_child(vbox);
            btn.clicked.connect(() => navigate_user(File.new_for_path(path)));

            // Wrap in FlowBoxChild with fixed size so it doesn't stretch
            var fbi = new FlowBoxChild();
            fbi.set_child(btn);
            fbi.add_css_class("disk-card-child");
            fbi.focusable = false;
            fbi.halign = Align.START;
            fbi.valign = Align.START;
            box.append(fbi);

            // Async: query used/total
            var disk_file = GLib.File.new_for_path(path);
            disk_file.query_filesystem_info_async.begin(
                "filesystem::size,filesystem::free", Priority.LOW, null, (obj2, res2) => {
                    try {
                        var fs_info = disk_file.query_filesystem_info_async.end(res2);
                        uint64 total = fs_info.get_attribute_uint64("filesystem::size");
                        uint64 free_b = fs_info.get_attribute_uint64("filesystem::free");
                        uint64 used = total - free_b;
                        if (total > 0) {
                            bar.value = (double)used / (double)total;
                        }
                        string free_str = GLib.format_size(free_b);
                        string total_str = GLib.format_size(total);
                        size_lbl.label = _("%s free of %s").printf(free_str, total_str);
                    } catch { }
                });
        }

        private void add_disk_card_volume(FlowBox box, string name, string icon, GLib.Volume volume) {
            var btn = new Button();
            btn.has_frame = true;
            btn.add_css_class("disk-card");
            btn.set_size_request(160, 160);
            var vbox = new Box(Orientation.VERTICAL, 8);
            vbox.margin_top = 14;
            vbox.margin_bottom = 12;
            vbox.margin_start = 12;
            vbox.margin_end = 12;

            var img = new Image();
            img.pixel_size = 56;
            img.halign = Align.CENTER;
            img.set_from_icon_name(icon);
            vbox.append(img);

            var lbl = new Label(name);
            lbl.halign = Align.CENTER;
            lbl.ellipsize = Pango.EllipsizeMode.END;
            lbl.max_width_chars = 12;
            vbox.append(lbl);

            var hint = new Label(_("Click to mount"));
            hint.add_css_class("dim-label");
            hint.halign = Align.CENTER;
            hint.ellipsize = Pango.EllipsizeMode.END;
            hint.max_width_chars = 14;
            vbox.append(hint);

            btn.set_child(vbox);
            btn.clicked.connect(() => mount_volume_and_navigate(volume));

            var fbi = new FlowBoxChild();
            fbi.set_child(btn);
            fbi.add_css_class("disk-card-child");
            fbi.focusable = false;
            fbi.halign = Align.START;
            fbi.valign = Align.START;
            box.append(fbi);
        }

        // Column browser (Miller columns)

        private void rebuild_visible_panes() {
            if (_col_browser == null) return;
            _col_browser.set_viewport(_col_viewport_start, MAX_COL_VISIBLE);
            // Scroll to show the rightmost pane.
            Idle.add(() => {
                var adj = _col_browser.hadjustment;
                if (adj != null)
                    adj.set_value(adj.get_upper() - adj.get_page_size());
                return false;
            });
        }

        private void load_column_pane(int idx, File folder) {
            if (_col_browser == null) return;

            // Drop every pane after the requested index.
            _col_browser.pop_to(idx - 1);
            if (_col_folders.length > idx) _col_folders.resize(idx);
            _col_count = idx;

            var pane = _col_browser.push_pane();
            _col_folders += folder;
            _col_count = idx + 1;

            // Sliding viewport: always show rightmost MAX_COL_VISIBLE panes
            _col_viewport_start = int.max(0, _col_count - MAX_COL_VISIBLE);
            rebuild_visible_panes();

            fill_column_pane.begin(idx, folder, pane.list_box);
        }

        private async void fill_column_pane(int idx, File folder, ListBox list_box) {
            try {
                bool show_hidden = settings.get_boolean("show-hidden");
                var items = new GenericArray<FileItem>();

                // Route smb:// and recent:// through their respective
                // FileProviders - enumerate_children_async returns nothing
                // for those special URIs, which is why column mode used to
                // show an empty Network page.
                string uri = folder.get_uri();
                if (uri.has_prefix("smb://") && uri.length <= 6) {
                    // Seed with the synthetic "Connect to Server" entry so the
                    // column matches what grid/list view shows.
                    items.add(connect_server_item());
                    var provider = new Singularity.FileSystem.SambaProvider();
                    try {
                        var shares = yield provider.enumerate(uri, null);
                        foreach (var it in shares) items.add(it);
                    } catch { /* network may be slow/missing - show stub only */ }
                } else if (uri.has_prefix("recent://")) {
                    var provider = new Singularity.FileSystem.RecentProvider();
                    try {
                        var recents = yield provider.enumerate(uri, null);
                        foreach (var it in recents) items.add(it);
                    } catch {}
                } else {
                    var enumerator = yield folder.enumerate_children_async(
                        "standard::*,standard::icon,standard::is-hidden,time::modified,owner::user",
                        FileQueryInfoFlags.NONE, Priority.DEFAULT, null);
                    while (true) {
                        var files = yield enumerator.next_files_async(100, Priority.DEFAULT, null);
                        if (files == null || files.length() == 0) break;
                        foreach (var info in files) {
                            if (!show_hidden && info.get_is_hidden()) continue;
                            var child = folder.get_child(info.get_name());
                            items.add(new FileItem(child, info));
                        }
                    }
                }

                // Sort: folders first, then by name
                items.sort((a, b) => {
                    bool dir_a = a.info.get_file_type() == FileType.DIRECTORY;
                    bool dir_b = b.info.get_file_type() == FileType.DIRECTORY;
                    if (dir_a && !dir_b) return -1;
                    if (!dir_a && dir_b) return  1;
                    return a.name.collate(b.name);
                });

                // set_empty handles the placeholder swap internally.
                if (items.length == 0) {
                    var pane = _col_browser != null ? _col_browser.get_pane(idx) : null;
                    if (pane != null) pane.set_empty("folder-symbolic", "Empty", "");
                    return;
                }

                for (int i = 0; i < items.length; i++) {
                    var item = items.get(i);
                    var row = new ListBoxRow();
                    row.add_css_class("col-browser-row");

                    var row_box = new Box(Orientation.HORIZONTAL, 8);
                    row_box.margin_top = 4;
                    row_box.margin_bottom = 4;
                    row_box.margin_start = 10;
                    row_box.margin_end = 6;

                    var icon = new Image();
                    icon.pixel_size = 16;
                    if (item.info.get_icon() != null)
                        icon.set_from_gicon(item.info.get_icon());
                    else
                        icon.icon_name = item.is_folder
                            ? "folder-symbolic" : "text-x-generic-symbolic";

                    var name_lbl = new Label(item.name);
                    name_lbl.halign = Align.START;
                    name_lbl.hexpand = true;
                    name_lbl.ellipsize = Pango.EllipsizeMode.END;

                    row_box.append(icon);
                    row_box.append(name_lbl);

                    if (item.is_folder) {
                        var chevron = new Image.from_icon_name("go-next-symbolic");
                        chevron.pixel_size = 12;
                        chevron.add_css_class("dim-label");
                        chevron.valign = Align.CENTER;
                        row_box.append(chevron);
                    }

                    row.set_child(row_box);
                    row.set_data<FileItem>("col-file-item", item);

                    var captured_item = item;
                    var ctx_gesture = new GestureClick();
                    ctx_gesture.button = 3;
                    ctx_gesture.pressed.connect((n, gx, gy) => {
                        show_context_menu(row, captured_item, gx, gy);
                    });
                    row.add_controller(ctx_gesture);

                    list_box.append(row);
                }

                int captured_idx2 = idx;
                list_box.row_activated.connect((row) => {
                    var fi = row.get_data<FileItem>("col-file-item");
                    if (fi == null) return;
                    // Picker mode: a click/dbl-click in the column should
                    // SELECT for the picker, not launch / open in browser.
                    // Folders still descend into a new column, but files
                    // and "everything else" become the picker selection
                    // (single click) or commit it (double click).
                    if (picker_mode) {
                        if (fi.is_folder) {
                            load_column_pane(captured_idx2 + 1, fi.file);
                            current_folder = fi.file;
                            update_path_bar(fi.file);
                            // Selecting a folder is also a valid picker
                            // choice (save-mode / folder pickers).
                            _picker_selected_file = fi.file;
                            _picker_selected_info = fi.info;
                        } else {
                            _picker_selected_file = fi.file;
                            _picker_selected_info = fi.info;
                        }
                        // row_activated fires on Enter + double-click; we
                        // treat both as confirm. Single-click on a row in
                        // a ListBox does NOT fire row_activated, just
                        // selection change - separately handled below.
                        submit_picker_selection();
                        return;
                    }
                    if (fi.is_folder) {
                        load_column_pane(captured_idx2 + 1, fi.file);
                        current_folder = fi.file;
                        update_menu_actions();
                        update_path_bar(fi.file);
                    } else if (is_archive_item(fi)) {
                        open_archive_as_folder(fi);
                    } else {
                        launch_file(fi.file);
                    }
                });

                // In picker mode, also update the picker's current selection
                // on a single-click - so the user can pick a row and confirm
                // via the toolbar button without double-clicking.
                if (picker_mode) {
                    list_box.row_selected.connect((row) => {
                        if (row == null) return;
                        var fi = row.get_data<FileItem>("col-file-item");
                        if (fi == null) return;
                        _picker_selected_file = fi.file;
                        _picker_selected_info = fi.info;
                    });
                }

            } catch (Error e) {
                warning("Column pane load error: %s", e.message);
            }
        }


        private void launch_file(File file) {
            FileOpener.open(file, active_window);
        }

        private bool is_runnable(File file) {
            if (file.get_path() == null) return false;
            try {
                var info = file.query_info(FileAttribute.ACCESS_CAN_EXECUTE + "," + FileAttribute.STANDARD_CONTENT_TYPE,
                    FileQueryInfoFlags.NONE);
                string? content_type = info.get_content_type();
                return info.get_attribute_boolean(FileAttribute.ACCESS_CAN_EXECUTE)
                    && content_type != null && ContentType.can_be_executable(content_type);
            } catch (Error e) {
                return false;
            }
        }

        private void run_program(File file) {
            string? path = file.get_path();
            if (path == null) return;
            try {
                string[] argv = { path };
                Process.spawn_async(file.get_parent()?.get_path(), argv, null, 0, null, null);
            } catch (SpawnError e) {
                warning("Run as program failed: %s", e.message);
            }
        }

        private void launch_terminal() {
            if (current_folder == null) return;
            try {
                // Pass --working-directory so the terminal opens in the current folder
                string[] argv = { "singularity-leafs", current_folder.get_path() };
                Process.spawn_async(null, argv, null, SpawnFlags.SEARCH_PATH, null, null);
            } catch (Error e) {
                warning("Failed to launch terminal: %s", e.message);
            }
        }

        private void show_properties(FileItem? forced_item = null) {
            File file = current_folder;
            string name = current_folder != null ? current_folder.get_basename() : "";
            string type = "Directory";
            string size_str = "--";
            FileInfo? info = null;
            FileItem? effective_item = forced_item;
            if (effective_item == null) {
                var selected = get_selected_items();
                if (selected.length > 0) effective_item = selected.get(0);
            }
            if (effective_item != null) {
                file = effective_item.file;
                name = effective_item.name;
                info = effective_item.info;
                type = info.get_content_type() ?? "Unknown";
                size_str = format_size(info.get_size());
            }
            var dialog = new Singularity.Widgets.AppDialog((Gtk.Application)this, false);
            dialog.title = _("Properties");
            dialog.transient_for = (Gtk.Window)file_view.get_root();
            dialog.set_default_size(400, 450);
            var box = new Box(Orientation.VERTICAL, 18);
            box.margin_top = 32;
            box.margin_bottom = 32;
            box.margin_start = 32;
            box.margin_end = 32;
            box.add_css_class("properties-dialog");
            Icon? file_icon = null;
            if (info != null) {
                file_icon = info.get_icon();
            }
            var icon = file_icon != null
                ? new Image.from_gicon(file_icon)
                : new Image.from_icon_name(type == "Directory" ? "folder" : "text-x-generic");
            icon.pixel_size = 64;
            icon.halign = Align.CENTER;
            box.append(icon);
            var name_lbl = new Label(name);
            name_lbl.add_css_class("title-2");
            name_lbl.halign = Align.CENTER;
            name_lbl.ellipsize = Pango.EllipsizeMode.MIDDLE;
            name_lbl.max_width_chars = 30;
            box.append(name_lbl);
            box.append(new Separator(Orientation.HORIZONTAL));
            var grid = new Grid();
            grid.column_spacing = 16;
            grid.row_spacing = 12;
            grid.halign = Align.FILL;
            grid.hexpand = true;
            int row = 0;
            void add_info_row(string label_text, string value_text) {
                var lbl = new Label(label_text);
                lbl.halign = Align.END;
                lbl.add_css_class("dim-label");
                lbl.add_css_class("caption");
                grid.attach(lbl, 0, row);
                var val = new Label(value_text);
                val.halign = Align.START;
                val.ellipsize = Pango.EllipsizeMode.MIDDLE;
                val.max_width_chars = 25;
                val.selectable = true;
                grid.attach(val, 1, row);
                row++;
            }
            add_info_row("Type:", type);
            add_info_row("Size:", size_str);
            var parent = file.get_parent();
            if (parent != null) {
                add_info_row("Location:", parent.get_path() ?? "");
            }
            if (info != null) {
                var mod_time = info.get_modification_date_time();
                if (mod_time != null) {
                    add_info_row("Modified:", mod_time.to_local().format("%Y-%m-%d %H:%M"));
                }
                if (info.has_attribute(FileAttribute.UNIX_MODE)) {
                    uint32 mode = info.get_attribute_uint32(FileAttribute.UNIX_MODE);
                    string perms = format_permissions(mode);
                    add_info_row("Permissions:", perms);
                }
            }
            if (effective_item != null && !effective_item.is_folder && is_archive_item(effective_item)) {
                add_archive_properties(grid, row, file);
            }
            box.append(grid);
            var btn_box = new Box(Orientation.HORIZONTAL, 12);
            btn_box.halign = Align.END;
            btn_box.margin_top = 12;
            var close_btn = new Button.with_label(_("Close"));
            close_btn.add_css_class("close-button");
            close_btn.clicked.connect(() => dialog.close());
            dialog.set_cancel_button(close_btn);
            btn_box.append(close_btn);
            box.append(btn_box);
            dialog.content_box.append(box);
            dialog.present();
        }

        private string format_permissions(uint32 mode) {
            string result = "";
            result += (mode & 0400) != 0 ? "r" : "-";
            result += (mode & 0200) != 0 ? "w" : "-";
            result += (mode & 0100) != 0 ? "x" : "-";
            result += (mode & 0040) != 0 ? "r" : "-";
            result += (mode & 0020) != 0 ? "w" : "-";
            result += (mode & 0010) != 0 ? "x" : "-";
            result += (mode & 0004) != 0 ? "r" : "-";
            result += (mode & 0002) != 0 ? "w" : "-";
            result += (mode & 0001) != 0 ? "x" : "-";
            return result;
        }
    }
}

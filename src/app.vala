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
        private Singularity.Widgets.StatusPage? _empty_page = null;
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
        private Entry? filename_entry = null;
        private Entry search_entry_widget;
        private string current_search = "";
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
        private FlowBox? _disks_page_box = null;
        private string[] _temp_archive_dirs = {};

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

        /**
         * Ensure the view_stack has an "empty" page with a centred StatusPage.
         * Idempotent - safe to call from multiple init paths.
         */
        private void ensure_empty_page() {
            if (view_stack_ref == null) return;
            if (view_stack_ref.get_child_by_name("empty") != null) return;
            _empty_page = new Singularity.Widgets.StatusPage();
            _empty_page.icon_name = "folder-symbolic";
            _empty_page.title = _("This folder is empty");
            _empty_page.description = "Drop files here or use the menu to add new items.";
            view_stack_ref.add_named(_empty_page, "empty");
        }

        /**
         * Pick the right StatusPage copy for the current folder (Trash, Recent,
         * search results, …) and switch the view_stack to "empty" or back to
         * the user's view mode.
         */
        private void sync_empty_state() {
            if (view_stack_ref == null) return;
            ensure_empty_page();
            bool is_empty = file_store == null || file_store.get_n_items() == 0;
            if (is_empty && current_folder != null) {
                string uri = current_folder.get_uri();
                if (uri.has_prefix("trash://")) {
                    _empty_page.icon_name = "user-trash-symbolic";
                    _empty_page.title = _("Trash is empty");
                    _empty_page.description = "Deleted files appear here. They are not actually removed until you empty the Trash.";
                } else if (uri.has_prefix("recent://")) {
                    _empty_page.icon_name = "document-open-recent-symbolic";
                    _empty_page.title = _("No recent files");
                    _empty_page.description = "Files you open will appear here for quick access.";
                } else if (current_search != "") {
                    _empty_page.icon_name = "system-search-symbolic";
                    _empty_page.title = _("No matches");
                    _empty_page.description = "Try a different search term, or clear the filter with Escape.";
                } else {
                    _empty_page.icon_name = "folder-symbolic";
                    _empty_page.title = _("This folder is empty");
                    _empty_page.description = "Drop files here, paste with Ctrl+V or use the menu to add new items.";
                }
                view_stack_ref.visible_child_name = "empty";
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

        private void setup_menu() {
            var menu = new GLib.Menu();

            var file_menu = new GLib.Menu();
            file_menu.append("New Window", "app.new-window");
            file_menu.append("Open Terminal", "app.open-terminal");
            file_menu.append("Properties", "app.properties");
            file_menu.append("Settings", "app.settings");
            file_menu.append("Quit", "app.quit");
            menu.append_submenu("File", file_menu);

            var view_menu = new GLib.Menu();
            view_menu.append("Grid View", "app.view-mode('grid')");
            view_menu.append("List View", "app.view-mode('list')");
            view_menu.append("Column View", "app.view-mode('column')");
            view_menu.append("Show Hidden Files", "app.show-hidden");
            menu.append_submenu("View", view_menu);

            set_menubar(menu);

            // Actions
            var act_new_win = new SimpleAction("new-window", null);
            act_new_win.activate.connect(() => {
                try {
                    Process.spawn_command_line_async("singularity-files");
                } catch (Error e) { warning("%s", e.message); }
            });
            add_action(act_new_win);

            var act_term = new SimpleAction("open-terminal", null);
            act_term.activate.connect(launch_terminal);
            add_action(act_term);

            var act_props = new SimpleAction("properties", null);
            act_props.activate.connect(() => show_properties(null));
            add_action(act_props);

            var act_quit = new SimpleAction("quit", null);
            act_quit.activate.connect(() => {
                _cleanup_temp_archive_dirs();
                quit();
            });
            add_action(act_quit);

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

            var act_hidden = new SimpleAction.stateful("show-hidden", null, new GLib.Variant.boolean(false));
            act_hidden.activate.connect(() => {
                bool current = settings.get_boolean("show-hidden");
                settings.set_boolean("show-hidden", !current);
                act_hidden.set_state(new GLib.Variant.boolean(!current));
            });
            add_action(act_hidden);
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
                    if (f.query_exists(null)) _startup_folder = f;
                }
            }
            activate();
            return 0;
        }

        // Folder to open on launch, set from a positional command-line arg.
        private GLib.File? _startup_folder = null;

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

        protected override void startup() {
            base.startup();

            load_files_css();
            setup_menu();

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
            window.set_title(title);
            window.set_default_size(950, 650);

            // Empty handler: the real one is wired later with settings persistence.
            var sidebar_btn = window.add_bubble_icon("sidebar-show-symbolic", "Toggle Sidebar", () => {});
            sidebar_btn.visible = !picker_mode;
            // Back/Forward navigation buttons (non-picker only)
            if (!picker_mode) {
                back_btn = new Button.from_icon_name("go-previous-symbolic");
                back_btn.add_css_class("flat");
                back_btn.visible = false;
                back_btn.tooltip_text = _("Back");
                back_btn.clicked.connect(() => {
                    if (nav_index > 0) {
                        nav_index--;
                        update_nav_buttons();
                        navigate_to.begin(nav_history[nav_index]);
                    }
                });
                window.add_bubble_widget(back_btn);
                fwd_btn = new Button.from_icon_name("go-next-symbolic");
                fwd_btn.add_css_class("flat");
                fwd_btn.visible = false;
                fwd_btn.tooltip_text = _("Forward");
                fwd_btn.clicked.connect(() => {
                    if (nav_index < (int)nav_history.length - 1) {
                        nav_index++;
                        update_nav_buttons();
                        navigate_to.begin(nav_history[nav_index]);
                    }
                });
                window.add_bubble_widget(fwd_btn);
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
                window.set_content(build_content_with_ops_banner(content_scroll));
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
                sidebar_btn.clicked.connect(() => {
                    bool new_state = !window.get_sidebar_visible();
                    window.set_sidebar_visible(new_state);
                    settings.set_boolean("show-sidebar", new_state);
                });

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

                // Empty Trash button - shown only when in trash://
                var etb = new Button.from_icon_name("user-trash-full-symbolic");
                etb.has_frame = false;
                etb.add_css_class("toolbar-button");
                etb.tooltip_text = _("Empty Trash");
                etb.visible = false;
                etb.clicked.connect(() => {
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
                });
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
                // Right-click context menu for list view
                var gesture = new GestureClick();
                gesture.button = 3;
                gesture.pressed.connect((n, x, y) => {
                    var fi = box.get_data<FileItem>("file-item");
                    if (fi != null) show_context_menu(box, fi, x, y);
                });
                box.add_controller(gesture);
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
                bool show_previews = settings.get_boolean("show-previews");
                string? thumb_path = file_item.info.get_attribute_byte_string("thumbnail::path");
                string? content_type = file_item.info.get_content_type();
                if (show_previews && thumb_path != null) {
                    img.set_data<string>("thumb-for-path", "");
                    img.set_from_file(thumb_path);
                } else if (show_previews && content_type != null && content_type.has_prefix("image/")) {
                    img.set_from_gicon(file_item.info.get_icon());
                    string? fpath = file_item.file.get_path();
                    if (fpath != null) {
                        img.set_data<string>("thumb-for-path", fpath);
                        load_thumbnail_async(img, null, fpath, 24);
                    }
                } else {
                    img.set_from_gicon(file_item.info.get_icon());
                    if (!apply_plugin_icon(img, file_item, 24)) {
                        img.set_data<string>("thumb-for-path", "");
                    }
                }
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
                if (file_item.info.get_file_type() == FileType.DIRECTORY) {
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
                drag_src.drag_begin.connect((drag) => {
                    var img_ref = box.get_data<Image>("thumb-img");
                    if (img_ref != null && img_ref.paintable != null) {
                        drag_src.set_icon(img_ref.paintable, 24, 24);
                    }
                });
                box.add_controller(drag_src);
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
                bool show_previews = settings.get_boolean("show-previews");
                string? thumb_path = file_item.info.get_attribute_byte_string("thumbnail::path");
                string? content_type = file_item.info.get_content_type();
                if (show_previews && thumb_path != null) {
                    img.set_data<string>("thumb-for-path", "");
                    img.set_from_file(thumb_path);
                } else if (show_previews && content_type != null && content_type.has_prefix("image/")) {
                    img.set_from_icon_name("image-loading-symbolic");
                    spinner.spinning = true;
                    spinner.visible = true;
                    string? fpath = file_item.file.get_path();
                    if (fpath != null) {
                        img.set_data<string>("thumb-for-path", fpath);
                        load_thumbnail_async(img, spinner, fpath, 64);
                    } else {
                        spinner.spinning = false;
                        spinner.visible = false;
                    }
                } else {
                    img.set_from_gicon(file_item.info.get_icon());
                    if (!apply_plugin_icon(img, file_item, grid_icon_size)) {
                        img.set_data<string>("thumb-for-path", "");
                    }
                }
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
            var status_page = new Singularity.Widgets.StatusPage();
            status_page.icon_name = "folder-open-symbolic";
            status_page.title = _("Folder is Empty");
            status_page.description = "There are no files in this folder.";
            stack.add_named(status_page, "empty");

            var network_empty = new Singularity.Widgets.StatusPage();
            network_empty.icon_name = "network-workgroup-symbolic";
            network_empty.title = _("No Network Shares Found");
            network_empty.description = "No Samba/SMB shares were discovered on the local network.\nUse \"New Connection\" at the top of this page to connect to a specific address.";
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
            bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;

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
                if (current_folder != null) navigate_to.begin(current_folder);
                return true;
            }

            // Ctrl+P opens the path-entry palette (same effect as "/").
            if (ctrl && keyval == Gdk.Key.p) {
                if (path_bar_stack != null && path_bar_stack.visible_child_name != "entry") {
                    if (current_folder != null) {
                        path_entry_widget.text = current_folder.get_path() ?? "";
                    }
                    path_bar_stack.visible_child_name = "entry";
                    path_entry_widget.grab_focus();
                    path_entry_widget.set_position(-1);
                }
                return true;
            }

            // Ctrl+A - select all
            if (ctrl && keyval == Gdk.Key.a) {
                var sel = file_view.model as SelectionModel;
                if (sel != null) sel.select_all();
                return true;
            }

            // Ctrl+C - copy selected file to clipboard
            if (ctrl && keyval == Gdk.Key.c) {
                var selected = get_selected_items();
                if (selected.length > 0) {
                    bool was_cut = clipboard_is_cut;
                    set_clipboard(selected, false);
                    if (was_cut && current_folder != null) navigate_to.begin(current_folder);
                }
                return true;
            }
            // Ctrl+X / Ctrl+K - cut selected file
            if (ctrl && (keyval == Gdk.Key.x || keyval == Gdk.Key.k)) {
                var selected = get_selected_items();
                if (selected.length > 0) {
                    set_clipboard(selected, true);
                    if (current_folder != null) navigate_to.begin(current_folder);
                }
                return true;
            }
            // Ctrl+V - paste
            if (ctrl && keyval == Gdk.Key.v) {
                paste_files();
                return true;
            }
            // Delete / KP_Delete - move selected file to trash (async via ops manager)
            if (!ctrl && (keyval == Gdk.Key.Delete || keyval == Gdk.Key.KP_Delete)) {
                var selected = get_selected_items();
                if (selected.length > 0) {
                    ensure_ops_manager();
                    var files = new GLib.File[selected.length];
                    for (int i = 0; i < selected.length; i++)
                        files[i] = selected.get(i).file;
                    var op = _ops.start_trash(files);
                    op.completed.connect(() => {
                        if (current_folder != null) navigate_to.begin(current_folder);
                    });
                }
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
                try {
                    string? path = current_folder?.get_path();
                    if (path != null) {
                        Process.spawn_command_line_async("singularity-files " + GLib.Shell.quote(path));
                    } else {
                        Process.spawn_command_line_async("singularity-files");
                    }
                } catch (Error e) { warning("new window: %s", e.message); }
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
            }
        }

        // ── Operations banner ─────────────────────────────────────────────────
        private Gtk.Widget build_content_with_ops_banner(Gtk.Widget content) {
            ensure_ops_manager();

            var outer = new Gtk.Box(Orientation.VERTICAL, 0);
            content.hexpand = true;
            content.vexpand = true;

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
                label_text = "Done";
            } else if (_ops.ops.size == 1) {
                var op = _ops.ops[0];
                label_text = op.errored
                    ? "Failed: " + (op.error_message ?? "")
                    : op.display_name;
            } else {
                label_text = "%d file operations".printf(active);
            }
            _ops_label.label = label_text;
        }

        private void show_background_context_menu(Widget widget, double mx, double my) {
            var menu = new Singularity.Widgets.ContextMenu(widget);
            Gdk.Rectangle rect = { (int)mx, (int)my, 1, 1 };
            menu.set_pointing_to(rect);
            menu.add_item("New Folder", "folder-new-symbolic", () => {
                show_new_folder_dialog();
            });
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
            menu.popup();
        }

        private void show_new_folder_dialog() {
            if (current_folder == null) return;
            var dialog = new Singularity.Widgets.AppDialog((Gtk.Application)this, false);
            dialog.title = _("New Folder");
            dialog.transient_for = (Gtk.Window)file_view.get_root();
            dialog.set_default_size(360, 160);

            var box = new Box(Orientation.VERTICAL, 16);
            box.margin_top = 24;
            box.margin_bottom = 24;
            box.margin_start = 24;
            box.margin_end = 24;

            var entry = new Entry();
            entry.placeholder_text = _("Folder name");
            entry.text = "New Folder";
            entry.hexpand = true;
            box.append(entry);

            var btn_box = new Box(Orientation.HORIZONTAL, 8);
            btn_box.halign = Align.END;
            var cancel_btn = new Button.with_label(_("Cancel"));
            cancel_btn.add_css_class("flat");
            cancel_btn.clicked.connect(() => dialog.close());
            var ok_btn = new Button.with_label(_("Create"));
            ok_btn.add_css_class("suggested-action");
            ok_btn.clicked.connect(() => {
                string name = entry.text.strip();
                if (name != "") {
                    var new_dir = current_folder.get_child(name);
                    try {
                        new_dir.make_directory(null);
                        navigate_to.begin(current_folder);
                    } catch (Error e) {
                        warning("New folder failed: %s", e.message);
                    }
                }
                dialog.close();
            });
            btn_box.append(cancel_btn);
            btn_box.append(ok_btn);
            box.append(btn_box);

            var key_ctrl = new EventControllerKey();
            key_ctrl.key_pressed.connect((kv, kc, mstate) => {
                if (kv == Gdk.Key.Return || kv == Gdk.Key.KP_Enter) {
                    ok_btn.clicked();
                    return true;
                }
                return false;
            });
            entry.add_controller(key_ctrl);

            dialog.content_box.append(box);
            dialog.present();
            entry.grab_focus();
            entry.select_region(0, -1);
        }

        private static bool is_archive_file(string? ctype) {
            if (ctype == null) return false;
            string[] archive_types = {
                "application/zip", "application/x-tar",
                "application/x-compressed-tar", "application/x-bzip-compressed-tar",
                "application/x-xz-compressed-tar", "application/x-lzma-compressed-tar",
                "application/x-zstd-compressed-tar", "application/x-7z-compressed",
                "application/x-rar", "application/x-rar-compressed",
                "application/gzip", "application/x-bzip2", "application/x-xz",
                "application/zstd", "application/x-zstd", "application/x-lzip",
                "application/x-lzma"
            };
            foreach (var t in archive_types) {
                if (ctype == t) return true;
            }
            return false;
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

        private void open_archive_as_folder(FileItem item) {
            string? src = item.file.get_path();
            if (src == null) return;
            try {
                string tmpl = GLib.Path.build_filename(GLib.Environment.get_tmp_dir(), "sg-archive-XXXXXX");
                string dest = GLib.DirUtils.make_tmp(tmpl);
                _temp_archive_dirs += dest;
                string[] cmd = { "bsdtar", "xf", src, "-C", dest };
                var proc = new GLib.Subprocess.newv(cmd, GLib.SubprocessFlags.STDERR_PIPE);
                proc.wait_async.begin(null, (obj, res) => {
                    try {
                        proc.wait_async.end(res);
                        if (proc.get_exit_status() == 0) {
                            navigate_user(File.new_for_path(dest));
                        } else {
                            warning("bsdtar extraction failed for %s", src);
                        }
                    } catch (Error e) { warning("Archive open error: %s", e.message); }
                });
            } catch (Error e) {
                warning("Failed to create temp dir for archive: %s", e.message);
            }
        }

        // Build an extraction command for the given archive, picking a tool
        // that is actually installed. bsdtar handles every format but is not
        // always present (e.g. Fedora), so fall back to unzip for .zip and the
        // GNU tar for tarballs.
        private string[]? extract_command(string src, string dest_dir) {
            string lower = src.down();
            if (GLib.Environment.find_program_in_path("bsdtar") != null) {
                return { "bsdtar", "-x", "-f", src, "-C", dest_dir };
            }
            if (lower.has_suffix(".zip") &&
                GLib.Environment.find_program_in_path("unzip") != null) {
                return { "unzip", "-o", src, "-d", dest_dir };
            }
            if (GLib.Environment.find_program_in_path("tar") != null) {
                return { "tar", "-x", "-f", src, "-C", dest_dir };
            }
            return null;
        }

        private void run_extract(string src, string dest_dir, bool refresh) {
            string[]? cmd = extract_command(src, dest_dir);
            if (cmd == null) {
                warning("Extract: no extraction tool (bsdtar/unzip/tar) found");
                return;
            }
            try {
                var proc = new GLib.Subprocess.newv(cmd, GLib.SubprocessFlags.STDERR_PIPE);
                proc.wait_check_async.begin(null, (obj, res) => {
                    try {
                        proc.wait_check_async.end(res);
                        if (refresh && current_folder != null)
                            navigate_to.begin(current_folder);
                    } catch (Error e) {
                        warning("Extract failed for %s: %s", src, e.message);
                    }
                });
            } catch (Error e) {
                warning("Failed to start extraction: %s", e.message);
            }
        }

        private void extract_archive_here(FileItem item) {
            string? src = item.file.get_path();
            string? dest_dir = item.file.get_parent()?.get_path();
            if (src == null || dest_dir == null) return;
            run_extract(src, dest_dir, true);
        }

        private void extract_archive_to(Widget widget, FileItem item) {
            var dialog = new FileDialog();
            dialog.title = _("Extract To…");
            dialog.select_folder.begin(active_window, null, (obj, res) => {
                try {
                    var dest_file = dialog.select_folder.end(res);
                    string? src = item.file.get_path();
                    string? dest = dest_file.get_path();
                    if (src == null || dest == null) return;
                    run_extract(src, dest, false);
                } catch {}
            });
        }

        private void compress_selected_files(Widget widget) {
            var selected = get_selected_items();
            if (selected.length == 0 || current_folder == null) return;
            string default_name = selected.length == 1 ? selected[0].name : "archive";

            var dialog = new Singularity.Widgets.AppDialog((Gtk.Application)this, false);
            dialog.title = _("Compress Files");
            if (active_window != null) dialog.transient_for = active_window;
            dialog.set_default_size(380, 200);

            var box = new Box(Orientation.VERTICAL, 12);
            box.margin_top = 20; box.margin_bottom = 20;
            box.margin_start = 20; box.margin_end = 20;

            var name_entry = new Entry();
            name_entry.placeholder_text = _("Archive name");
            name_entry.text = default_name;
            name_entry.hexpand = true;
            box.append(name_entry);

            var fmt_row = new Box(Orientation.HORIZONTAL, 8);
            var fmt_lbl = new Label(_("Format:"));
            fmt_lbl.halign = Align.START;
            var fmt_combo = new DropDown.from_strings({ "tar.gz", "zip" });
            fmt_row.append(fmt_lbl);
            fmt_row.append(fmt_combo);
            box.append(fmt_row);

            var btn_row = new Box(Orientation.HORIZONTAL, 8);
            btn_row.halign = Align.END;
            var cancel_btn = new Button.with_label(_("Cancel"));
            cancel_btn.add_css_class("flat");
            cancel_btn.clicked.connect(() => dialog.close());
            var ok_btn = new Button.with_label(_("Compress"));
            ok_btn.add_css_class("suggested-action");
            ok_btn.clicked.connect(() => {
                string aname = name_entry.text.strip();
                if (aname == "") return;
                string? cdir = current_folder.get_path();
                if (cdir == null) { dialog.close(); return; }
                bool is_zip = fmt_combo.selected == 1;
                string ext = is_zip ? ".zip" : ".tar.gz";
                string out_path = GLib.Path.build_filename(cdir, aname + ext);
                string[] sources = {};
                foreach (var fi in selected) { if (fi.file.get_path() != null) sources += fi.file.get_basename(); }
                dialog.close();
                try {
                    string[] cmd;
                    if (is_zip) {
                        cmd = new string[3 + sources.length];
                        cmd[0] = "zip"; cmd[1] = "-r"; cmd[2] = out_path;
                        for (int i = 0; i < sources.length; i++) cmd[3 + i] = sources[i];
                    } else {
                        cmd = new string[4 + sources.length];
                        cmd[0] = "tar"; cmd[1] = "czf"; cmd[2] = out_path; cmd[3] = "--";
                        for (int i = 0; i < sources.length; i++) cmd[4 + i] = sources[i];
                    }
                    var launcher = new GLib.SubprocessLauncher(GLib.SubprocessFlags.STDERR_PIPE);
                    launcher.set_cwd(cdir);
                    var proc = launcher.spawnv(cmd);
                    proc.wait_async.begin(null, (obj, res) => {
                        try { proc.wait_async.end(res); } catch {}
                        if (current_folder != null) navigate_to.begin(current_folder);
                    });
                } catch (Error e) { warning("Compress failed: %s", e.message); }
            });
            btn_row.append(cancel_btn);
            btn_row.append(ok_btn);
            box.append(btn_row);

            dialog.content_box.append(box);
            dialog.present();
            name_entry.grab_focus();
            name_entry.select_region(0, -1);
        }

        private void _cleanup_temp_archive_dirs() {
            foreach (var d in _temp_archive_dirs) {
                try {
                    var f = File.new_for_path(d);
                    delete_recursive(f);
                } catch {}
            }
            _temp_archive_dirs = {};
        }

        private static void delete_recursive(File file) throws Error {
            var info = file.query_info("standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            if (info.get_file_type() == FileType.DIRECTORY) {
                var children = file.enumerate_children("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? child_info;
                while ((child_info = children.next_file()) != null) {
                    delete_recursive(file.get_child(child_info.get_name()));
                }
            }
            file.delete();
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
                    if (is_archive_file(item_ctype)) {
                        menu.add_item("Open as Folder", "folder-open-symbolic", () => {
                            open_archive_as_folder(item);
                        });
                        menu.add_item("Extract Here", "package-x-generic-symbolic", () => {
                            extract_archive_here(item);
                        });
                        menu.add_item("Extract To…", "folder-download-symbolic", () => {
                            extract_archive_to(widget, item);
                        });
                        menu.add_separator();
                    } else {
                        menu.add_item("Open With…", "preferences-other-symbolic", () => {
                            GLib.Idle.add(() => {
                                show_open_with_menu(widget, item, mx, my);
                                return GLib.Source.REMOVE;
                            });
                        });
                    }
                    if (is_image_file(item)) {
                        menu.add_item("Set as Wallpaper", "preferences-desktop-wallpaper-symbolic", () => {
                            set_as_wallpaper(item);
                        });
                    }
                }
                menu.add_item("Compress…", "package-x-generic-symbolic", () => {
                    compress_selected_files(widget);
                });
                menu.add_item("Rename", "document-edit-symbolic", () => {
                    start_inline_rename(item);
                });
                menu.add_separator();
                menu.add_item("Copy", "edit-copy-symbolic", () => {
                    clipboard_set_for_menu(item, false);
                });
                menu.add_item("Cut", "edit-cut-symbolic", () => {
                    clipboard_set_for_menu(item, true);
                    if (current_folder != null) navigate_to.begin(current_folder);
                });
                menu.add_separator();
                menu.add_item("Move to Trash", "user-trash-symbolic", () => {
                    try {
                        item.file.trash(null);
                        if (current_folder != null) navigate_to.begin(current_folder);
                    } catch (Error e) {
                        warning("Trash failed: %s", e.message);
                    }
                });
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
            menu.popup();
        }

        private void show_open_with_menu(Widget widget, FileItem item, double mx = -1, double my = -1) {
            string? ctype = item.info.get_content_type();
            if (ctype == null) return;
            var apps = GLib.AppInfo.get_all_for_type(ctype);
            if (apps.length() == 0) return;
            var popover = new Popover();
            popover.add_css_class("context-menu");
            popover.set_parent(widget);
            popover.has_arrow = false;
            if (mx >= 0 && my >= 0) {
                Gdk.Rectangle rect = { (int)mx, (int)my, 1, 1 };
                popover.set_pointing_to(rect);
            }
            var box = new Box(Orientation.VERTICAL, 0);
            box.margin_top = 4;
            box.margin_bottom = 4;
            apps.foreach((app) => {
                var btn = new Button();
                btn.has_frame = false;
                btn.add_css_class("menu-row");
                var hbox = new Box(Orientation.HORIZONTAL, 10);
                var gicon = app.get_icon();
                var ico = (gicon != null)
                    ? new Image.from_gicon(gicon)
                    : new Image.from_icon_name("application-x-executable-symbolic");
                ico.pixel_size = 16;
                hbox.append(ico);
                var lbl = new Label(app.get_name());
                lbl.halign = Align.START;
                hbox.append(lbl);
                btn.set_child(hbox);
                btn.set_data<GLib.AppInfo>("app-info", app);
                btn.clicked.connect(() => {
                    popover.popdown();
                    var ai = btn.get_data<GLib.AppInfo>("app-info");
                    if (ai == null) return;
                    try {
                        var files = new GLib.List<GLib.File>();
                        files.append(item.file);
                        ai.launch(files, null);
                    } catch (Error e) {
                        warning("Open With launch failed: %s", e.message);
                    }
                });
                box.append(btn);
            });
            popover.set_child(box);
            popover.popup();
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

            // Pre-select the stem only for files with an extension;
            // folders have no dot/extension contract.
            int dot = fi.name.last_index_of_char('.');
            if (dot > 0 && !fi.is_folder) entry.select_region(0, dot);
            else                          entry.select_region(0, -1);
            Idle.add(() => { entry.grab_focus(); return false; });

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
            var dialog = new Singularity.Widgets.AppDialog((Gtk.Application)this, false);
            dialog.title = _("Rename");
            dialog.transient_for = (Gtk.Window)file_view.get_root();
            dialog.set_default_size(360, 160);

            var box = new Box(Orientation.VERTICAL, 16);
            box.margin_top = 24;
            box.margin_bottom = 24;
            box.margin_start = 24;
            box.margin_end = 24;

            var entry = new Entry();
            entry.text = item.name;
            entry.hexpand = true;
            box.append(entry);

            var btn_box = new Box(Orientation.HORIZONTAL, 8);
            btn_box.halign = Align.END;
            var cancel_btn = new Button.with_label(_("Cancel"));
            cancel_btn.add_css_class("flat");
            cancel_btn.clicked.connect(() => dialog.close());
            var ok_btn = new Button.with_label(_("Rename"));
            ok_btn.add_css_class("suggested-action");
            ok_btn.clicked.connect(() => {
                string new_name = entry.text.strip();
                if (new_name != "" && new_name != item.name) {
                    try {
                        item.file.set_display_name(new_name, null);
                        if (current_folder != null) navigate_to.begin(current_folder);
                    } catch (Error e) {
                        warning("Rename failed: %s", e.message);
                    }
                }
                dialog.close();
            });
            btn_box.append(cancel_btn);
            btn_box.append(ok_btn);
            box.append(btn_box);

            // Enter key in entry triggers rename
            var key_ctrl = new EventControllerKey();
            key_ctrl.key_pressed.connect((kv, kc, mstate) => {
                if (kv == Gdk.Key.Return || kv == Gdk.Key.KP_Enter) {
                    ok_btn.clicked();
                    return true;
                }
                return false;
            });
            entry.add_controller(key_ctrl);

            dialog.content_box.append(box);
            dialog.present();
            entry.grab_focus();
        }

        private void trigger_preview(string uri) {
            try {
                var preview = Bus.get_proxy_sync<PreviewService>(BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/shell/Preview");
                preview.show_preview(uri);
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
            if (is_archive_file(file_item.info.get_content_type())) {
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
            if (bookmarks.length > 0) {
                _bookmarks_section.append(new Separator(Orientation.HORIZONTAL));
                _bookmarks_section.append(new Singularity.Widgets.SidebarSectionLabel("Bookmarks"));
                foreach (var bm in bookmarks) {
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
                menu.popup();
                gesture.set_state(EventSequenceState.CLAIMED);
            });
            btn.add_controller(gesture);
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
            box.append(btn);
        }

        // Highlight the sidebar button whose path is the closest ancestor of (or equal to) `folder`.
        private void sync_sidebar_active(File folder) {
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
                        if (empty_trash_btn != null) empty_trash_btn.visible = false;
                        // Highlight "Recent" in the sidebar
                        sync_sidebar_active(File.new_for_uri("recent://"));
                        sync_after_special_uri(File.new_for_uri("recent://"));
                    } catch (Error e) {
                        warning("Failed to load recent files: %s", e.message);
                    }
                });
            } else if (uri == "trash://") {
                navigate_to.begin(File.new_for_uri("trash://"));
            } else if (uri == "smb://") {
                // Show "Connect to Server" immediately, then enumerate network shares async
                var conn_info = new GLib.FileInfo();
                conn_info.set_name("connect-to-server");
                conn_info.set_display_name("New Connection");
                conn_info.set_file_type(GLib.FileType.UNKNOWN);
                conn_info.set_icon(new GLib.ThemedIcon("network-server"));
                var conn_item = new FileItem(GLib.File.new_for_uri("x-singularity://connect-to-server"), conn_info);
                file_store.splice(0, file_store.get_n_items(), { conn_item });

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

        private void load_thumbnail_async(Image img, Spinner? spinner, string file_path, int size) {
            string path = file_path;
            int px = size;

            new GLib.Thread<void>("thumb", () => {
                Gdk.Pixbuf? pb = null;
                try {
                    pb = new Gdk.Pixbuf.from_file_at_scale(path, px, px, true);
                } catch (Error e) {}
                GLib.Idle.add(() => {
                    // Only update if the widget still wants this thumbnail (not recycled)
                    string? expected = img.get_data<string>("thumb-for-path");
                    if (expected != null && expected == path) {
                        if (pb != null)
                            img.set_from_pixbuf(pb);
                        else
                            img.set_from_icon_name("image-x-generic-symbolic");
                        if (spinner != null) {
                            spinner.spinning = false;
                            spinner.visible = false;
                        }
                    }
                    return GLib.Source.REMOVE;
                });
            });
        }

        private bool apply_plugin_icon(Image img, FileItem file_item, int size) {
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
                    img.set_from_paintable(paintable);
                }
            });
            return true;
        }

        private async void navigate_to(File folder) {
            try {
                // Request only the attributes we actually use; NOFOLLOW_SYMLINKS avoids
                // extra stat() calls on each symlink target.
                var enumerator = yield folder.enumerate_children_async(
                    "standard::name,standard::type,standard::size,standard::icon," +
                    "standard::is-hidden,standard::is-symlink,standard::content-type," +
                    "time::modified,thumbnail::path,trash::orig-path,owner::user",
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT, null);
                current_folder = folder;
                string uri = folder.get_uri();
                // Toggle empty-trash button
                if (empty_trash_btn != null)
                    empty_trash_btn.visible = uri.has_prefix("trash://");
                if (uri.has_prefix("file://"))
                    settings.set_string("last-folder", uri);
                update_path_bar(folder);
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
                if (folder_monitor != null) {
                    folder_monitor.cancel();
                    folder_monitor = null;
                }
                try {
                    folder_monitor = folder.monitor_directory(FileMonitorFlags.NONE, null);
                    folder_monitor.changed.connect((src, dest, event) => {
                        if (event == FileMonitorEvent.CREATED ||
                            event == FileMonitorEvent.DELETED ||
                            event == FileMonitorEvent.RENAMED ||
                            event == FileMonitorEvent.MOVED_IN ||
                            event == FileMonitorEvent.MOVED_OUT) {
                            if (current_folder != null)
                                navigate_to.begin(current_folder);
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
                    // Seed with the synthetic "New Connection" entry so the
                    // column matches what grid/list view shows.
                    var conn_info = new GLib.FileInfo();
                    conn_info.set_name("connect-to-server");
                    conn_info.set_display_name("New Connection");
                    conn_info.set_file_type(GLib.FileType.UNKNOWN);
                    conn_info.set_icon(new GLib.ThemedIcon("network-server"));
                    items.add(new FileItem(
                        GLib.File.new_for_uri("x-singularity://connect-to-server"),
                        conn_info));
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
                        update_path_bar(fi.file);
                    } else if (is_archive_file(fi.info.get_content_type())) {
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
            try {
                var launcher = new Gtk.FileLauncher(file);
                launcher.launch.begin(null, null, (obj, res) => {
                    try {
                        launcher.launch.end(res);
                    } catch (Error e) {
                        warning("Launch failed: %s", e.message);
                    }
                });
            } catch (Error e) {
                 warning("Launch setup failed: %s", e.message);
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
            box.append(grid);
            var btn_box = new Box(Orientation.HORIZONTAL, 12);
            btn_box.halign = Align.END;
            btn_box.margin_top = 12;
            var close_btn = new Button.with_label(_("Close"));
            close_btn.add_css_class("close-button");
            close_btn.clicked.connect(() => dialog.close());
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

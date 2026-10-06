using Gtk;
using GLib;
using Singularity;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(PlacesDockPlugin));
}

public class PlacesDockPlugin : Object, Singularity.Plugin, Singularity.DockContextMenuProvider {
    private const string FILES_ID = "dev.sinty.files";
    private const int MAX_BOOKMARKS = 8;

    private PluginContext? context = null;

    public void activate(PluginContext ctx) {
        context = ctx;
        bind_translations();
        ctx.add_dock_context_menu_provider(this);
    }

    public void deactivate() {
        if (context != null) context.remove_dock_context_menu_provider(this);
        context = null;
    }

    public Gtk.Widget? get_settings_widget() {
        return null;
    }

    public bool populate_context_menu(Singularity.Widgets.ContextMenu menu, DockContextMenuRequest request) {
        string id = request.app_id.down();
        if (id.has_suffix(".desktop")) id = id.substring(0, id.length - 8);
        if (id != FILES_ID) return false;
        var app = new DesktopAppInfo(FILES_ID + ".desktop");
        if (app == null) return false;

        add_place(menu, app, File.new_for_path(Environment.get_home_dir()), _("Home"), "user-home-symbolic");
        add_special(menu, app, UserDirectory.DOCUMENTS, _("Documents"), "folder-documents-symbolic");
        add_special(menu, app, UserDirectory.DOWNLOAD, _("Downloads"), "folder-download-symbolic");

        bool separated = false;
        int shown = 0;
        foreach (var bookmark in load_bookmarks()) {
            if (shown >= MAX_BOOKMARKS) break;
            var file = File.new_for_uri(bookmark.uri);
            if (file.query_file_type(FileQueryInfoFlags.NONE) != FileType.DIRECTORY) continue;
            if (!separated) {
                menu.add_separator();
                separated = true;
            }
            string label = bookmark.name != "" ? bookmark.name : (file.get_basename() ?? bookmark.uri);
            add_place(menu, app, file, label, "folder-symbolic");
            shown++;
        }
        return true;
    }

    private void add_special(Singularity.Widgets.ContextMenu menu, DesktopAppInfo app, UserDirectory kind,
                             string label, string icon) {
        string? path = Environment.get_user_special_dir(kind);
        if (path == null || path == Environment.get_home_dir()) return;
        var file = File.new_for_path(path);
        if (!file.query_exists()) return;
        add_place(menu, app, file, label, icon);
    }

    private void add_place(Singularity.Widgets.ContextMenu menu, DesktopAppInfo app, File folder,
                           string label, string icon) {
        string uri = folder.get_uri();
        menu.add_item(label, icon, () => {
            var uris = new List<string>();
            uris.append(uri);
            try {
                app.launch_uris(uris, Gdk.Display.get_default().get_app_launch_context());
            } catch (Error e) {
                warning("Places: cannot open %s: %s", uri, e.message);
            }
        });
    }

    private static GenericArray<Bookmark> load_bookmarks() {
        var result = new GenericArray<Bookmark>();
        string ours = Path.build_filename(Environment.get_user_config_dir(), "singularity", "bookmarks");
        string gtk = Path.build_filename(Environment.get_user_config_dir(), "gtk-3.0", "bookmarks");
        string path = FileUtils.test(ours, FileTest.EXISTS) ? ours : gtk;
        string contents;
        try {
            FileUtils.get_contents(path, out contents);
        } catch (Error e) {
            return result;
        }
        foreach (string raw in contents.split("\n")) {
            string line = raw.strip();
            if (line == "") continue;
            int space = line.index_of_char(' ');
            string uri = space > 0 ? line.substring(0, space) : line;
            string name = space > 0 ? line.substring(space + 1).strip() : "";
            if (!uri.has_prefix("file://")) continue;
            result.add(new Bookmark(uri, name));
        }
        return result;
    }

    private static void bind_translations() {
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link("/proc/self/exe");
            locale_dir = Path.build_filename(Path.get_dirname(Path.get_dirname(exe)), "share", "locale");
        } catch (Error e) { }
        Intl.bindtextdomain("singularity-files", locale_dir);
        Intl.bind_textdomain_codeset("singularity-files", "UTF-8");
    }
}

private class Bookmark : Object {
    public string uri { get; construct; }
    public string name { get; construct; }

    public Bookmark(string uri, string name) {
        Object(uri: uri, name: name);
    }
}

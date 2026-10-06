using Gtk;
using GLib;
using Singularity;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(RecentDocumentsPlugin));
}

public class RecentDocumentsPlugin : Object, Singularity.Plugin, Singularity.DockContextMenuProvider {
    public const string DESKTOP_KEY = "X-Singularity-Dock-Recent";
    private const int MAX_ITEMS = 5;

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
        var app = find_app(request.app_id);
        if (app == null || !app.has_key(DESKTOP_KEY) || !app.get_boolean(DESKTOP_KEY)) return false;
        if (!history_enabled()) return false;
        var items = recent_for(app);
        if (items.length == 0) return false;
        foreach (var info in items) {
            add_entry(menu, app, info);
        }
        return true;
    }

    private void add_entry(Singularity.Widgets.ContextMenu menu, DesktopAppInfo app, RecentInfo info) {
        string uri = info.get_uri();
        string? description = info.get_description();
        string label = info.get_display_name();
        if (description != null && description.strip() != "")
            label = _("%s (%s)").printf(label, description.strip());
        menu.add_item_gicon(label, symbolic_icon(info), () => {
            var uris = new List<string>();
            uris.append(uri);
            try {
                app.launch_uris(uris, Gdk.Display.get_default().get_app_launch_context());
            } catch (Error e) {
                warning("Recent documents: cannot open %s: %s", uri, e.message);
            }
        });
    }

    private static DesktopAppInfo? find_app(string app_id) {
        string id = app_id.has_suffix(".desktop") ? app_id : app_id + ".desktop";
        var app = new DesktopAppInfo(id);
        if (app != null) return app;
        foreach (var candidate in AppInfo.get_all()) {
            string? cid = candidate.get_id();
            if (cid != null && cid.down() == id.down()) return candidate as DesktopAppInfo;
        }
        return null;
    }

    private static bool history_enabled() {
        return Runtime.file_history_enabled();
    }

    private static RecentInfo[] recent_for(DesktopAppInfo app) {
        string? exe = app.get_executable();
        string exe_name = exe != null ? Path.get_basename(exe) : "";
        string app_id = app.get_id() ?? "";
        if (app_id.has_suffix(".desktop")) app_id = app_id.substring(0, app_id.length - 8);
        var matching = new GenericArray<RecentInfo>();
        foreach (var info in RecentManager.get_default().get_items()) {
            if (!recorded_by(info, exe_name, app_id)) continue;
            if (info.is_local() && !info.exists()) continue;
            matching.add(info);
        }
        matching.sort((a, b) => b.get_modified().compare(a.get_modified()));
        RecentInfo[] result = {};
        for (int i = 0; i < matching.length && result.length < MAX_ITEMS; i++)
            result += matching[i];
        return result;
    }

    private static bool recorded_by(RecentInfo info, string exe_name, string app_id) {
        foreach (string name in info.get_applications()) {
            if (name == exe_name || name == app_id) return true;
            unowned string app_exec;
            uint count;
            unowned DateTime stamp;
            if (!info.get_application_info(name, out app_exec, out count, out stamp) || app_exec == null)
                continue;
            string[] argv;
            try {
                GLib.Shell.parse_argv(app_exec, out argv);
                if (argv.length == 1 && argv[0].contains(" ")) GLib.Shell.parse_argv(argv[0], out argv);
            } catch (ShellError e) {
                continue;
            }
            if (argv.length > 0 && Path.get_basename(argv[0]) == exe_name) return true;
        }
        return false;
    }

    private static GLib.Icon symbolic_icon(RecentInfo info) {
        string? mime = info.get_mime_type();
        if (mime != null) {
            string? type = ContentType.from_mime_type(mime);
            if (type != null) return ContentType.get_symbolic_icon(type);
        }
        return new ThemedIcon("text-x-generic-symbolic");
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

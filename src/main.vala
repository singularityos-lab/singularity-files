using Gtk;
using GLib;
using Singularity;

namespace Singularity.Apps {

    public static int main(string[] args) {
        Intl.setlocale(GLib.LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = GLib.FileUtils.read_link("/proc/self/exe");
            locale_dir = GLib.Path.build_filename(GLib.Path.get_dirname(GLib.Path.get_dirname(exe)), "share", "locale");
        } catch (GLib.Error e) { }
        Intl.bindtextdomain("singularity-files", locale_dir);
        Intl.bind_textdomain_codeset("singularity-files", "UTF-8");
        Intl.textdomain("singularity-files");

        // Use a unique app ID in portal mode to avoid connecting to an existing instance.
        string app_id = "dev.sinty.files";
        foreach (var arg in args) {
            if (arg == "--portal-mode") {
                app_id = "dev.sinty.files.portal.p%lld".printf(GLib.get_real_time());
                break;
            }
        }

        var app = new FilesApp(app_id);
        return app.run(args);
    }
}

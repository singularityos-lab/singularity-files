using GLib;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.FilesPlugin), typeof(VideoThumbnailsPlugin));
}

public class VideoThumbnailsPlugin : Object, Singularity.FilesPlugin {
    private Singularity.FilesPluginContext? context = null;
    private VideoIconProvider? provider = null;

    public void activate(Singularity.FilesPluginContext context) {
        this.context = context;
        provider = new VideoIconProvider();
        context.add_file_icon_provider(provider);
    }

    public void deactivate() {
        if (context != null && provider != null) context.remove_file_icon_provider(provider);
        provider = null;
        context = null;
    }
}

public class VideoIconProvider : Object, Singularity.FileIconProvider {
    private const int MAX_PIXELS = 512;
    private const int64 MAX_FILE_BYTES = 16LL * 1024 * 1024 * 1024;

    private GLib.Settings? files_settings = null;

    construct {
        var source = SettingsSchemaSource.get_default();
        if (source != null && source.lookup("dev.sinty.files", true) != null)
            files_settings = new GLib.Settings("dev.sinty.files");
    }

    public bool matches(File file, string? content_type) {
        if (content_type == null || file.get_path() == null) return false;
        if (files_settings != null && !files_settings.get_boolean("show-previews")) return false;
        string mime = ContentType.get_mime_type(content_type) ?? content_type;
        return mime.has_prefix("video/");
    }

    public async Gdk.Paintable? load_icon(File file, int size) {
        try {
            var info = yield file.query_info_async(
                FileAttribute.STANDARD_SIZE,
                FileQueryInfoFlags.NONE);
            if (info.get_size() > MAX_FILE_BYTES) return null;
        } catch (Error e) {
            return null;
        }
        try {
            return yield Singularity.Async.Thumbnails.shared().load(file, int.min(MAX_PIXELS, int.max(64, size * 2)), Singularity.Async.Qos.UTILITY);
        } catch (Error e) {
            return null;
        }
    }
}

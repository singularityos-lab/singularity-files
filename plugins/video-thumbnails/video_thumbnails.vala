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

    private static ThreadPool<VideoThumbnailJob>? pool = null;
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
        int64 mtime = 0;
        string? mime = null;
        try {
            var info = yield file.query_info_async(
                FileAttribute.TIME_MODIFIED + "," + FileAttribute.STANDARD_SIZE + "," + FileAttribute.STANDARD_CONTENT_TYPE,
                FileQueryInfoFlags.NONE);
            if (info.get_size() > MAX_FILE_BYTES) return null;
            mtime = info.get_modification_date_time().to_unix();
            string? type = info.get_content_type();
            if (type != null) mime = ContentType.get_mime_type(type);
        } catch (Error e) {
            return null;
        }
        var job = new VideoThumbnailJob(file.get_uri(), mtime, int.min(MAX_PIXELS, int.max(64, size * 2)), mime);
        SourceFunc callback = load_icon.callback;
        job.done.connect(() => callback());
        try {
            if (pool == null) pool = new ThreadPool<VideoThumbnailJob>.with_owned_data((j) => j.run(), 2, false);
            pool.add(job);
        } catch (ThreadError e) {
            return null;
        }
        yield;
        return job.texture;
    }
}

public class VideoThumbnailJob : Object {
    public string uri { get; construct; }
    public int64 mtime { get; construct; }
    public int pixels { get; construct; }
    public string? mime { get; construct; }
    public Gdk.Texture? texture = null;

    public signal void done();

    public VideoThumbnailJob(string uri, int64 mtime, int pixels, string? mime) {
        Object(uri: uri, mtime: mtime, pixels: pixels, mime: mime);
    }

    public void run() {
        var pixbuf = Singularity.FileSystem.VideoThumbnailer.thumbnail(uri, mtime, pixels, mime);
        if (pixbuf != null) {
            var format = pixbuf.has_alpha ? Gdk.MemoryFormat.R8G8B8A8 : Gdk.MemoryFormat.R8G8B8;
            texture = new Gdk.MemoryTexture(pixbuf.width, pixbuf.height, format,
                pixbuf.read_pixel_bytes(), pixbuf.rowstride);
        }
        Idle.add(() => {
            done();
            return Source.REMOVE;
        });
    }
}

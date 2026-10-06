namespace Singularity.Apps.Files {

    public enum ThumbnailStyle {
        PLAIN,
        PHOTO,
        FILM;

        public static ThumbnailStyle for_content_type(string? content_type) {
            if (content_type == null) return PLAIN;
            string mime = ContentType.get_mime_type(content_type) ?? content_type;
            if (mime.has_prefix("image/")) return PHOTO;
            if (mime.has_prefix("video/")) return FILM;
            return PLAIN;
        }
    }

    public class ThumbnailTheme : Object {
        private static ThumbnailTheme? instance = null;

        public bool dark { get; private set; default = false; }

        public static ThumbnailTheme get_default() {
            if (instance == null) instance = new ThumbnailTheme();
            return instance;
        }

        private ThumbnailTheme() {
            var settings = Gtk.Settings.get_default();
            if (settings == null) return;
            dark = settings.gtk_application_prefer_dark_theme;
            settings.notify["gtk-application-prefer-dark-theme"].connect(() => {
                dark = settings.gtk_application_prefer_dark_theme;
            });
        }
    }

    public class ThumbnailFrame : Object, Gdk.Paintable {
        public Gdk.Paintable picture { get; construct; }
        public ThumbnailStyle style { get; construct; }
        public bool compact { get; construct; }
        public double tilt { get; construct; }

        private ulong theme_handler = 0;

        public ThumbnailFrame(Gdk.Paintable picture, ThumbnailStyle style, bool compact, double tilt = 0.0) {
            Object(picture: picture, style: style, compact: compact, tilt: compact ? 0.0 : tilt);
        }

        construct {
            theme_handler = ThumbnailTheme.get_default().notify["dark"].connect(() => invalidate_contents());
        }

        ~ThumbnailFrame() {
            if (theme_handler != 0) ThumbnailTheme.get_default().disconnect(theme_handler);
        }

        public static double tilt_for(string key) {
            return (double) ((int) (key.hash() % 7) - 3);
        }

        public static Gdk.Paintable decorate(Gdk.Paintable picture, string? content_type, string key, bool compact) {
            var style = ThumbnailStyle.for_content_type(content_type);
            if (style == ThumbnailStyle.PLAIN) return picture;
            return new ThumbnailFrame(picture, style, compact, tilt_for(key));
        }

        public int get_intrinsic_width() {
            return compact ? 24 : 64;
        }

        public int get_intrinsic_height() {
            return compact ? 24 : 64;
        }

        public double get_intrinsic_aspect_ratio() {
            return 1.0;
        }

        private double picture_aspect() {
            double ratio = picture.get_intrinsic_aspect_ratio();
            if (ratio <= 0) ratio = 1.0;
            if (style == ThumbnailStyle.PHOTO) return ratio.clamp(0.75, 4.0 / 3.0);
            return ratio.clamp(1.0, 1.9);
        }

        public void snapshot(Gdk.Snapshot gdk_snapshot, double width, double height) {
            var snapshot = (Gtk.Snapshot) gdk_snapshot;
            bool dark = ThumbnailTheme.get_default().dark;
            double aspect = picture_aspect();

            double side, top, bottom;
            if (style == ThumbnailStyle.PHOTO) {
                side = compact ? 0.08 : 0.06;
                top = side;
                bottom = compact ? 0.16 : 0.22;
            } else {
                side = compact ? 0.0 : 0.035;
                top = compact ? 0.24 : 0.2;
                bottom = top;
            }
            double unit_w = 1.0 + 2 * side;
            double unit_h = 1.0 / aspect + top + bottom;
            double ratio = unit_w / unit_h;

            double margin = compact ? 1.0 : double.max(2.0, double.min(width, height) * 0.08);
            double avail_w = width - 2 * margin;
            double avail_h = height - 2 * margin;
            if (avail_w <= 2 || avail_h <= 2) return;
            double radians = tilt * Math.PI / 180.0;
            double c = Math.fabs(Math.cos(radians));
            double s = Math.fabs(Math.sin(radians));
            double frame_h = double.min(avail_w / (ratio * c + s), avail_h / (ratio * s + c));
            double frame_w = frame_h * ratio;
            double scale = frame_w / unit_w;

            snapshot.save();
            snapshot.translate({ (float) (width / 2), (float) (height / 2) });
            if (tilt != 0.0) snapshot.rotate((float) tilt);
            snapshot.translate({ (float) (-frame_w / 2), (float) (-frame_h / 2) });

            var frame_rect = Graphene.Rect();
            frame_rect.init(0, 0, (float) frame_w, (float) frame_h);
            float radius = style == ThumbnailStyle.PHOTO ? (compact ? 1.5f : 2.5f) : (compact ? 2.0f : 3.0f);
            var rounded = Gsk.RoundedRect();
            rounded.init_from_rect(frame_rect, radius);

            var shadow = Gdk.RGBA() { red = 0, green = 0, blue = 0, alpha = dark ? 0.55f : 0.28f };
            float blur = compact ? 1.5f : (float) double.max(2.0, margin * 0.9);
            snapshot.append_outset_shadow(rounded, shadow, 0, compact ? 0.5f : blur * 0.45f, 0, blur);

            snapshot.push_rounded_clip(rounded);
            snapshot.append_color(frame_color(dark), frame_rect);

            var photo = Graphene.Rect();
            photo.init((float) (side * scale), (float) (top * scale),
                       (float) (scale), (float) (scale / aspect));
            draw_picture(snapshot, photo);

            if (style == ThumbnailStyle.FILM) {
                draw_perforations(snapshot, frame_w, top * scale, 0, dark);
                draw_perforations(snapshot, frame_w, bottom * scale, frame_h - bottom * scale, dark);
                if (!compact && photo.get_height() >= 30) draw_play_mark(snapshot, photo);
            }
            snapshot.pop();

            if (style == ThumbnailStyle.PHOTO || dark) {
                float edge = compact ? 1.0f : 0.8f;
                float strength = style == ThumbnailStyle.FILM ? 0.24f : 0.10f;
                var line = dark ? Gdk.RGBA() { red = 1, green = 1, blue = 1, alpha = strength }
                                : Gdk.RGBA() { red = 0, green = 0, blue = 0, alpha = 0.10f };
                snapshot.append_border(rounded, { edge, edge, edge, edge }, { line, line, line, line });
            }
            snapshot.restore();
        }

        private Gdk.RGBA frame_color(bool dark) {
            if (style == ThumbnailStyle.PHOTO) {
                return dark ? Gdk.RGBA() { red = 0.91f, green = 0.90f, blue = 0.87f, alpha = 1 }
                            : Gdk.RGBA() { red = 0.995f, green = 0.99f, blue = 0.975f, alpha = 1 };
            }
            return dark ? Gdk.RGBA() { red = 0.075f, green = 0.075f, blue = 0.085f, alpha = 1 }
                        : Gdk.RGBA() { red = 0.14f, green = 0.14f, blue = 0.15f, alpha = 1 };
        }

        private void draw_picture(Gtk.Snapshot snapshot, Graphene.Rect area) {
            double source = picture.get_intrinsic_aspect_ratio();
            if (source <= 0) source = area.get_width() / area.get_height();
            double w = area.get_width();
            double h = area.get_height();
            if (source > w / h) {
                w = h * source;
            } else {
                h = w / source;
            }
            snapshot.push_clip(area);
            snapshot.save();
            snapshot.translate({ (float) (area.get_x() + (area.get_width() - w) / 2),
                                 (float) (area.get_y() + (area.get_height() - h) / 2) });
            picture.snapshot(snapshot, w, h);
            snapshot.restore();
            snapshot.pop();
        }

        private void draw_perforations(Gtk.Snapshot snapshot, double width, double band, double y, bool dark) {
            if (band < 2) return;
            double hole_h = double.max(1.0, band * 0.44);
            double hole_w = hole_h * 1.35;
            double gap = hole_w * 0.85;
            int count = (int) Math.floor((width - gap) / (hole_w + gap));
            if (count < 1) return;
            double start = (width - (count * hole_w + (count - 1) * gap)) / 2;
            var color = dark ? Gdk.RGBA() { red = 0.44f, green = 0.44f, blue = 0.46f, alpha = 1 }
                             : Gdk.RGBA() { red = 0.95f, green = 0.945f, blue = 0.93f, alpha = 1 };
            float radius = (float) (hole_h * 0.3);
            for (int i = 0; i < count; i++) {
                var rect = Graphene.Rect();
                rect.init((float) (start + i * (hole_w + gap)), (float) (y + (band - hole_h) / 2),
                          (float) hole_w, (float) hole_h);
                var hole = Gsk.RoundedRect();
                hole.init_from_rect(rect, radius);
                snapshot.push_rounded_clip(hole);
                snapshot.append_color(color, rect);
                snapshot.pop();
            }
        }

        private void draw_play_mark(Gtk.Snapshot snapshot, Graphene.Rect photo) {
            double r = double.min(photo.get_height() * 0.16, 11.0);
            double cx = photo.get_x() + photo.get_width() - r - r * 0.45;
            double cy = photo.get_y() + photo.get_height() - r - r * 0.45;
            var circle = Graphene.Rect();
            circle.init((float) (cx - r), (float) (cy - r), (float) (2 * r), (float) (2 * r));
            var round = Gsk.RoundedRect();
            round.init_from_rect(circle, (float) r);
            snapshot.push_rounded_clip(round);
            snapshot.append_color({ 0, 0, 0, 0.55f }, circle);
            snapshot.pop();
            var builder = new Gsk.PathBuilder();
            double t = r * 0.42;
            builder.move_to((float) (cx - t * 0.7), (float) (cy - t));
            builder.line_to((float) (cx + t), (float) cy);
            builder.line_to((float) (cx - t * 0.7), (float) (cy + t));
            builder.close();
            snapshot.append_fill(builder.to_path(), Gsk.FillRule.WINDING, { 1, 1, 1, 0.95f });
        }
    }
}

namespace Singularity.Apps.Files.Archives {

    public enum ArchiveKind {
        UNKNOWN,
        ZIP,
        SEVEN_ZIP,
        TAR,
        TAR_GZ,
        TAR_BZ2,
        TAR_XZ,
        TAR_ZST,
        RAR,
        ISO,
        CPIO,
        COMPRESSED_FILE;

        public bool can_write() {
            switch (this) {
                case ZIP:
                case SEVEN_ZIP:
                case TAR:
                case TAR_GZ:
                case TAR_BZ2:
                case TAR_XZ:
                case TAR_ZST:
                    return true;
                default:
                    return false;
            }
        }

        public string extension() {
            switch (this) {
                case ZIP: return ".zip";
                case SEVEN_ZIP: return ".7z";
                case TAR: return ".tar";
                case TAR_GZ: return ".tar.gz";
                case TAR_BZ2: return ".tar.bz2";
                case TAR_XZ: return ".tar.xz";
                case TAR_ZST: return ".tar.zst";
                case RAR: return ".rar";
                case ISO: return ".iso";
                case CPIO: return ".cpio";
                default: return "";
            }
        }

        public string label() {
            switch (this) {
                case ZIP: return "ZIP";
                case SEVEN_ZIP: return "7z";
                case TAR: return "tar";
                case TAR_GZ: return "tar.gz";
                case TAR_BZ2: return "tar.bz2";
                case TAR_XZ: return "tar.xz";
                case TAR_ZST: return "tar.zst";
                case RAR: return "RAR";
                case ISO: return "ISO";
                case CPIO: return "cpio";
                case COMPRESSED_FILE: return _("Compressed file");
                default: return _("Unknown");
            }
        }

        public string? writer_format() {
            switch (this) {
                case ZIP: return "zip";
                case SEVEN_ZIP: return "7zip";
                case TAR:
                case TAR_GZ:
                case TAR_BZ2:
                case TAR_XZ:
                case TAR_ZST:
                    return "paxr";
                default:
                    return null;
            }
        }

        public string? writer_filter() {
            switch (this) {
                case TAR_GZ: return "gzip";
                case TAR_BZ2: return "bzip2";
                case TAR_XZ: return "xz";
                case TAR_ZST: return "zstd";
                default: return null;
            }
        }

        public bool has_levels() {
            return can_write() && this != TAR;
        }

        public bool can_store() {
            return this == ZIP || this == SEVEN_ZIP;
        }
    }

    public enum CompressionLevel {
        STORE,
        FAST,
        NORMAL,
        BEST;

        public string label() {
            switch (this) {
                case STORE: return _("No Compression");
                case FAST: return _("Fast");
                case BEST: return _("Smallest");
                default: return _("Normal");
            }
        }
    }

    public class ArchiveFormats : Object {
        private static int encryption_probe = -1;

        private const string[] ARCHIVE_TYPES = {
            "application/zip", "application/x-zip-compressed", "application/x-tar",
            "application/x-compressed-tar", "application/x-bzip-compressed-tar",
            "application/x-bzip2-compressed-tar",
            "application/x-xz-compressed-tar", "application/x-lzma-compressed-tar",
            "application/x-zstd-compressed-tar", "application/x-7z-compressed",
            "application/x-rar", "application/x-rar-compressed", "application/vnd.rar",
            "application/x-cd-image", "application/x-iso9660-image", "application/vnd.efi.iso", "application/x-cpio",
            "application/gzip", "application/x-gzip", "application/x-bzip2", "application/x-bzip",
            "application/x-xz", "application/zstd", "application/x-zstd", "application/x-lzip",
            "application/x-lzma", "application/vnd.ms-cab-compressed", "application/x-archive"
        };

        public static bool is_archive_type(string? content_type) {
            if (content_type == null) return false;
            foreach (unowned string t in ARCHIVE_TYPES) {
                if (content_type == t) return true;
            }
            return false;
        }

        public static bool is_archive_name(string name) {
            return from_name(name) != ArchiveKind.UNKNOWN || split_first_volume(name) != null;
        }

        public static ArchiveKind from_name(string name) {
            string n = name.down();
            string? inner = split_first_volume(n);
            if (inner != null) n = inner;
            if (n.has_suffix(".tar.gz") || n.has_suffix(".tgz")) return ArchiveKind.TAR_GZ;
            if (n.has_suffix(".tar.bz2") || n.has_suffix(".tbz2") || n.has_suffix(".tbz")) return ArchiveKind.TAR_BZ2;
            if (n.has_suffix(".tar.xz") || n.has_suffix(".txz")) return ArchiveKind.TAR_XZ;
            if (n.has_suffix(".tar.zst") || n.has_suffix(".tzst")) return ArchiveKind.TAR_ZST;
            if (n.has_suffix(".tar")) return ArchiveKind.TAR;
            if (n.has_suffix(".zip")) return ArchiveKind.ZIP;
            if (n.has_suffix(".7z")) return ArchiveKind.SEVEN_ZIP;
            if (n.has_suffix(".rar")) return ArchiveKind.RAR;
            if (n.has_suffix(".iso")) return ArchiveKind.ISO;
            if (n.has_suffix(".cpio")) return ArchiveKind.CPIO;
            if (n.has_suffix(".gz") || n.has_suffix(".bz2") || n.has_suffix(".xz")
                || n.has_suffix(".zst") || n.has_suffix(".lz") || n.has_suffix(".lzma")) {
                return ArchiveKind.COMPRESSED_FILE;
            }
            return ArchiveKind.UNKNOWN;
        }

        public static ArchiveKind from_magic(uint8[] head, string name) {
            int n = head.length;
            if (n >= 4 && head[0] == 'P' && head[1] == 'K'
                && ((head[2] == 3 && head[3] == 4) || (head[2] == 5 && head[3] == 6) || (head[2] == 7 && head[3] == 8))) {
                return ArchiveKind.ZIP;
            }
            if (n >= 6 && head[0] == '7' && head[1] == 'z' && head[2] == 0xBC && head[3] == 0xAF
                && head[4] == 0x27 && head[5] == 0x1C) {
                return ArchiveKind.SEVEN_ZIP;
            }
            if (n >= 6 && head[0] == 'R' && head[1] == 'a' && head[2] == 'r' && head[3] == '!'
                && head[4] == 0x1A && head[5] == 0x07) {
                return ArchiveKind.RAR;
            }
            ArchiveKind by_name = from_name(name);
            bool tar_name = by_name == ArchiveKind.TAR_GZ || by_name == ArchiveKind.TAR_BZ2
                || by_name == ArchiveKind.TAR_XZ || by_name == ArchiveKind.TAR_ZST;
            if (n >= 2 && head[0] == 0x1F && head[1] == 0x8B) {
                return tar_name ? ArchiveKind.TAR_GZ : ArchiveKind.COMPRESSED_FILE;
            }
            if (n >= 3 && head[0] == 'B' && head[1] == 'Z' && head[2] == 'h') {
                return tar_name ? ArchiveKind.TAR_BZ2 : ArchiveKind.COMPRESSED_FILE;
            }
            if (n >= 6 && head[0] == 0xFD && head[1] == '7' && head[2] == 'z' && head[3] == 'X'
                && head[4] == 'Z' && head[5] == 0) {
                return tar_name ? ArchiveKind.TAR_XZ : ArchiveKind.COMPRESSED_FILE;
            }
            if (n >= 4 && head[0] == 0x28 && head[1] == 0xB5 && head[2] == 0x2F && head[3] == 0xFD) {
                return tar_name ? ArchiveKind.TAR_ZST : ArchiveKind.COMPRESSED_FILE;
            }
            if (n >= 262 && head[257] == 'u' && head[258] == 's' && head[259] == 't'
                && head[260] == 'a' && head[261] == 'r') {
                return ArchiveKind.TAR;
            }
            if (n >= 0x8006 && head[0x8001] == 'C' && head[0x8002] == 'D' && head[0x8003] == '0'
                && head[0x8004] == '0' && head[0x8005] == '1') {
                return ArchiveKind.ISO;
            }
            if (n >= 6 && head[0] == '0' && head[1] == '7' && head[2] == '0' && head[3] == '7'
                && head[4] == '0' && (head[5] == '1' || head[5] == '2' || head[5] == '7')) {
                return ArchiveKind.CPIO;
            }
            return by_name;
        }

        public static ArchiveKind detect(string path) {
            string name = Path.get_basename(path);
            uint8[] head = new uint8[0x8010];
            size_t got = 0;
            var stream = FileStream.open(path, "rb");
            if (stream != null) got = stream.read(head);
            head.resize((int) got);
            return from_magic(head, name);
        }

        public static string? split_first_volume(string name) {
            if (name.length > 4 && name.has_suffix(".001")) return name.substring(0, name.length - 4);
            return null;
        }

        public static string[] volume_paths(string path) {
            string? stem = split_first_volume(path);
            if (stem == null) return { path };
            string[] parts = {};
            for (int i = 1; i < 10000; i++) {
                string part = "%s.%03d".printf(stem, i);
                if (!FileUtils.test(part, FileTest.EXISTS)) break;
                parts += part;
            }
            return parts;
        }

        public static string stem(string name) {
            string n = name;
            string? inner = split_first_volume(n);
            if (inner != null) n = inner;
            string lower = n.down();
            foreach (unowned string ext in new string[] {
                ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tgz", ".tbz2", ".tbz", ".txz", ".tzst",
                ".tar", ".zip", ".7z", ".rar", ".iso", ".cpio", ".gz", ".bz2", ".xz", ".zst", ".lz", ".lzma"
            }) {
                if (lower.has_suffix(ext) && n.length > ext.length) return n.substring(0, n.length - ext.length);
            }
            return n;
        }

        public static string options_for(ArchiveKind kind, CompressionLevel level, bool encrypt) {
            string[] opts = {};
            switch (kind) {
                case ArchiveKind.ZIP:
                    if (level == CompressionLevel.STORE) {
                        opts += "zip:compression=store";
                    } else {
                        opts += "zip:compression=deflate";
                        opts += "zip:compression-level=%d".printf(numeric_level(kind, level));
                    }
                    if (encrypt) opts += "zip:encryption=aes256";
                    break;
                case ArchiveKind.SEVEN_ZIP:
                    if (level == CompressionLevel.STORE) {
                        opts += "7zip:compression=store";
                    } else {
                        opts += "7zip:compression=lzma2";
                        opts += "7zip:compression-level=%d".printf(numeric_level(kind, level));
                    }
                    break;
                case ArchiveKind.TAR_GZ:
                case ArchiveKind.TAR_BZ2:
                case ArchiveKind.TAR_XZ:
                case ArchiveKind.TAR_ZST:
                    opts += "%s:compression-level=%d".printf(kind.writer_filter(), numeric_level(kind, level));
                    break;
                default:
                    break;
            }
            return string.joinv(",", opts);
        }

        public static int numeric_level(ArchiveKind kind, CompressionLevel level) {
            if (level == CompressionLevel.STORE) return 0;
            if (kind == ArchiveKind.TAR_ZST) {
                switch (level) {
                    case CompressionLevel.FAST: return 1;
                    case CompressionLevel.BEST: return 19;
                    default: return 3;
                }
            }
            if (kind == ArchiveKind.SEVEN_ZIP) {
                switch (level) {
                    case CompressionLevel.FAST: return 1;
                    case CompressionLevel.BEST: return 9;
                    default: return 5;
                }
            }
            switch (level) {
                case CompressionLevel.FAST: return 1;
                case CompressionLevel.BEST: return 9;
                default: return 6;
            }
        }

        public static bool supports_encryption(ArchiveKind kind) {
            if (kind != ArchiveKind.ZIP) return false;
            if (encryption_probe < 0) {
                var w = new LA.Writer();
                bool ok = w.set_format_by_name("zip") == LA.OK
                    && w.set_options("zip:encryption=aes256") == LA.OK;
                encryption_probe = ok ? 1 : 0;
            }
            return encryption_probe == 1;
        }

        public static bool supports_writing(ArchiveKind kind) {
            string? format = kind.writer_format();
            if (format == null) return false;
            var w = new LA.Writer();
            if (w.set_format_by_name(format) != LA.OK) return false;
            string? filter = kind.writer_filter();
            if (filter != null && w.add_filter_by_name(filter) != LA.OK) return false;
            return true;
        }

        public static string ratio_text(int64 compressed, int64 uncompressed) {
            if (uncompressed <= 0) return "";
            double pct = 100.0 * (double) compressed / (double) uncompressed;
            if (pct >= 100.0) return _("%.0f%% of the original size, no space saved").printf(pct);
            return _("%.0f%% of the original size, %.0f%% saved").printf(pct, 100.0 - pct);
        }
    }
}

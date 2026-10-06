namespace Singularity.Apps.Files.Archives {

    public class ArchivePaths : Object {

        public static string? sanitize(string? entry_path) {
            if (entry_path == null) return null;
            string p = entry_path;
            if (p == "") return null;
            if (p.has_prefix("/") || p.has_prefix("\\")) return null;
            if (p.length >= 3 && p[1] == ':' && (p[2] == '/' || p[2] == '\\')) return null;
            string[] kept = {};
            foreach (unowned string raw in p.replace("\\", "/").split("/")) {
                if (raw == "" || raw == ".") continue;
                if (raw == "..") return null;
                kept += raw;
            }
            if (kept.length == 0) return null;
            return string.joinv("/", kept);
        }

        public static bool link_stays_inside(string entry_rel, string? target) {
            if (target == null || target == "") return false;
            if (target.has_prefix("/") || target.has_prefix("\\")) return false;
            string[] stack = {};
            string[] entry_parts = entry_rel.split("/");
            for (int i = 0; i < entry_parts.length - 1; i++) {
                if (entry_parts[i] != "") stack += entry_parts[i];
            }
            foreach (unowned string part in target.replace("\\", "/").split("/")) {
                if (part == "" || part == ".") continue;
                if (part == "..") {
                    if (stack.length == 0) return false;
                    stack.resize(stack.length - 1);
                } else {
                    stack += part;
                }
            }
            return true;
        }

        public static string unique_sibling(string path) {
            if (!FileUtils.test(path, FileTest.EXISTS) && !FileUtils.test(path, FileTest.IS_SYMLINK)) return path;
            string dir = Path.get_dirname(path);
            string name = Path.get_basename(path);
            string stem = name;
            string ext = "";
            string lower = name.down();
            foreach (unowned string dext in new string[] { ".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst" }) {
                if (lower.has_suffix(dext) && name.length > dext.length) {
                    stem = name.substring(0, name.length - dext.length);
                    ext = name.substring(name.length - dext.length);
                    break;
                }
            }
            if (ext == "") {
                int dot = name.last_index_of(".");
                if (dot > 0 && name.length - dot <= 6) {
                    stem = name.substring(0, dot);
                    ext = name.substring(dot);
                }
            }
            for (int n = 2; n < 100000; n++) {
                string candidate = Path.build_filename(dir, "%s (%d)%s".printf(stem, n, ext));
                if (!FileUtils.test(candidate, FileTest.EXISTS) && !FileUtils.test(candidate, FileTest.IS_SYMLINK)) {
                    return candidate;
                }
            }
            return path;
        }

        public static void set_tree_writable(string path, bool writable) {
            Posix.Stat st;
            if (Posix.lstat(path, out st) != 0) return;
            if (Posix.S_ISLNK(st.st_mode)) return;
            if (Posix.S_ISDIR(st.st_mode)) {
                if (writable) Posix.chmod(path, 0755);
                try {
                    var dir = Dir.open(path);
                    unowned string? name;
                    while ((name = dir.read_name()) != null) {
                        set_tree_writable(Path.build_filename(path, name), writable);
                    }
                } catch (FileError e) {
                }
                if (!writable) Posix.chmod(path, 0555);
            } else {
                Posix.chmod(path, writable ? (st.st_mode & 07777) | 0200 : (st.st_mode & 07555));
            }
        }

        public static void remove_tree(string path) {
            Posix.Stat st;
            if (Posix.lstat(path, out st) != 0) return;
            if (Posix.S_ISDIR(st.st_mode) && !Posix.S_ISLNK(st.st_mode)) {
                Posix.chmod(path, 0755);
                try {
                    var dir = Dir.open(path);
                    unowned string? name;
                    string[] names = {};
                    while ((name = dir.read_name()) != null) names += name;
                    foreach (unowned string n in names) remove_tree(Path.build_filename(path, n));
                } catch (FileError e) {
                }
                DirUtils.remove(path);
            } else {
                FileUtils.unlink(path);
            }
        }
    }
}

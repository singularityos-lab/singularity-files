using GLib;
using Gee;

namespace Singularity.Apps.Files {

    public class SizeReport : Object {
        public int64 bytes = 0;
        public int   files = 0;
    }

    public class FileOp : Object {
        public string id;
        public string display_name;   
        public bool   is_move;
        public int64  total_bytes = 0;
        public int64  done_bytes = 0;
        public int    total_files = 0;
        public int    done_files = 0;
        public bool   finished { get; set; default = false; } 
        public bool   errored = false;
        public string? error_message = null;
        public Cancellable cancellable = new Cancellable();

        // Explicit completion signal - more reliable than `notify["finished"]`
        // (which only fires when `finished` is a proper GObject property AND
        // the caller successfully connects to it via the right name).
        public signal void completed();
    }

    /**
     * Singleton-ish manager for long-running file operations in singularity-files.
     *
     * Responsibilities:
     *   1. Run copy/move recursively with byte-accurate progress reporting.
     *   2. Aggregate progress across all concurrent operations.
     *   3. Emit the Unity LauncherEntry DBus signal so the dock (or any
     *      LauncherEntry-aware launcher) can surface ambient progress.
     *   4. Expose a `state_changed` signal so the in-app banner UI can
     *      redraw without polling.
     *
     * The aggregate progress used for the LauncherEntry signal is byte-based
     * across all operations: sum(done_bytes) / sum(total_bytes).
     */
    public class FileOpsManager : Object {
        public signal void state_changed();

        public Gee.ArrayList<FileOp> ops = new Gee.ArrayList<FileOp>();
        private DBusConnection? _conn = null;
        private int _id_counter = 0;
        // Coalesce LauncherEntry signal emissions so a copy progressing rapidly
        // doesn't flood DBus. We at most emit ~10/s.
        private uint _emit_idle = 0;

        public FileOpsManager() {
            try { _conn = Bus.get_sync(BusType.SESSION); }
            catch (Error e) { warning("FileOpsManager: bus get failed: %s", e.message); }
        }

        /**
         * Start a copy or move operation across `sources` into `dest_folder`.
         * Returns the FileOp handle; the manager runs it asynchronously and
         * reports progress via `state_changed`.
         */
        public FileOp start_transfer(GLib.File[] sources, GLib.File dest_folder, bool is_move) {
            // Copy the array contents into an ArrayList right away. The
            // array literal at the callsite (often `new GLib.File[] { src }`)
            // is stack-allocated and its lifetime ends when the caller
            // returns - passing it directly through an async chain would
            // leave the .begin() captures referencing freed memory once
            // the call yields control back to the main loop.
            var list = new Gee.ArrayList<GLib.File>();
            foreach (var s in sources) list.add(s);

            var op = new FileOp();
            op.id = "fop-%d".printf(++_id_counter);
            op.is_move = is_move;
            op.display_name = list.size == 1
                ? "%s %s".printf(is_move ? "Moving" : "Copying", list[0].get_basename() ?? "?")
                : "%s %d items to %s".printf(is_move ? "Moving" : "Copying",
                    list.size, dest_folder.get_basename() ?? "/");
            ops.add(op);
            state_changed();
            // Emit IMMEDIATELY at start (skipping the debounce) so the dock
            // sees the in-progress state even when the actual transfer is
            // shorter than the debounce window (small-file copies finish in
            // < 100 ms and would otherwise never get a visible emit).
            emit_launcher_entry();
            run_transfer.begin(op, list, dest_folder);
            return op;
        }

        public FileOp start_trash(GLib.File[] sources) {
            var list = new Gee.ArrayList<GLib.File>();
            foreach (var s in sources) list.add(s);

            var op = new FileOp();
            op.id = "fop-%d".printf(++_id_counter);
            op.is_move = true;
            op.display_name = list.size == 1
                ? "Moving %s to Trash".printf(list[0].get_basename() ?? "?")
                : "Moving %d items to Trash".printf(list.size);
            op.total_files = list.size;
            ops.add(op);
            state_changed();
            emit_launcher_entry();
            run_trash.begin(op, list);
            return op;
        }

        // ── Async runners ─────────────────────────────────────────────────────

        private async void run_transfer(FileOp op, Gee.ArrayList<GLib.File> sources, GLib.File dest_folder) {
            // Phase 1: walk to compute total size + file count so the progress
            // bar can be byte-accurate even on multi-GB folders.
            int64 total = 0;
            int total_files = 0;
            foreach (var src in sources) {
                if (op.cancellable.is_cancelled()) break;
                try {
                    var rep = yield compute_size(src, op.cancellable);
                    total += rep.bytes;
                    total_files += rep.files;
                } catch (Error e) {
                    // Skip unreadable items in the precount; surface errors
                    // during the actual transfer instead.
                }
            }
            op.total_bytes = total;
            op.total_files = total_files;
            schedule_emit();

            // Phase 2: do the copy / move.
            foreach (var src in sources) {
                if (op.cancellable.is_cancelled()) break;
                var dst = dest_folder.get_child(src.get_basename());
                try {
                    yield transfer_recursive(src, dst, op);
                } catch (Error e) {
                    op.errored = true;
                    op.error_message = e.message;
                    break;
                }
            }
            finalize_op(op);
        }

        private async void run_trash(FileOp op, Gee.ArrayList<GLib.File> sources) {
            foreach (var src in sources) {
                if (op.cancellable.is_cancelled()) break;
                try {
                    yield src.trash_async(GLib.Priority.DEFAULT, op.cancellable);
                } catch (Error e) {
                    op.errored = true;
                    op.error_message = e.message;
                }
                op.done_files++;
                schedule_emit();
                state_changed();
            }
            finalize_op(op);
        }

        // ── Recursive transfer ────────────────────────────────────────────────

        private async void transfer_recursive(GLib.File src, GLib.File dst, FileOp op)
                throws Error {
            if (op.cancellable.is_cancelled()) return;
            var info = yield src.query_info_async(
                "standard::type,standard::size,standard::name",
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
                GLib.Priority.DEFAULT, op.cancellable);

            // If we're moving and src and dst are on the same filesystem,
            // GFile.move_async will use rename() under the hood - instant.
            // We attempt this for ALL items (file or directory) first; on
            // EXDEV (cross-device) we fall back to copy + delete.
            if (op.is_move) {
                try {
                    int64 before = op.done_bytes;
                    yield src.move_async(dst,
                        FileCopyFlags.NONE,
                        GLib.Priority.DEFAULT,
                        op.cancellable,
                        (current, total) => {
                            op.done_bytes = before + current;
                            schedule_emit();
                            state_changed();
                        });
                    op.done_bytes = before + info.get_size();
                    op.done_files++;
                    schedule_emit();
                    state_changed();
                    return;
                } catch (IOError e) {
                    if (!(e is IOError.WOULD_RECURSE) && !(e is IOError.NOT_SUPPORTED)
                        && !(e is IOError.EXISTS)) {
                        throw e;
                    }
                    // Fall through to manual recursive copy + delete.
                }
            }

            if (info.get_file_type() == FileType.DIRECTORY) {
                // Create destination dir, then recurse into children.
                try { dst.make_directory(op.cancellable); }
                catch (IOError e) { if (!(e is IOError.EXISTS)) throw e; }

                var enumerator = yield src.enumerate_children_async(
                    "standard::name",
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
                    GLib.Priority.DEFAULT, op.cancellable);
                while (true) {
                    if (op.cancellable.is_cancelled()) break;
                    var batch = yield enumerator.next_files_async(20,
                        GLib.Priority.DEFAULT, op.cancellable);
                    if (batch == null || batch.length() == 0) break;
                    foreach (var ch_info in batch) {
                        var child_src = src.get_child(ch_info.get_name());
                        var child_dst = dst.get_child(ch_info.get_name());
                        yield transfer_recursive(child_src, child_dst, op);
                    }
                }

                if (op.is_move && !op.cancellable.is_cancelled()) {
                    // Source dir should now be empty - remove it.
                    try { yield src.delete_async(GLib.Priority.DEFAULT, op.cancellable); }
                    catch (Error e) { warning("FileOpsManager rmdir: %s", e.message); }
                }
                op.done_files++;
                schedule_emit();
                state_changed();
            } else {
                // Regular file (or symlink we don't follow) - copy.
                int64 before = op.done_bytes;
                yield src.copy_async(dst,
                    FileCopyFlags.NONE,
                    GLib.Priority.DEFAULT,
                    op.cancellable,
                    (current, total) => {
                        op.done_bytes = before + current;
                        schedule_emit();
                        state_changed();
                    });
                op.done_bytes = before + info.get_size();
                op.done_files++;
                if (op.is_move) {
                    try { yield src.delete_async(GLib.Priority.DEFAULT, op.cancellable); }
                    catch (Error e) { warning("FileOpsManager rm: %s", e.message); }
                }
                schedule_emit();
                state_changed();
            }
        }

        // ── Helpers ───────────────────────────────────────────────────────────

        private async SizeReport compute_size(GLib.File f, Cancellable? cancel) throws Error {
            var rep = new SizeReport();
            FileInfo? info = null;
            try {
                info = yield f.query_info_async(
                    "standard::type,standard::size",
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
                    GLib.Priority.DEFAULT, cancel);
            } catch { return rep; }
            if (info == null) return rep;

            if (info.get_file_type() == FileType.DIRECTORY) {
                rep.files++;
                FileEnumerator? en = null;
                try {
                    en = yield f.enumerate_children_async("standard::name",
                        FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
                        GLib.Priority.DEFAULT, cancel);
                } catch { return rep; }
                while (true) {
                    if (cancel != null && cancel.is_cancelled()) break;
                    GLib.List<FileInfo>? b = null;
                    try {
                        b = yield en.next_files_async(50, GLib.Priority.DEFAULT, cancel);
                    } catch { break; }
                    if (b == null || b.length() == 0) break;
                    foreach (var ch in b) {
                        try {
                            var sub = yield compute_size(f.get_child(ch.get_name()), cancel);
                            rep.bytes += sub.bytes;
                            rep.files += sub.files;
                        } catch { /* ignore */ }
                    }
                }
            } else {
                rep.bytes += info.get_size();
                rep.files++;
            }
            return rep;
        }

        private void finalize_op(FileOp op) {
            // Fire `completed` synchronously so callers (e.g. paste_files →
            // navigate_to) react right away.
            op.completed();
            // Hold the op visible at 100% briefly so even instant copies
            // produce a flash of feedback in the dock badge / banner.
            if (op.total_bytes > 0 && op.done_bytes < op.total_bytes)
                op.done_bytes = op.total_bytes;
            if (op.total_files > 0 && op.done_files < op.total_files)
                op.done_files = op.total_files;
            emit_launcher_entry();
            state_changed();

            GLib.Timeout.add(1500, () => {
                op.finished = true;
                emit_launcher_entry();
                state_changed();
                // Then remove from list (UI banner clears too) after a
                // linger window. Errored ops linger longer.
                int linger = op.errored ? 12 : 3;
                GLib.Timeout.add_seconds(linger, () => {
                    ops.remove(op);
                    emit_launcher_entry();
                    state_changed();
                    return GLib.Source.REMOVE;
                });
                return GLib.Source.REMOVE;
            });
        }

        public double aggregate_fraction() {
            int64 t = 0, d = 0;
            int tf = 0, df = 0;
            foreach (var o in ops) {
                if (o.finished) continue;
                t += int64.max(0, o.total_bytes);
                d += o.done_bytes;
                tf += o.total_files;
                df += o.done_files;
            }
            if (t > 0) return ((double) d / (double) t).clamp(0, 1);
            // Fallback when we don't have byte-accurate counts (e.g. trash).
            if (tf > 0) return ((double) df / (double) tf).clamp(0, 1);
            return 0;
        }

        public int active_count() {
            int n = 0;
            foreach (var o in ops) if (!o.finished) n++;
            return n;
        }

        // ── LauncherEntry signal ──────────────────────────────────────────────

        private void schedule_emit() {
            if (_emit_idle != 0) return;
            _emit_idle = GLib.Timeout.add(100, () => {  // ~10 Hz
                _emit_idle = 0;
                emit_launcher_entry();
                return GLib.Source.REMOVE;
            });
        }

        private void emit_launcher_entry() {
            if (_conn == null) return;
            int active = active_count();
            double progress = aggregate_fraction();
            // Always emit - even when ops are 0, so the dock badge clears
            // immediately when the last op finishes.
            var props = new VariantBuilder(VariantType.VARDICT);
            props.add("{sv}", "count", new Variant.int64((int64) active));
            props.add("{sv}", "count-visible", new Variant.boolean(active > 0));
            props.add("{sv}", "progress", new Variant.double(progress));
            props.add("{sv}", "progress-visible", new Variant.boolean(active > 0));

            // Non-standard but well-tolerated extension: a human-readable
            // label describing what's happening. Generic LauncherEntry
            // consumers ignore unknown keys; ours surfaces it as a name on
            // the dock widget. With multiple concurrent ops we collapse to
            // a summary string.
            if (active > 0) {
                string label;
                if (active == 1) {
                    label = "Working…";
                    foreach (var o in ops) {
                        if (!o.finished) { label = o.display_name; break; }
                    }
                } else {
                    label = "%d file operations".printf(active);
                }
                props.add("{sv}", "label", new Variant.string(label));
            }

            try {
                _conn.emit_signal(null,
                    "/com/canonical/Unity/LauncherEntry",
                    "com.canonical.Unity.LauncherEntry",
                    "Update",
                    new Variant.tuple({
                        new Variant.string("application://dev.sinty.files.desktop"),
                        props.end()
                    }));
            } catch (Error e) {
                warning("emit_launcher_entry: %s", e.message);
            }
        }
    }
}

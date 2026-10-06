using GLib;
using Gee;

namespace Singularity.Apps.Files {

    public class SizeReport : Object {
        public int64 bytes = 0;
        public int   files = 0;
    }

    public enum ConflictChoice {
        REPLACE,
        KEEP_BOTH,
        SKIP,
        MERGE,
        CANCEL
    }

    public class ConflictRequest : Object {
        public FileOp op;
        public GLib.File source;
        public GLib.File target;
        public FileInfo source_info;
        public FileInfo target_info;
        public string suggested_name;
        public ConflictChoice choice = ConflictChoice.SKIP;
        public bool apply_all = false;
        public string? new_name = null;
        internal SourceFunc? resume = null;

        public bool both_folders {
            get {
                return source_info.get_file_type() == FileType.DIRECTORY
                    && target_info.get_file_type() == FileType.DIRECTORY;
            }
        }

        public void answer(ConflictChoice choice, bool apply_all, string? new_name = null) {
            this.choice = choice;
            this.apply_all = apply_all;
            this.new_name = new_name;
            if (resume != null) {
                SourceFunc callback = (owned) resume;
                resume = null;
                Idle.add((owned) callback);
            }
        }
    }

    public class ArchivePasswordRequest : Object {
        public string archive_name;
        public bool retry;
        private bool answered = false;
        public signal void done(string? password);

        public ArchivePasswordRequest(string archive_name, bool retry) {
            this.archive_name = archive_name;
            this.retry = retry;
        }

        public void answer(string? password) {
            if (answered) return;
            answered = true;
            done(password);
        }
    }

    public class ThreadGate {
        private Mutex mutex = Mutex();
        private Cond cond = Cond();
        private bool opened = false;

        public void open() {
            mutex.lock();
            opened = true;
            cond.broadcast();
            mutex.unlock();
        }

        public void wait() {
            mutex.lock();
            while (!opened) cond.wait(mutex);
            mutex.unlock();
        }
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
        public int file_policy = -1;
        public int folder_policy = -1;
        public int skipped = 0;
        public bool waiting { get; set; default = false; }
        public string kind = "transfer";
        public string? result_path = null;

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
        public signal void conflict(ConflictRequest request);
        public signal void password_needed(ArchivePasswordRequest request);

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

        public FileOp start_extract(Archives.ArchiveExtractor extractor, string display_name) {
            var op = new FileOp();
            op.id = "fop-%d".printf(++_id_counter);
            op.kind = "extract";
            op.display_name = display_name;
            op.total_bytes = Archives.ArchiveReader.input_size(extractor.archive_path);
            extractor.cancellable = op.cancellable;
            string archive_name = Path.get_basename(extractor.archive_path);
            extractor.set_resolver((entry, dest_path, out new_name) => {
                return resolve_from_thread(op, entry, dest_path, out new_name);
            });
            extractor.set_password_provider((retry) => {
                return password_from_thread(op, archive_name, retry);
            });
            ops.add(op);
            state_changed();
            emit_launcher_entry();
            run_archive_job(op, () => {
                extractor.run();
                op.result_path = extractor.result_path;
            }, () => {
                op.done_bytes = extractor.done_bytes;
                op.total_bytes = int64.max(extractor.total_bytes, 1);
                op.skipped = extractor.skipped;
            });
            return op;
        }

        public FileOp start_create(Archives.ArchiveCreator creator) {
            var op = new FileOp();
            op.id = "fop-%d".printf(++_id_counter);
            op.kind = "create";
            op.display_name = _("Creating %s").printf(Path.get_basename(creator.output_path));
            creator.cancellable = op.cancellable;
            ops.add(op);
            state_changed();
            emit_launcher_entry();
            run_archive_job(op, () => {
                creator.run();
                op.result_path = creator.outputs.length > 0 ? creator.outputs[0] : creator.output_path;
            }, () => {
                op.done_bytes = creator.done_bytes;
                op.total_bytes = int64.max(creator.total_bytes, 1);
            });
            return op;
        }

        public delegate void ArchiveWork() throws Error;
        public delegate void ArchivePoll();

        private void run_archive_job(FileOp op, owned ArchiveWork work, owned ArchivePoll poll) {
            bool running = true;
            uint ticker = GLib.Timeout.add(100, () => {
                poll();
                schedule_emit();
                state_changed();
                return running ? GLib.Source.CONTINUE : GLib.Source.REMOVE;
            });
            new Thread<bool>("files-archive", () => {
                Error? failure = null;
                try {
                    work();
                } catch (Error e) {
                    failure = e;
                }
                GLib.Idle.add(() => {
                    running = false;
                    GLib.Source.remove(ticker);
                    poll();
                    if (failure is IOError.CANCELLED) op.cancellable.cancel();
                    if (failure != null && !(failure is IOError.CANCELLED)) {
                        op.errored = true;
                        op.error_message = failure.message;
                    }
                    finalize_op(op);
                    return GLib.Source.REMOVE;
                });
                return true;
            });
        }

        private Archives.ExtractChoice resolve_from_thread(FileOp op, Archives.ArchiveEntryInfo entry, string dest_path, out string? new_name) {
            var gate = new ThreadGate();
            ConflictRequest? answer = null;
            GLib.Idle.add(() => {
                var target = GLib.File.new_for_path(dest_path);
                FileInfo target_info;
                try {
                    target_info = target.query_info(COMPARE_ATTRS, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                } catch (Error e) {
                    target_info = new FileInfo();
                    target_info.set_name(target.get_basename());
                    target_info.set_display_name(target.get_basename());
                }
                var src_info = new FileInfo();
                string base_name = Path.get_basename(entry.path);
                src_info.set_name(base_name);
                src_info.set_display_name(base_name);
                src_info.set_size(entry.size);
                src_info.set_file_type(entry.is_dir ? FileType.DIRECTORY : FileType.REGULAR);
                string ctype = entry.is_dir ? "inode/directory" : ContentType.guess(base_name, null, null);
                src_info.set_content_type(ctype);
                src_info.set_icon(ContentType.get_icon(ctype));
                src_info.set_modification_date_time(new DateTime.from_unix_utc(entry.mtime));
                var req = new ConflictRequest();
                req.op = op;
                req.source = GLib.File.new_for_path(Path.build_filename("/nonexistent-archive-entry", entry.path));
                req.target = target;
                req.source_info = src_info;
                req.target_info = target_info;
                var parent = target.get_parent();
                req.suggested_name = parent != null ? unique_name(parent, target.get_basename()) : target.get_basename();
                answer = req;
                int policy = req.both_folders ? op.folder_policy : op.file_policy;
                if (policy >= 0) {
                    req.choice = (ConflictChoice) policy;
                    gate.open();
                    return GLib.Source.REMOVE;
                }
                op.waiting = true;
                state_changed();
                req.resume = () => {
                    op.waiting = false;
                    if (req.apply_all && req.choice != ConflictChoice.CANCEL) {
                        if (req.both_folders) op.folder_policy = (int) req.choice;
                        else op.file_policy = (int) req.choice;
                    }
                    state_changed();
                    gate.open();
                    return GLib.Source.REMOVE;
                };
                conflict(req);
                return GLib.Source.REMOVE;
            });
            gate.wait();
            new_name = answer.new_name;
            switch (answer.choice) {
                case ConflictChoice.REPLACE:
                case ConflictChoice.MERGE:
                    return Archives.ExtractChoice.REPLACE;
                case ConflictChoice.KEEP_BOTH:
                    return Archives.ExtractChoice.KEEP_BOTH;
                case ConflictChoice.CANCEL:
                    return Archives.ExtractChoice.CANCEL;
                default:
                    return Archives.ExtractChoice.SKIP;
            }
        }

        private string? password_from_thread(FileOp op, string archive_name, bool retry) {
            var gate = new ThreadGate();
            string? result = null;
            GLib.Idle.add(() => {
                var req = new ArchivePasswordRequest(archive_name, retry);
                op.waiting = true;
                state_changed();
                req.done.connect((pw) => {
                    result = pw;
                    op.waiting = false;
                    state_changed();
                    gate.open();
                });
                password_needed(req);
                return GLib.Source.REMOVE;
            });
            gate.wait();
            return result;
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

        private const string COMPARE_ATTRS = "standard::type,standard::size,standard::name,standard::display-name,standard::icon,standard::content-type,time::modified,thumbnail::path";

        public static string unique_name(GLib.File folder, string name) {
            string stem = name;
            string ext = "";
            string lower = name.down();
            foreach (string double_ext in new string[] { ".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst" }) {
                if (lower.has_suffix(double_ext) && name.length > double_ext.length) {
                    stem = name.substring(0, name.length - double_ext.length);
                    ext = name.substring(name.length - double_ext.length);
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
            int n = 2;
            try {
                var re = new Regex("^(.*) \\((\\d+)\\)$");
                MatchInfo m;
                if (re.match(stem, 0, out m)) {
                    stem = m.fetch(1);
                    n = int.parse(m.fetch(2)) + 1;
                }
            } catch (RegexError e) {
            }
            while (true) {
                string candidate = "%s (%d)%s".printf(stem, n, ext);
                if (!folder.get_child(candidate).query_exists()) return candidate;
                n++;
            }
        }

        private async ConflictRequest ask(FileOp op, GLib.File src, GLib.File dst, FileInfo src_info, FileInfo dst_info) {
            var req = new ConflictRequest();
            req.op = op;
            req.source = src;
            req.target = dst;
            req.source_info = src_info;
            req.target_info = dst_info;
            var parent = dst.get_parent();
            req.suggested_name = parent != null ? unique_name(parent, dst.get_basename()) : dst.get_basename();
            int policy = req.both_folders ? op.folder_policy : op.file_policy;
            if (policy >= 0) {
                req.choice = (ConflictChoice) policy;
                if (req.choice == ConflictChoice.MERGE && !req.both_folders) req.choice = ConflictChoice.REPLACE;
                return req;
            }
            op.waiting = true;
            state_changed();
            req.resume = ask.callback;
            conflict(req);
            yield;
            op.waiting = false;
            state_changed();
            if (req.apply_all && req.choice != ConflictChoice.CANCEL) {
                if (req.both_folders) op.folder_policy = (int) req.choice;
                else op.file_policy = (int) req.choice;
            }
            return req;
        }

        private async void remove_existing(GLib.File target, FileOp op) throws Error {
            try {
                yield target.trash_async(GLib.Priority.DEFAULT, op.cancellable);
                return;
            } catch (IOError e) {
                if (e is IOError.CANCELLED) throw e;
            }
            yield delete_recursive(target, op.cancellable);
        }

        private async void delete_recursive(GLib.File target, Cancellable? cancel) throws Error {
            var type = target.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS, cancel);
            if (type == FileType.DIRECTORY) {
                var en = yield target.enumerate_children_async("standard::name",
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, GLib.Priority.DEFAULT, cancel);
                while (true) {
                    var batch = yield en.next_files_async(50, GLib.Priority.DEFAULT, cancel);
                    if (batch == null || batch.length() == 0) break;
                    foreach (var ch in batch) yield delete_recursive(target.get_child(ch.get_name()), cancel);
                }
            }
            yield target.delete_async(GLib.Priority.DEFAULT, cancel);
        }

        private async void skip_item(GLib.File src, FileInfo info, FileOp op) {
            try {
                var rep = yield compute_size(src, op.cancellable);
                op.done_bytes += rep.bytes;
                op.done_files += rep.files;
            } catch (Error e) {
                op.done_files++;
            }
            op.skipped++;
            schedule_emit();
            state_changed();
        }

        private async void transfer_recursive(GLib.File src, GLib.File dst_in, FileOp op)
                throws Error {
            if (op.cancellable.is_cancelled()) return;
            GLib.File dst = dst_in;
            var info = yield src.query_info_async(
                COMPARE_ATTRS,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
                GLib.Priority.DEFAULT, op.cancellable);

            bool merging = false;
            if (info.get_file_type() == FileType.DIRECTORY && (dst.equal(src) || dst.has_prefix(src))) {
                if (op.is_move && dst.equal(src)) return;
                if (!dst.equal(src)) throw new IOError.INVALID_ARGUMENT(_("A folder cannot be copied into itself."));
            }
            if (src.equal(dst)) {
                if (op.is_move) return;
                var parent = dst.get_parent();
                if (parent != null) dst = parent.get_child(unique_name(parent, dst.get_basename()));
            } else {
                FileInfo? existing = null;
                try {
                    existing = yield dst.query_info_async(COMPARE_ATTRS,
                        FileQueryInfoFlags.NOFOLLOW_SYMLINKS, GLib.Priority.DEFAULT, op.cancellable);
                } catch (IOError e) {
                    if (!(e is IOError.NOT_FOUND)) throw e;
                }
                if (existing != null) {
                    var req = yield ask(op, src, dst, info, existing);
                    switch (req.choice) {
                        case ConflictChoice.CANCEL:
                            op.cancellable.cancel();
                            return;
                        case ConflictChoice.SKIP:
                            yield skip_item(src, info, op);
                            return;
                        case ConflictChoice.KEEP_BOTH:
                            var parent = dst.get_parent();
                            string name = req.new_name != null && req.new_name.strip() != "" ? req.new_name.strip() : req.suggested_name;
                            if (parent != null) dst = parent.get_child(name);
                            if (dst.query_exists() && parent != null) dst = parent.get_child(unique_name(parent, name));
                            break;
                        case ConflictChoice.MERGE:
                            if (req.both_folders) {
                                merging = true;
                                break;
                            }
                            yield remove_existing(dst, op);
                            break;
                        default:
                            yield remove_existing(dst, op);
                            break;
                    }
                }
            }

            // If we're moving and src and dst are on the same filesystem,
            // GFile.move_async will use rename() under the hood - instant.
            // We attempt this for ALL items (file or directory) first; on
            // EXDEV (cross-device) we fall back to copy + delete.
            if (op.is_move && !merging) {
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

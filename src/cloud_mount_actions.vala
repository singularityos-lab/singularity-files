using Gtk;
using Singularity.Accounts;

namespace Singularity.Apps.Files {

    public delegate void CloudActionDone();

    public class CloudMountActions : Object {
        public static bool covers(GLib.File[] files) {
            if (files.length == 0) return false;
            foreach (var f in files) {
                string? path = f.get_path();
                if (path == null || !CloudLocations.is_cloud_path(path)) return false;
            }
            return true;
        }

        public static void append_offline_item(Singularity.Widgets.ContextMenu menu, GLib.File[] files) {
            if (!covers(files)) return;
            bool all_kept = true;
            string[] paths = {};
            foreach (var f in files) {
                paths += f.get_path();
                if (!CloudMounts.is_kept_offline(f)) all_kept = false;
            }
            if (all_kept) {
                menu.add_item(_("Don't Keep Offline"), "edit-clear-symbolic", () => keep_offline.begin(paths, false));
            } else {
                menu.add_item(_("Keep Offline"), "folder-download-symbolic", () => keep_offline.begin(paths, true));
            }
        }

        private static async void keep_offline(string[] paths, bool keep) {
            try {
                yield CloudMounts.get_default().set_keep_offline(paths, keep);
            } catch (Error e) {
                warning("keep offline: %s", e.message);
            }
        }

        public static void confirm_delete(Gtk.Window? parent, GLib.File[] files, owned CloudActionDone done) {
            if (files.length == 0) return;
            var app = parent != null ? parent.application : (Gtk.Application) GLib.Application.get_default();
            var mount = CloudMounts.get_default().for_path(files[0].get_path());
            string account = mount != null ? mount.name : _("Online Account");
            string title = files.length == 1
                ? _("Delete %s?").printf(files[0].get_basename())
                : ngettext("Delete %d Item?", "Delete %d Items?", files.length).printf(files.length);
            string description = files.length == 1
                ? _("This deletes it from %s on the server. It cannot be undone.").printf(account)
                : _("This deletes them from %s on the server. It cannot be undone.").printf(account);
            var dialog = new Singularity.Widgets.ConfirmDialog(app, title, null, description,
                _("Delete"), Singularity.Widgets.ConfirmDialog.ActionStyle.DESTRUCTIVE);
            if (parent != null) dialog.transient_for = parent;
            GLib.File[] targets = files;
            dialog.response.connect((r) => {
                if (r != Singularity.Widgets.ConfirmDialog.Response.PRIMARY) return;
                delete_all.begin(targets, (obj, res) => {
                    delete_all.end(res);
                    done();
                });
            });
            dialog.present();
        }

        private static async void delete_all(GLib.File[] files) {
            foreach (var f in files) {
                try {
                    yield delete_tree(f);
                } catch (Error e) {
                    warning("delete %s: %s", f.get_path(), e.message);
                }
            }
        }

        private static async void delete_tree(GLib.File file) throws Error {
            var type = file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            if (type == FileType.DIRECTORY) {
                var en = yield file.enumerate_children_async(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT, null);
                while (true) {
                    var infos = yield en.next_files_async(50, Priority.DEFAULT, null);
                    if (infos == null) break;
                    foreach (var info in infos) yield delete_tree(file.get_child(info.get_name()));
                }
            }
            yield file.delete_async(Priority.DEFAULT, null);
        }
    }
}

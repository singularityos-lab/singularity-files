using Gtk;
using Singularity.Accounts;

namespace Singularity.Apps.Files {

    public class CloudLocations : Object {
        public Box section { get; private set; }
        public string active_id { get; private set; default = ""; }

        public signal void location_activated(Account account);
        public signal void mount_activated(string path);
        public signal void location_gone(string account_id);

        private Manager manager;
        private CloudMounts mounts;
        private Gee.HashMap<string, Singularity.Widgets.SidebarRow> rows =
            new Gee.HashMap<string, Singularity.Widgets.SidebarRow>();

        public CloudLocations() {
            section = new Box(Orientation.VERTICAL, 2);
            section.visible = false;
            manager = Manager.get_default();
            mounts = CloudMounts.get_default();
            manager.account_added.connect(() => rebuild());
            manager.account_removed.connect(() => rebuild());
            manager.account_changed.connect(() => rebuild());
            manager.needs_attention.connect(() => rebuild());
            manager.reloaded.connect(() => rebuild());
            mounts.changed.connect(() => rebuild());
            manager.load.begin((obj, res) => {
                manager.load.end(res);
                rebuild();
                mounts.load.begin();
            });
        }

        public static bool has_drive(Account account) {
            if (!account.has_capability(Capability.FILES)) return false;
            string api = account.get_endpoint("files-api") ?? (account.get_endpoint("webdav") != null ? "webdav" : "");
            return api == "google-drive" || api == "onedrive" || (api == "webdav" && account.get_endpoint("webdav") != null);
        }

        public static bool is_cloud_path(string path) {
            return CloudMounts.get_default().for_path(path) != null;
        }

        public void set_active(string id) {
            active_id = id;
            foreach (var entry in rows.entries) entry.value.set_active(entry.key == id);
        }

        public void sync_active_path(File folder) {
            string? path = folder.get_path();
            var mount = path != null ? mounts.for_path(path) : null;
            set_active(mount != null ? mount.account_id : "");
        }

        private static string status_icon(CloudMount mount) {
            switch (mount.status) {
                case "offline": return "network-offline-symbolic";
                case "syncing": return "emblem-synchronizing-symbolic";
                case "attention": return "dialog-warning-symbolic";
                default: return "";
            }
        }

        private static string describe(Account account, CloudMount? mount) {
            if (!account.healthy) return _("%s, sign in again in Settings").printf(account.provider_name);
            if (mount == null) return _("%s, not mounted").printf(account.provider_name);
            string state;
            switch (mount.status) {
                case "offline":
                    state = mount.pending > 0
                        ? ngettext("Offline, %u change waits to upload", "Offline, %u changes wait to upload", mount.pending).printf(mount.pending)
                        : _("Offline, files kept on this computer still open");
                    break;
                case "syncing":
                    state = _("Syncing");
                    break;
                default:
                    state = _("Up to date");
                    break;
            }
            string text = "%s\n%s".printf(account.provider_name, state);
            if (mount.total > 0 && mount.used >= 0) {
                text += "\n" + _("%s of %s used").printf(format_size((uint64) mount.used), format_size((uint64) mount.total));
            }
            return text;
        }

        private Widget build_row(Account account, CloudMount? mount) {
            var row = new Singularity.Widgets.SidebarRow(account.symbolic_icon_name, account.display_name);
            row.hexpand = true;
            row.tooltip_text = describe(account, mount);
            var inner = row.get_child() as Box;
            string glyph = "";
            if (!account.healthy) glyph = "dialog-warning-symbolic";
            else if (mount != null) glyph = status_icon(mount);
            if (inner != null && glyph != "") {
                var status = new Image.from_icon_name(glyph);
                status.pixel_size = 16;
                if (glyph == "dialog-warning-symbolic") status.add_css_class("warning");
                else status.add_css_class("dim-label");
                inner.append(status);
            }
            string id = account.id;
            row.clicked.connect(() => activate_account.begin(id));
            row.set_active(id == active_id);
            rows[id] = row;

            var line = new Box(Orientation.HORIZONTAL, 0);
            line.add_css_class("files-cloud-line");
            line.append(row);
            if (mount != null) {
                var eject = new Button.from_icon_name("media-eject-symbolic");
                eject.add_css_class("flat");
                eject.add_css_class("files-cloud-eject");
                eject.valign = Align.CENTER;
                eject.tooltip_text = _("Unmount");
                eject.update_property(AccessibleProperty.LABEL, _("Unmount %s").printf(account.display_name), -1);
                eject.clicked.connect(() => {
                    mounts.unmount.begin(id, (obj, res) => {
                        try {
                            mounts.unmount.end(res);
                        } catch (Error e) {
                            warning("unmount %s: %s", id, e.message);
                        }
                    });
                });
                line.append(eject);
            }
            if (mount == null || mount.total <= 0 || mount.used < 0) return line;

            var outer = new Box(Orientation.VERTICAL, 2);
            outer.append(line);
            var bar = new LevelBar();
            bar.min_value = 0;
            bar.max_value = 1;
            double fraction = double.min((double) mount.used / (double) mount.total, 1.0);
            bar.value = fraction;
            bar.margin_start = 40;
            bar.margin_end = 12;
            bar.margin_bottom = 2;
            bar.add_css_class("disk-usage-bar");
            if (fraction > 0.9) bar.add_css_class("disk-usage-high");
            else if (fraction > 0.75) bar.add_css_class("disk-usage-moderate");
            bar.can_target = false;
            outer.append(bar);
            return outer;
        }

        private async void activate_account(string id) {
            var current = manager.get_account(id);
            if (current == null) return;
            if (!mounts.available) {
                location_activated(current);
                return;
            }
            var mount = mounts.for_account(id);
            if (mount == null && current.healthy) {
                try {
                    yield mounts.mount(id);
                } catch (Error e) {
                    warning("mount %s: %s", id, e.message);
                }
                mount = mounts.for_account(id);
            }
            if (mount != null) {
                set_active(id);
                mount_activated(mount.path);
            } else {
                location_activated(current);
            }
        }

        private void rebuild() {
            Widget? child;
            while ((child = section.get_first_child()) != null) section.remove(child);
            rows.clear();
            section.append(new Separator(Orientation.HORIZONTAL));
            section.append(new Singularity.Widgets.SidebarSectionLabel(_("Online Accounts")));
            foreach (var account in manager.get_accounts_for(Capability.FILES)) {
                if (!has_drive(account)) continue;
                section.append(build_row(account, mounts.for_account(account.id)));
            }
            section.visible = rows.size > 0;
            if (active_id != "" && !rows.has_key(active_id)) {
                string gone = active_id;
                active_id = "";
                location_gone(gone);
            }
        }
    }
}

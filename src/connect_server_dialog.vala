using Gtk;
using GLib;
using Singularity;
using Singularity.Widgets;
using Singularity.FileSystem;

namespace Singularity.Apps {

    public class ConnectToServerDialog : Singularity.Widgets.AppDialog {
        public signal void connect_requested(string uri);

        public ConnectToServerDialog(Gtk.Application app) {
            base(app, true);
            set_title(_("Connect to Server"));
            set_default_size(440, -1);
            resizable = false;

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            box.margin_top = 6;
            box.margin_bottom = 16;
            box.margin_start = 24;
            box.margin_end = 24;

            var desc_lbl = new Gtk.Label(_("Enter an address such as sftp://user@host"));
            desc_lbl.wrap = true;
            desc_lbl.xalign = 0f;
            desc_lbl.add_css_class("dim-label");
            box.append(desc_lbl);

            var entry = new Gtk.Entry();
            entry.placeholder_text = "sftp://user@hostname";
            entry.hexpand = true;
            Singularity.Widgets.ContextMenu.attach_editable(entry);
            box.append(entry);

            var btn_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            btn_row.halign = Gtk.Align.END;

            var cancel_btn = new Gtk.Button.with_label(_("Cancel"));
            cancel_btn.clicked.connect(() => { close(); });
            set_cancel_button(cancel_btn);

            var connect_btn = new Gtk.Button.with_label(_("Connect"));
            connect_btn.add_css_class("suggested-action");
            connect_btn.clicked.connect(() => {
                string uri = entry.get_text().strip();
                if (uri != "") {
                    connect_requested(uri);
                    close();
                }
            });

            entry.activate.connect(() => {
                string uri = entry.get_text().strip();
                if (uri != "") {
                    connect_requested(uri);
                    close();
                }
            });

            btn_row.append(cancel_btn);
            btn_row.append(connect_btn);
            box.append(btn_row);

            content_box.append(box);
        }
    }
}

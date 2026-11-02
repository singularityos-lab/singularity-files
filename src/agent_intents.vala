namespace Singularity.Apps {

    internal class FilesIntents : Object {
        private const string PATH = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}";
        private const string PAIR = "{\"type\":\"object\",\"properties\":{\"from\":{\"type\":\"string\"},\"to\":{\"type\":\"string\"}},\"required\":[\"from\",\"to\"]}";

        private static File path (Json.Object args, string key = "path") throws Error {
            string p = args.has_member (key) ? args.get_string_member (key) : "";
            if (!p.has_prefix ("/")) throw new IOError.INVALID_ARGUMENT ("%s must be an absolute path", key);
            return File.new_for_path (p);
        }

        private static Json.Node result (File f) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("path").add_string_value (f.get_path ());
            b.end_object ();
            return b.get_root ();
        }

        internal static void install (Singularity.Application app) {
            var agent = app.agent;
            agent.add_intent ("files_list", "List a folder.",
                PATH, Singularity.AppIntentRisk.READ, (args) => {
                    var list = new Json.Array ();
                    var e = path (args).enumerate_children ("standard::name,standard::type,standard::size,standard::content-type", FileQueryInfoFlags.NONE);
                    FileInfo? info;
                    while ((info = e.next_file ()) != null && list.get_length () < 2000) {
                        var o = new Json.Object ();
                        o.set_string_member ("name", info.get_name ());
                        o.set_boolean_member ("folder", info.get_file_type () == FileType.DIRECTORY);
                        o.set_int_member ("size", info.get_size ());
                        o.set_string_member ("type", info.get_content_type () ?? "");
                        list.add_object_element (o);
                    }
                    var node = new Json.Node (Json.NodeType.ARRAY);
                    node.set_array (list);
                    return node;
                });
            agent.add_intent ("files_show", "Show a file or a folder in a window.",
                PATH, Singularity.AppIntentRisk.READ, (args) => {
                    var f = path (args);
                    app.open ({ f }, "");
                    return result (f);
                });
            agent.add_intent ("files_mkdir", "Create a folder.",
                PATH, Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var f = path (args);
                    f.make_directory_with_parents ();
                    return result (f);
                });
            agent.add_intent ("files_copy", "Copy a file. It never overwrites.",
                PAIR, Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var to = path (args, "to");
                    path (args, "from").copy (to, FileCopyFlags.NONE);
                    return result (to);
                });
            agent.add_intent ("files_move", "Move or rename a file. It never overwrites.",
                PAIR, Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var to = path (args, "to");
                    path (args, "from").move (to, FileCopyFlags.NONE);
                    return result (to);
                });
            agent.add_intent ("files_trash", "Move a file to the trash.",
                PATH, Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var f = path (args);
                    f.trash ();
                    return result (f);
                });
            agent.add_intent ("files_delete", "Delete a file or an empty folder for good.",
                PATH, Singularity.AppIntentRisk.IRREVERSIBLE, (args) => {
                    var f = path (args);
                    f.delete ();
                    return result (f);
                });
        }
    }
}

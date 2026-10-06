namespace Singularity.Apps.Files.Tests {

FileType lookup_set (string name, string[] dirs, string[] files) {
    if (name in dirs) return FileType.DIRECTORY;
    if (name in files) return FileType.REGULAR;
    return FileType.UNKNOWN;
}

File scratch_dir () {
    try {
        return File.new_for_path (DirUtils.make_tmp ("folder-templates-XXXXXX"));
    } catch (Error e) {
        error ("tmp: %s", e.message);
    }
}

void remove_tree (File f) {
    try {
        if (f.query_file_type (FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null) == FileType.DIRECTORY) {
            var en = f.enumerate_children ("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            FileInfo? info;
            while ((info = en.next_file (null)) != null) remove_tree (f.get_child (info.get_name ()));
        }
        f.delete (null);
    } catch (Error e) {
        warning ("cleanup %s: %s", f.get_path (), e.message);
    }
}

string read_text (File f) {
    try {
        uint8[] data;
        f.load_contents (null, out data, null);
        return (string) data;
    } catch (Error e) {
        error ("read %s: %s", f.get_path (), e.message);
    }
}

void test_validation () {
    string[] dirs = { "Work", "New Folder" };
    string[] files = { "notes.txt" };
    NameLookup look = (n) => lookup_set (n, dirs, files);
    assert (FolderNames.check ("Holiday", look) == NameState.OK);
    assert (FolderNames.check ("  Holiday  ", look) == NameState.OK);
    assert (FolderNames.check ("", look) == NameState.EMPTY);
    assert (FolderNames.check ("   ", look) == NameState.EMPTY);
    assert (FolderNames.check ("a/b", look) == NameState.SLASH);
    assert (FolderNames.check ("/", look) == NameState.SLASH);
    assert (FolderNames.check ("line\nbreak", look) == NameState.CONTROL_CHARS);
    assert (FolderNames.check ("tab\there", look) == NameState.CONTROL_CHARS);
    assert (FolderNames.check (".", look) == NameState.RESERVED);
    assert (FolderNames.check ("..", look) == NameState.RESERVED);
    assert (FolderNames.check (string.nfill (256, 'x'), look) == NameState.TOO_LONG);
    assert (FolderNames.check (string.nfill (255, 'x'), look) == NameState.OK);
    assert (FolderNames.check ("Work", look) == NameState.EXISTS_FOLDER);
    assert (FolderNames.check (" Work ", look) == NameState.EXISTS_FOLDER);
    assert (FolderNames.check ("work", look) == NameState.OK);
    assert (FolderNames.check ("notes.txt", look) == NameState.EXISTS_FILE);
    assert (FolderNames.check (".secret", look) == NameState.HIDDEN);
    assert (!NameState.HIDDEN.blocks ());
    assert (!NameState.OK.blocks ());
    assert (NameState.EMPTY.blocks ());
    assert (NameState.SLASH.blocks ());
    assert (NameState.EXISTS_FOLDER.blocks ());
    assert (NameState.EXISTS_FILE.blocks ());
    assert (FolderNames.message (NameState.OK, "x") == "");
    assert (FolderNames.message (NameState.EXISTS_FOLDER, " Work ").contains ("“Work”"));
    assert (FolderNames.message (NameState.HIDDEN, ".a") != "");
}

void test_stem_length () {
    assert (FolderNames.stem_length ("report.pdf", false) == 6);
    assert (FolderNames.stem_length ("backup.tar.gz", false) == 6);
    assert (FolderNames.stem_length ("Backup.TAR.XZ", false) == 6);
    assert (FolderNames.stem_length ("archive.2024.gz", false) == 12);
    assert (FolderNames.stem_length ("café crème.txt", false) == 10);
    assert (FolderNames.stem_length (".bashrc", false) == 7);
    assert (FolderNames.stem_length (".tar.gz", false) == 4);
    assert (FolderNames.stem_length (".config.json", false) == 7);
    assert (FolderNames.stem_length ("README", false) == 6);
    assert (FolderNames.stem_length ("photos.2024", true) == 11);
    assert (FolderNames.stem_length ("", false) == 0);
}

void test_unique () {
    string[] none = {};
    string[] dirs = { "New Folder", "New Folder 2", "New Folder 4" };
    NameLookup look = (n) => lookup_set (n, dirs, none);
    assert (FolderNames.unique ("New Folder", look) == "New Folder 3");
    assert (FolderNames.unique ("Project", look) == "Project");
    string[] one = { "New Folder" };
    NameLookup look1 = (n) => lookup_set (n, one, none);
    assert (FolderNames.unique ("New Folder", look1) == "New Folder 2");
    string[] files = { "Text Document.txt", "Text Document 2.txt", "Makefile", ".bashrc" };
    NameLookup lookf = (n) => lookup_set (n, none, files);
    assert (FolderNames.unique_file ("Text Document.txt", lookf) == "Text Document 3.txt");
    assert (FolderNames.unique_file ("Makefile", lookf) == "Makefile 2");
    assert (FolderNames.unique_file (".bashrc", lookf) == ".bashrc 2");
    assert (FolderNames.unique_file ("Sheet.ods", lookf) == "Sheet.ods");
}

void test_expand () {
    var now = new DateTime.local (2026, 3, 7, 10, 0, 0);
    assert (FolderTemplates.expand ("# {{name}}", "Garden", now) == "# Garden");
    assert (FolderTemplates.expand ("{{year}}/01", "x", now) == "2026/01");
    assert (FolderTemplates.expand ("on {{date}}", "x", now) == "on 2026-03-07");
    assert (FolderTemplates.expand ("{{name}} {{name}}", "A", now) == "A A");
    assert (FolderTemplates.expand ("{{unknown}}", "A", now) == "{{unknown}}");
    assert (FolderTemplates.safe_relative ("docs"));
    assert (FolderTemplates.safe_relative ("a/b/c.txt"));
    assert (!FolderTemplates.safe_relative ("../x"));
    assert (!FolderTemplates.safe_relative ("/etc"));
    assert (!FolderTemplates.safe_relative ("a//b"));
    assert (!FolderTemplates.safe_relative (""));
}

void test_parse_builtin () {
    string? path = Environment.get_variable ("FOLDER_TEMPLATES_JSON");
    assert (path != null);
    string json;
    try {
        FileUtils.get_contents (path, out json);
        var list = FolderTemplates.parse (json);
        string[] ids = {};
        foreach (var t in list.data) ids += t.id;
        assert (string.joinv (",", ids) == "project,photo-shoot,invoices,course,music,website");
        foreach (var t in list.data) {
            assert (t.name != "" && t.summary != "" && t.icon_name != "");
            assert (t.entries.length > 0);
        }
    } catch (Error e) {
        error ("parse: %s", e.message);
    }
}

void test_parse_rejects_escapes () {
    string json = """{"templates":[{"id":"bad","name":"Bad","entries":[{"path":"../evil/"},{"path":"/abs.txt","content":"x"},{"path":"ok/"}]},{"id":"","name":"skip"}]}""";
    try {
        var list = FolderTemplates.parse (json);
        assert (list.length == 1);
        assert (list[0].entries.length == 1);
        assert (list[0].entries[0].path == "ok" && list[0].entries[0].is_dir);
    } catch (Error e) {
        error ("parse: %s", e.message);
    }
}

void test_create_builtin () {
    var root = scratch_dir ();
    var now = new DateTime.local (2026, 9, 28, 9, 0, 0);
    try {
        string json;
        FileUtils.get_contents (Environment.get_variable ("FOLDER_TEMPLATES_JSON"), out json);
        var list = FolderTemplates.parse (json);
        FolderTemplate? project = null;
        FolderTemplate? invoices = null;
        FolderTemplate? website = null;
        foreach (var t in list.data) {
            if (t.id == "project") project = t;
            if (t.id == "invoices") invoices = t;
            if (t.id == "website") website = t;
        }
        var p = root.get_child ("Garden Shed");
        FolderTemplates.create (project, p, now);
        foreach (string d in new string[] { "docs", "src", "assets" })
            assert (p.get_child (d).query_file_type (0, null) == FileType.DIRECTORY);
        string readme = read_text (p.get_child ("README.md"));
        assert (readme.has_prefix ("# Garden Shed\n"));
        assert (readme.contains ("2026-09-28"));
        assert (!readme.contains ("{{"));

        var inv = root.get_child ("Invoices");
        FolderTemplates.create (invoices, inv, now);
        for (int m = 1; m <= 12; m++)
            assert (inv.get_child ("2026").get_child ("%02d".printf (m)).query_exists ());

        var web = root.get_child ("Site");
        FolderTemplates.create (website, web, now);
        assert (read_text (web.get_child ("index.html")).contains ("<title>Site</title>"));
        assert (web.get_child ("img").query_file_type (0, null) == FileType.DIRECTORY);
        assert (web.get_child ("css").get_child ("style.css").query_exists ());

        var empty = root.get_child ("Plain");
        FolderTemplates.create (FolderTemplates.empty_template (), empty, now);
        assert (empty.enumerate_children ("standard::name", 0, null).next_file (null) == null);

        bool failed = false;
        try {
            FolderTemplates.create (project, p, now);
        } catch (IOError.EXISTS e) {
            failed = true;
        }
        assert (failed);
    } catch (Error e) {
        error ("create: %s", e.message);
    }
    remove_tree (root);
}

void test_user_templates () {
    var home = scratch_dir ();
    var tpl_dir = home.get_child ("Templates");
    try {
        tpl_dir.make_directory (null);
        var band = tpl_dir.get_child ("Band");
        band.get_child ("Setlists").make_directory_with_parents (null);
        band.get_child ("Setlists").get_child ("tour.txt").replace_contents ("gig".data, null, false, 0, null, null);
        tpl_dir.get_child (".hidden").make_directory (null);
        tpl_dir.get_child ("Letter.odt").replace_contents ("doc".data, null, false, 0, null, null);
        tpl_dir.get_child ("Empty Text.txt").replace_contents ("".data, null, false, 0, null, null);

        var user = FolderTemplates.load_user (tpl_dir);
        assert (user.length == 1);
        assert (user[0].name == "Band" && user[0].source != null);
        assert (user[0].summary == "Your template with Setlists");

        var docs = FolderTemplates.document_templates (tpl_dir);
        assert (docs.length == 2);
        assert (docs[0].get_name () == "Empty Text.txt" && docs[1].get_name () == "Letter.odt");

        var target = home.get_child ("Summer Tour");
        FolderTemplates.create (user[0], target, new DateTime.now_local ());
        assert (read_text (target.get_child ("Setlists").get_child ("tour.txt")) == "gig");

        var src = home.get_child ("Client A");
        src.get_child ("Briefs").get_child ("2026").make_directory_with_parents (null);
        src.get_child ("Briefs").get_child ("brief.txt").replace_contents ("secret".data, null, false, 0, null, null);
        var saved = FolderTemplates.save_folder (src, tpl_dir, false);
        assert (saved.get_basename () == "Client A");
        assert (saved.get_child ("Briefs").get_child ("2026").query_exists ());
        assert (!saved.get_child ("Briefs").get_child ("brief.txt").query_exists ());
        var saved2 = FolderTemplates.save_folder (src, tpl_dir, true);
        assert (saved2.get_basename () == "Client A 2");
        assert (read_text (saved2.get_child ("Briefs").get_child ("brief.txt")) == "secret");

        bool refused = false;
        try {
            FolderTemplates.save_folder (home, tpl_dir, false);
        } catch (IOError.INVALID_ARGUMENT e) {
            refused = true;
        }
        assert (refused);
    } catch (Error e) {
        error ("user templates: %s", e.message);
    }
    remove_tree (home);
}

public static int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/folder-templates/validation", test_validation);
    Test.add_func ("/folder-templates/unique", test_unique);
    Test.add_func ("/folder-templates/stem-length", test_stem_length);
    Test.add_func ("/folder-templates/expand", test_expand);
    Test.add_func ("/folder-templates/parse-builtin", test_parse_builtin);
    Test.add_func ("/folder-templates/parse-rejects-escapes", test_parse_rejects_escapes);
    Test.add_func ("/folder-templates/create-builtin", test_create_builtin);
    Test.add_func ("/folder-templates/user-templates", test_user_templates);
    return Test.run ();
}

}

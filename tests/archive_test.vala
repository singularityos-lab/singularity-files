using Singularity.Apps.Files.Archives;

private string scratch;

private string fresh_dir(string name) {
    string path = Path.build_filename(scratch, name);
    ArchivePaths.remove_tree(path);
    DirUtils.create_with_parents(path, 0755);
    return path;
}

private void write_file(string path, uint8[] data) {
    DirUtils.create_with_parents(Path.get_dirname(path), 0755);
    try {
        FileUtils.set_data(path, data);
    } catch (FileError e) {
        error("%s", e.message);
    }
}

private uint8[] pseudo_random(int n, uint32 seed) {
    var data = new uint8[n];
    uint32 x = seed;
    for (int i = 0; i < n; i++) {
        x = x * 1103515245 + 12345;
        data[i] = (uint8) (x >> 16);
    }
    return data;
}

private string make_tree(string name) {
    string root = Path.build_filename(fresh_dir(name), "Project");
    write_file(Path.build_filename(root, "readme.txt"), "hello archive\n".data);
    write_file(Path.build_filename(root, "data", "blob.bin"), pseudo_random(70000, 7));
    write_file(Path.build_filename(root, "data", "deep", "notes.md"), string.nfill(5000, 'a').data);
    DirUtils.create_with_parents(Path.build_filename(root, "empty"), 0755);
    FileUtils.symlink("readme.txt", Path.build_filename(root, "link.txt"));
    return root;
}

private string checksum_file(string path) {
    uint8[] data;
    try {
        FileUtils.get_data(path, out data);
    } catch (FileError e) {
        return "missing";
    }
    return Checksum.compute_for_data(ChecksumType.SHA256, data);
}

private void assert_same_tree(string a, string b) {
    assert(checksum_file(Path.build_filename(a, "readme.txt")) == checksum_file(Path.build_filename(b, "readme.txt")));
    assert(checksum_file(Path.build_filename(a, "data", "blob.bin")) == checksum_file(Path.build_filename(b, "data", "blob.bin")));
    assert(checksum_file(Path.build_filename(a, "data", "deep", "notes.md")) == checksum_file(Path.build_filename(b, "data", "deep", "notes.md")));
    assert(FileUtils.test(Path.build_filename(b, "empty"), FileTest.IS_DIR));
    assert(FileUtils.test(Path.build_filename(b, "link.txt"), FileTest.IS_SYMLINK));
    try {
        assert(FileUtils.read_link(Path.build_filename(b, "link.txt")) == "readme.txt");
    } catch (FileError e) {
        assert_not_reached();
    }
}

private void test_detect_names() {
    assert(ArchiveFormats.from_name("a.zip") == ArchiveKind.ZIP);
    assert(ArchiveFormats.from_name("A.TAR.GZ") == ArchiveKind.TAR_GZ);
    assert(ArchiveFormats.from_name("a.tgz") == ArchiveKind.TAR_GZ);
    assert(ArchiveFormats.from_name("a.tar.zst") == ArchiveKind.TAR_ZST);
    assert(ArchiveFormats.from_name("a.7z") == ArchiveKind.SEVEN_ZIP);
    assert(ArchiveFormats.from_name("a.rar") == ArchiveKind.RAR);
    assert(ArchiveFormats.from_name("a.iso") == ArchiveKind.ISO);
    assert(ArchiveFormats.from_name("a.txt.gz") == ArchiveKind.COMPRESSED_FILE);
    assert(ArchiveFormats.from_name("a.zip.001") == ArchiveKind.ZIP);
    assert(ArchiveFormats.from_name("a.txt") == ArchiveKind.UNKNOWN);
    assert(ArchiveFormats.stem("Photos.tar.gz") == "Photos");
    assert(ArchiveFormats.stem("Photos.zip.001") == "Photos");
    assert(ArchiveFormats.stem("v1.2.zip") == "v1.2");
    assert(ArchiveFormats.split_first_volume("x.7z.001") == "x.7z");
    assert(ArchiveFormats.split_first_volume("x.7z") == null);
}

private void test_detect_magic() {
    assert(ArchiveFormats.from_magic({ 'P', 'K', 3, 4, 0 }, "noext") == ArchiveKind.ZIP);
    assert(ArchiveFormats.from_magic({ '7', 'z', 0xBC, 0xAF, 0x27, 0x1C }, "x.bin") == ArchiveKind.SEVEN_ZIP);
    assert(ArchiveFormats.from_magic({ 'R', 'a', 'r', '!', 0x1A, 0x07, 0 }, "x") == ArchiveKind.RAR);
    assert(ArchiveFormats.from_magic({ 0x1F, 0x8B, 8 }, "x.tar.gz") == ArchiveKind.TAR_GZ);
    assert(ArchiveFormats.from_magic({ 0x1F, 0x8B, 8 }, "x.gz") == ArchiveKind.COMPRESSED_FILE);
    assert(ArchiveFormats.from_magic({ 0xFD, '7', 'z', 'X', 'Z', 0 }, "x.txz") == ArchiveKind.TAR_XZ);
    assert(ArchiveFormats.from_magic({ 0x28, 0xB5, 0x2F, 0xFD }, "x.tar.zst") == ArchiveKind.TAR_ZST);
    var tar = new uint8[512];
    tar[257] = 'u'; tar[258] = 's'; tar[259] = 't'; tar[260] = 'a'; tar[261] = 'r';
    assert(ArchiveFormats.from_magic(tar, "renamed.dat") == ArchiveKind.TAR);
    var iso = new uint8[0x8010];
    iso[0x8001] = 'C'; iso[0x8002] = 'D'; iso[0x8003] = '0'; iso[0x8004] = '0'; iso[0x8005] = '1';
    assert(ArchiveFormats.from_magic(iso, "disc.img") == ArchiveKind.ISO);
    assert(ArchiveFormats.from_magic({ 'h', 'i' }, "x.zip") == ArchiveKind.ZIP);
}

private void test_sanitize() {
    assert(ArchivePaths.sanitize("a/b.txt") == "a/b.txt");
    assert(ArchivePaths.sanitize("./a//b/./c") == "a/b/c");
    assert(ArchivePaths.sanitize("dir/") == "dir");
    assert(ArchivePaths.sanitize("../evil") == null);
    assert(ArchivePaths.sanitize("a/../../evil") == null);
    assert(ArchivePaths.sanitize("a/../b") == null);
    assert(ArchivePaths.sanitize("/etc/passwd") == null);
    assert(ArchivePaths.sanitize("C:\\Windows\\x") == null);
    assert(ArchivePaths.sanitize("a\\..\\..\\x") == null);
    assert(ArchivePaths.sanitize("") == null);
    assert(ArchivePaths.sanitize("./") == null);
    assert(ArchivePaths.sanitize("a:b.txt") == "a:b.txt");
    assert(ArchivePaths.link_stays_inside("a/link", "../b.txt"));
    assert(ArchivePaths.link_stays_inside("link", "sub/x"));
    assert(!ArchivePaths.link_stays_inside("link", "../x"));
    assert(!ArchivePaths.link_stays_inside("a/link", "../../x"));
    assert(!ArchivePaths.link_stays_inside("a/link", "/etc/passwd"));
    assert(!ArchivePaths.link_stays_inside("a/link", ""));
}

private void test_options() {
    assert(ArchiveFormats.options_for(ArchiveKind.ZIP, CompressionLevel.STORE, false) == "zip:compression=store");
    assert(ArchiveFormats.options_for(ArchiveKind.ZIP, CompressionLevel.BEST, true) == "zip:compression=deflate,zip:compression-level=9,zip:encryption=aes256");
    assert(ArchiveFormats.options_for(ArchiveKind.SEVEN_ZIP, CompressionLevel.FAST, false) == "7zip:compression=lzma2,7zip:compression-level=1");
    assert(ArchiveFormats.options_for(ArchiveKind.TAR_ZST, CompressionLevel.BEST, false) == "zstd:compression-level=19");
    assert(ArchiveFormats.options_for(ArchiveKind.TAR_GZ, CompressionLevel.NORMAL, false) == "gzip:compression-level=6");
    assert(ArchiveFormats.options_for(ArchiveKind.TAR, CompressionLevel.NORMAL, false) == "");
    assert(!ArchiveKind.TAR.has_levels());
    assert(ArchiveKind.ZIP.can_store() && !ArchiveKind.TAR_XZ.can_store());
    assert(!ArchiveKind.RAR.can_write() && !ArchiveKind.ISO.can_write());
    assert(!ArchiveFormats.supports_encryption(ArchiveKind.SEVEN_ZIP));
    assert(ArchiveFormats.ratio_text(25, 100) == "25% of the original size, 75% saved");
    assert(ArchiveFormats.ratio_text(120, 100) == "120% of the original size, no space saved");
    assert(ArchiveFormats.ratio_text(10, 0) == "");
}

private void round_trip(ArchiveKind kind, CompressionLevel level) {
    string label = kind.writer_format() + (kind.writer_filter() ?? "") + "-" + ((int) level).to_string();
    string src = make_tree("src-" + label);
    string out_dir = fresh_dir("out-" + label);
    string archive = Path.build_filename(out_dir, "Project" + kind.extension());
    var creator = new ArchiveCreator({ src }, archive);
    creator.kind = kind;
    creator.level = level;
    try {
        creator.run();
    } catch (Error e) {
        error("create %s: %s", label, e.message);
    }
    assert(creator.done_bytes == creator.total_bytes);
    assert(ArchiveFormats.detect(archive) == kind);
    ArchiveListing listing;
    try {
        listing = ArchiveReader.list(archive);
    } catch (Error e) {
        error("list %s: %s", label, e.message);
    }
    assert(listing.kind == kind);
    assert(listing.files == 4);
    assert(listing.folders == 4);
    assert(listing.uncompressed == 14 + 70000 + 5000);
    string[] tops = listing.top_level();
    assert(tops.length == 1 && tops[0] == "Project");
    string dest = fresh_dir("x-" + label);
    var ex = new ArchiveExtractor(archive, dest);
    try {
        ex.run();
    } catch (Error e) {
        error("extract %s: %s", label, e.message);
    }
    assert(ex.rejected == 0);
    assert(ex.files == 4);
    assert_same_tree(src, Path.build_filename(dest, "Project"));
}

private void test_round_trips() {
    ArchiveKind[] kinds = { ArchiveKind.ZIP, ArchiveKind.SEVEN_ZIP, ArchiveKind.TAR, ArchiveKind.TAR_GZ,
                            ArchiveKind.TAR_BZ2, ArchiveKind.TAR_XZ, ArchiveKind.TAR_ZST };
    foreach (var k in kinds) {
        assert(ArchiveFormats.supports_writing(k));
        round_trip(k, CompressionLevel.NORMAL);
    }
    round_trip(ArchiveKind.ZIP, CompressionLevel.STORE);
    round_trip(ArchiveKind.SEVEN_ZIP, CompressionLevel.BEST);
    round_trip(ArchiveKind.TAR_ZST, CompressionLevel.FAST);
}

private void test_levels_shrink() {
    string dir = fresh_dir("levels");
    write_file(Path.build_filename(dir, "text.txt"), string.nfill(200000, 'z').data);
    int64 sizes[2];
    CompressionLevel[] levels = { CompressionLevel.STORE, CompressionLevel.BEST };
    for (int i = 0; i < 2; i++) {
        string out_path = Path.build_filename(dir, "l%d.zip".printf(i));
        var c = new ArchiveCreator({ Path.build_filename(dir, "text.txt") }, out_path);
        c.level = levels[i];
        try { c.run(); } catch (Error e) { error("%s", e.message); }
        sizes[i] = ArchiveReader.input_size(out_path);
    }
    assert(sizes[0] > 200000);
    assert(sizes[1] < 5000);
}

private void test_password_zip() {
    if (!ArchiveFormats.supports_encryption(ArchiveKind.ZIP)) {
        Test.skip("zip encryption not available in this libarchive");
        return;
    }
    string src = make_tree("pw-src");
    string archive = Path.build_filename(fresh_dir("pw-out"), "secret.zip");
    var c = new ArchiveCreator({ src }, archive);
    c.password = "correct horse";
    try { c.run(); } catch (Error e) { error("%s", e.message); }
    ArchiveListing listing;
    try { listing = ArchiveReader.list(archive); } catch (Error e) { error("%s", e.message); }
    assert(listing.encrypted);

    string dest = fresh_dir("pw-x");
    var ex = new ArchiveExtractor(archive, dest);
    int asked = 0;
    bool saw_retry = false;
    ex.set_password_provider((retry) => {
        asked++;
        if (retry) saw_retry = true;
        return asked == 1 ? "wrong" : "correct horse";
    });
    try { ex.run(); } catch (Error e) { error("extract: %s", e.message); }
    assert(asked >= 2);
    assert(saw_retry);
    assert_same_tree(src, Path.build_filename(dest, "Project"));

    string dest2 = fresh_dir("pw-x2");
    var ex2 = new ArchiveExtractor(archive, dest2);
    ex2.set_password_provider((retry) => null);
    bool cancelled = false;
    try {
        ex2.run();
    } catch (IOError.CANCELLED e) {
        cancelled = true;
    } catch (Error e) {
        error("unexpected %s", e.message);
    }
    assert(cancelled);

    string dest3 = fresh_dir("pw-x3");
    var ex3 = new ArchiveExtractor(archive, dest3);
    ex3.password = "correct horse";
    try { ex3.run(); } catch (Error e) { error("%s", e.message); }
    assert_same_tree(src, Path.build_filename(dest3, "Project"));
}

private void test_unsupported_encryption() {
    string? seven = Environment.find_program_in_path("7z") ?? Environment.find_program_in_path("7za");
    if (seven == null) {
        Test.skip("7z is not installed");
        return;
    }
    string src = make_tree("enc7-src");
    string out_dir = fresh_dir("enc7-out");
    foreach (string variant in new string[] { "content", "headers" }) {
        string archive = Path.build_filename(out_dir, variant + ".7z");
        string[] argv = { seven, "a", "-bd", "-y", "-pcorrect horse", archive, "readme.txt", "data" };
        if (variant == "headers") argv += "-mhe=on";
        try {
            var launcher = new SubprocessLauncher(SubprocessFlags.STDOUT_SILENCE);
            launcher.set_cwd(src);
            launcher.spawnv(argv).wait_check();
        } catch (Error e) {
            error("7z: %s", e.message);
        }
        if (variant == "content") {
            ArchiveListing listing;
            try { listing = ArchiveReader.list(archive); } catch (Error e) { error("%s", e.message); }
            assert(listing.encrypted);
        }
        var ex = new ArchiveExtractor(archive, fresh_dir("enc7-x-" + variant));
        ex.password = "correct horse";
        bool unsupported = false;
        try {
            ex.run();
        } catch (ArchiveError.UNSUPPORTED e) {
            unsupported = true;
        } catch (Error e) {
            error("unexpected %s", e.message);
        }
        assert(unsupported);
    }
}

private string conflict_archive() {
    string dir = fresh_dir("cf-src");
    write_file(Path.build_filename(dir, "a.txt"), "from archive".data);
    write_file(Path.build_filename(dir, "b.txt"), "second".data);
    string archive = Path.build_filename(fresh_dir("cf-out"), "c.zip");
    var c = new ArchiveCreator({ Path.build_filename(dir, "a.txt"), Path.build_filename(dir, "b.txt") }, archive);
    try { c.run(); } catch (Error e) { error("%s", e.message); }
    return archive;
}

private string read_text(string path) {
    string text;
    try { FileUtils.get_contents(path, out text); } catch (FileError e) { return "missing"; }
    return text;
}

private void test_conflicts() {
    string archive = conflict_archive();
    ExtractChoice[] choices = { ExtractChoice.SKIP, ExtractChoice.KEEP_BOTH, ExtractChoice.REPLACE };
    foreach (var choice in choices) {
        string dest = fresh_dir("cf-dest-%d".printf((int) choice));
        write_file(Path.build_filename(dest, "a.txt"), "already here".data);
        var ex = new ArchiveExtractor(archive, dest);
        ex.use_trash = false;
        int calls = 0;
        ex.set_resolver((entry, dest_path, out new_name) => {
            new_name = null;
            calls++;
            assert(entry.path == "a.txt");
            return choice;
        });
        try { ex.run(); } catch (Error e) { error("%s", e.message); }
        assert(calls == 1);
        assert(read_text(Path.build_filename(dest, "b.txt")) == "second");
        switch (choice) {
            case ExtractChoice.SKIP:
                assert(ex.skipped == 1);
                assert(read_text(Path.build_filename(dest, "a.txt")) == "already here");
                break;
            case ExtractChoice.KEEP_BOTH:
                assert(read_text(Path.build_filename(dest, "a.txt")) == "already here");
                assert(read_text(Path.build_filename(dest, "a (2).txt")) == "from archive");
                break;
            default:
                assert(read_text(Path.build_filename(dest, "a.txt")) == "from archive");
                break;
        }
    }
    string named = fresh_dir("cf-named");
    write_file(Path.build_filename(named, "a.txt"), "already here".data);
    var ex = new ArchiveExtractor(archive, named);
    ex.set_resolver((entry, dest_path, out new_name) => {
        new_name = "renamed.txt";
        return ExtractChoice.KEEP_BOTH;
    });
    try { ex.run(); } catch (Error e) { error("%s", e.message); }
    assert(read_text(Path.build_filename(named, "renamed.txt")) == "from archive");

    string stop = fresh_dir("cf-stop");
    write_file(Path.build_filename(stop, "a.txt"), "already here".data);
    var ex2 = new ArchiveExtractor(archive, stop);
    ex2.set_resolver((entry, dest_path, out new_name) => {
        new_name = null;
        return ExtractChoice.CANCEL;
    });
    bool cancelled = false;
    try { ex2.run(); } catch (IOError.CANCELLED e) { cancelled = true; } catch (Error e) { error("%s", e.message); }
    assert(cancelled);
    assert(read_text(Path.build_filename(stop, "a.txt")) == "already here");
}

private void add_raw(LA.Writer w, string path, uint type, string? link, string? body) {
    var e = new LA.Entry();
    e.set_pathname(path);
    e.set_filetype(type);
    e.set_perm(type == LA.IFDIR ? 0755 : 0644);
    if (link != null) e.set_symlink(link);
    e.set_size(body != null ? body.length : 0);
    assert(w.write_header(e) == LA.OK);
    if (body != null) w.write_data((uint8*) body, body.length);
    w.finish_entry();
}

private void test_traversal() {
    string dir = fresh_dir("evil");
    string archive = Path.build_filename(dir, "evil.tar");
    var w = new LA.Writer();
    w.set_format_by_name("paxr");
    assert(w.open_filename(archive) == LA.OK);
    add_raw(w, "../escaped.txt", LA.IFREG, null, "bad");
    add_raw(w, "/tmp-absolute-escape.txt", LA.IFREG, null, "bad");
    add_raw(w, "ok/../../escaped2.txt", LA.IFREG, null, "bad");
    add_raw(w, "outlink", LA.IFLNK, "../../", null);
    add_raw(w, "abslink", LA.IFLNK, "/etc", null);
    add_raw(w, "outlink/pwned.txt", LA.IFREG, null, "bad");
    add_raw(w, "sub", LA.IFDIR, null, null);
    add_raw(w, "sub/fine.txt", LA.IFREG, null, "good");
    add_raw(w, "goodlink", LA.IFLNK, "sub/fine.txt", null);
    w.close();

    string dest = fresh_dir("evil/dest");
    var ex = new ArchiveExtractor(archive, dest);
    try { ex.run(); } catch (Error e) { error("%s", e.message); }
    assert(ex.rejected >= 5);
    assert(!FileUtils.test(Path.build_filename(dir, "escaped.txt"), FileTest.EXISTS));
    assert(!FileUtils.test(Path.build_filename(scratch, "escaped.txt"), FileTest.EXISTS));
    assert(!FileUtils.test(Path.build_filename(dir, "escaped2.txt"), FileTest.EXISTS));
    assert(!FileUtils.test("/tmp-absolute-escape.txt", FileTest.EXISTS));
    assert(!FileUtils.test(Path.build_filename(dest, "abslink"), FileTest.IS_SYMLINK));
    assert(!FileUtils.test(Path.build_filename(dest, "outlink"), FileTest.IS_SYMLINK));
    assert(!FileUtils.test(Path.build_filename(scratch, "pwned.txt"), FileTest.EXISTS));
    assert(read_text(Path.build_filename(dest, "sub", "fine.txt")) == "good");
    assert(FileUtils.test(Path.build_filename(dest, "goodlink"), FileTest.IS_SYMLINK));
}

private void test_split_volumes() {
    string dir = fresh_dir("split");
    write_file(Path.build_filename(dir, "big.bin"), pseudo_random(50000, 3));
    string sum = checksum_file(Path.build_filename(dir, "big.bin"));
    foreach (var kind in new ArchiveKind[] { ArchiveKind.ZIP, ArchiveKind.SEVEN_ZIP, ArchiveKind.TAR_GZ }) {
        string out_path = Path.build_filename(fresh_dir("split/out" + kind.extension()), "big" + kind.extension());
        var c = new ArchiveCreator({ Path.build_filename(dir, "big.bin") }, out_path);
        c.kind = kind;
        c.volume_size = 16384;
        try { c.run(); } catch (Error e) { error("%s", e.message); }
        assert(c.outputs.length >= 4);
        assert(FileUtils.test(out_path + ".001", FileTest.EXISTS));
        assert(!FileUtils.test(out_path, FileTest.EXISTS));
        ArchiveListing listing;
        try { listing = ArchiveReader.list(out_path + ".001"); } catch (Error e) { error("%s", e.message); }
        assert(listing.volumes == c.outputs.length);
        assert(listing.files == 1);
        string dest = fresh_dir("split/x" + kind.extension());
        var ex = new ArchiveExtractor(out_path + ".001", dest);
        try { ex.run(); } catch (Error e) { error("%s: %s", kind.label(), e.message); }
        assert(checksum_file(Path.build_filename(dest, "big.bin")) == sum);
    }
    string small = Path.build_filename(fresh_dir("split/small"), "small.zip");
    write_file(Path.build_filename(dir, "tiny.txt"), "tiny".data);
    var c2 = new ArchiveCreator({ Path.build_filename(dir, "tiny.txt") }, small);
    c2.volume_size = 1024 * 1024;
    try { c2.run(); } catch (Error e) { error("%s", e.message); }
    assert(c2.outputs.length == 1);
    assert(FileUtils.test(small, FileTest.EXISTS));
}

private void test_extract_here_flatten() {
    string src = make_tree("here-src");
    string parent = fresh_dir("here");
    string archive = Path.build_filename(parent, "Project.tar.gz");
    var c = new ArchiveCreator({ src }, archive);
    c.kind = ArchiveKind.TAR_GZ;
    try { c.run(); } catch (Error e) { error("%s", e.message); }
    string wrapper = ArchiveExtractor.extract_here_folder(archive);
    assert(wrapper == Path.build_filename(parent, "Project"));
    var ex = new ArchiveExtractor(archive, wrapper);
    try { ex.run(); } catch (Error e) { error("%s", e.message); }
    string result = ArchiveExtractor.flatten_single_child(wrapper);
    assert(result == Path.build_filename(parent, "Project"));
    assert_same_tree(src, result);

    string wrapper2 = ArchiveExtractor.extract_here_folder(archive);
    assert(wrapper2 == Path.build_filename(parent, "Project (2)"));
    var ex2 = new ArchiveExtractor(archive, wrapper2);
    try { ex2.run(); } catch (Error e) { error("%s", e.message); }
    string result2 = ArchiveExtractor.flatten_single_child(wrapper2);
    assert(result2 == wrapper2);
    assert_same_tree(src, Path.build_filename(wrapper2, "Project"));

    string loose = fresh_dir("loose");
    write_file(Path.build_filename(loose, "one.txt"), "1".data);
    write_file(Path.build_filename(loose, "two.txt"), "2".data);
    string la = Path.build_filename(loose, "pair.zip");
    var c3 = new ArchiveCreator({ Path.build_filename(loose, "one.txt"), Path.build_filename(loose, "two.txt") }, la);
    try { c3.run(); } catch (Error e) { error("%s", e.message); }
    string w3 = ArchiveExtractor.extract_here_folder(la);
    var ex3 = new ArchiveExtractor(la, w3);
    try { ex3.run(); } catch (Error e) { error("%s", e.message); }
    assert(ArchiveExtractor.flatten_single_child(w3) == w3);
    assert(read_text(Path.build_filename(w3, "two.txt")) == "2");
}

private void test_read_only_browse() {
    string src = make_tree("ro-src");
    string archive = Path.build_filename(fresh_dir("ro"), "p.zip");
    var c = new ArchiveCreator({ src }, archive);
    try { c.run(); } catch (Error e) { error("%s", e.message); }
    string dest = Path.build_filename(scratch, "ro", "view");
    var ex = new ArchiveExtractor(archive, dest);
    ex.read_only = true;
    try { ex.run(); } catch (Error e) { error("%s", e.message); }
    assert(Posix.access(Path.build_filename(dest, "Project", "readme.txt"), Posix.W_OK) != 0 || Posix.getuid() == 0);
    assert(Posix.access(Path.build_filename(dest, "Project"), Posix.W_OK) != 0 || Posix.getuid() == 0);
    ArchivePaths.remove_tree(dest);
    assert(!FileUtils.test(dest, FileTest.EXISTS));
}

private void test_compressed_single_file() {
    string dir = fresh_dir("single");
    string plain = Path.build_filename(dir, "notes.txt");
    write_file(plain, string.nfill(3000, 'q').data);
    string gz = Path.build_filename(dir, "notes.txt.gz");
    var w = new LA.Writer();
    w.set_format_by_name("raw");
    w.add_filter_by_name("gzip");
    assert(w.open_filename(gz) == LA.OK);
    var e = new LA.Entry();
    e.set_pathname("notes.txt");
    e.set_filetype(LA.IFREG);
    e.set_size(3000);
    w.write_header(e);
    uint8[] data;
    try { FileUtils.get_data(plain, out data); } catch (FileError fe) { error("%s", fe.message); }
    w.write_data((uint8*) data, data.length);
    w.close();
    assert(ArchiveFormats.detect(gz) == ArchiveKind.COMPRESSED_FILE);
    string dest = fresh_dir("single/x");
    var ex = new ArchiveExtractor(gz, dest);
    try { ex.run(); } catch (Error er) { error("%s", er.message); }
    assert(checksum_file(Path.build_filename(dest, "notes.txt")) == checksum_file(plain));
}

private void test_failed_extract_cleans_created_dirs() {
    string dir = fresh_dir("failed");
    string src = Path.build_filename(dir, "Project");
    write_file(Path.build_filename(src, "deep", "a", "b", "big.bin"), pseudo_random(400000, 11));
    string archive = Path.build_filename(dir, "project.tar");
    var creator = new ArchiveCreator({ src }, archive);
    creator.kind = ArchiveKind.TAR;
    try { creator.run(); } catch (Error e) { error("%s", e.message); }
    uint8[] data;
    try { FileUtils.get_data(archive, out data); } catch (FileError e) { error("%s", e.message); }
    string broken = Path.build_filename(dir, "broken.tar");
    write_file(broken, data[0:data.length / 2]);

    string parent = fresh_dir("failed/out");
    DirUtils.create_with_parents(Path.build_filename(parent, "keep"), 0755);
    string dest = Path.build_filename(parent, "new", "inner");
    var ex = new ArchiveExtractor(broken, dest);
    bool failed = false;
    try {
        ex.run();
    } catch (Error e) {
        failed = true;
    }
    assert(failed);
    assert(!FileUtils.test(Path.build_filename(parent, "new"), FileTest.EXISTS));
    assert(FileUtils.test(Path.build_filename(parent, "keep"), FileTest.IS_DIR));

    string existing = fresh_dir("failed/existing");
    DirUtils.create_with_parents(Path.build_filename(existing, "Project", "old"), 0755);
    write_file(Path.build_filename(existing, "note.txt"), "mine".data);
    var again = new ArchiveExtractor(broken, existing);
    failed = false;
    try {
        again.run();
    } catch (Error e) {
        failed = true;
    }
    assert(failed);
    assert(FileUtils.test(Path.build_filename(existing, "Project", "old"), FileTest.IS_DIR));
    assert(!FileUtils.test(Path.build_filename(existing, "Project", "deep"), FileTest.EXISTS));
    assert(FileUtils.test(Path.build_filename(existing, "note.txt"), FileTest.IS_REGULAR));

    string good = fresh_dir("failed/good");
    var ok = new ArchiveExtractor(archive, Path.build_filename(good, "fresh"));
    try { ok.run(); } catch (Error e) { error("%s", e.message); }
    assert(FileUtils.test(Path.build_filename(good, "fresh", "Project", "deep", "a", "b", "big.bin"), FileTest.IS_REGULAR));
}

public int main(string[] args) {
    Test.init(ref args);
    try {
        scratch = DirUtils.make_tmp("files-archive-test-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }
    Test.add_func("/archive/detect-names", test_detect_names);
    Test.add_func("/archive/detect-magic", test_detect_magic);
    Test.add_func("/archive/sanitize", test_sanitize);
    Test.add_func("/archive/options", test_options);
    Test.add_func("/archive/round-trips", test_round_trips);
    Test.add_func("/archive/levels", test_levels_shrink);
    Test.add_func("/archive/password-zip", test_password_zip);
    Test.add_func("/archive/unsupported-encryption", test_unsupported_encryption);
    Test.add_func("/archive/conflicts", test_conflicts);
    Test.add_func("/archive/traversal", test_traversal);
    Test.add_func("/archive/split-volumes", test_split_volumes);
    Test.add_func("/archive/extract-here", test_extract_here_flatten);
    Test.add_func("/archive/read-only-browse", test_read_only_browse);
    Test.add_func("/archive/compressed-single-file", test_compressed_single_file);
    Test.add_func("/archive/failed-extract-cleanup", test_failed_extract_cleans_created_dirs);
    int rc = Test.run();
    ArchivePaths.remove_tree(scratch);
    return rc;
}

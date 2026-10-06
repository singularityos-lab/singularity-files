# Singularity Files

> [!IMPORTANT]
> Report bugs and request features in the
> [Singularity Desktop tracker](https://github.com/singularityos-lab/singularity-desktop/issues/new/choose).

A file manager for the Singularity Desktop.

## Requirements

- [Meson](https://mesonbuild.com/) ≥ 1.0
- [Vala](https://vala.dev/) compiler
- [Vetro](https://github.com/singularityos-lab/vetro/) compiler
- GTK4
- libgee-0.8
- libarchive 3.4 or newer (`libarchive-dev`)
- [libsingularity](https://github.com/singularityos-lab/libsingularity)

## Build & Install

```sh
meson setup build
meson compile -C build
meson install -C build
```

## Archives

Files opens zip, 7z, RAR, tar (plain, gzip, bzip2, xz, zstd), ISO and cpio
archives as read-only folders, extracts them with progress, conflict choices
and password prompts, and creates zip, 7z and tar archives with a compression
level, an optional password and optional split parts. Everything goes through
libarchive in `src/archive/`; no external `tar`, `unzip` or `7z` command is
run.

- Browsing extracts the archive into
  `$XDG_CACHE_HOME/singularity-files/archives/` with read-only permissions and
  removes it when Files quits.
- Entries with absolute paths, `..` components, links that point outside the
  destination or unsafe hard links are skipped and counted.
- Split parts are raw volumes named `.001`, `.002` and so on, the same layout
  7-Zip uses, and open again when the first part is opened.

### For distributors

- Build dependency: `libarchive` 3.4 or newer through pkg-config. Formats and
  filters come from the libarchive build: a format or filter it cannot write
  is left out of the Create Archive dialog, and the password option only
  appears when libarchive was built with a crypto backend that supports zip
  AES-256 (nettle, OpenSSL or mbed TLS).
- Reading RAR 5, encrypted RAR and encrypted 7z depends on the libarchive
  version; unsupported archives report the libarchive error instead of
  failing silently.
- Writing 7z with a password is not offered because libarchive cannot encrypt
  7z archives.

## License

GPL-3.0-only - see [LICENSE](LICENSE).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on singularity-files. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.

project('singularity-files', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0',
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-files"', language: 'c')
subdir('po')

gnome = import('gnome')

# Dependencies
gtk_dep = dependency('gtk4')
gee_dep = dependency('gee-0.8')
libarchive_dep = dependency('libarchive', version: '>= 3.4')
posix_dep = meson.get_compiler('vala').find_library('posix')
archive_sources = files(
  'src/archive/libarchive-lowlevel.vapi',
  'src/archive/archive_format.vala',
  'src/archive/archive_paths.vala',
  'src/archive/archive_ops.vala',
)

# libsingularity dependency
if meson.is_subproject()
  libsingularity_subproj = subproject('libsingularity')
  libsingularity_dep = libsingularity_subproj.get_variable('libsingularity_dep')
else
  libsingularity_dep = dependency('singularity-1.0')
endif

# Compile .vetro to .ui in the ui/ subdirectory
subdir('ui')

# Resources
resources = gnome.compile_resources(
  'singularity-files-resources',
  'resources/dev.sinty.files.gresource.xml',
  source_dir: [meson.current_source_dir(), meson.current_build_dir()],
  dependencies: [main_ui, picker_ui]
)

sources = files(
  'src/main.vala',
  'src/window.vala',
  'src/app.vala',
  'src/connect_server_dialog.vala',
  'src/portal_service.vala',
  'src/file_ops_manager.vala',
  'src/conflict_dialog.vala',
  'src/files_plugin_manager.vala',
  'src/thumbnail_frame.vala',
  'src/cloud_locations.vala',
  'src/cloud_view.vala',
  'src/cloud_mount_actions.vala',
  'src/folder_templates.vala',
  'src/new_folder_dialog.vala',
  'src/archive/archive_dialogs.vala',
) + archive_sources

executable('singularity-files',
  sources: sources + [resources],
  dependencies: [
    gtk_dep, 
    gee_dep, 
    libsingularity_dep,
    dependency('libpeas-2'),
    dependency('json-glib-1.0'),
    libarchive_dep,
    posix_dep,
  ],
  install: true
)

archive_test = executable('archive-test',
  archive_sources + files('tests/archive_test.vala'),
  dependencies: [dependency('glib-2.0'), dependency('gobject-2.0'), dependency('gio-2.0'), libarchive_dep, posix_dep],
  c_args: ['-DGETTEXT_PACKAGE="singularity-files"'],
)
test('archive', archive_test, timeout: 120)

folder_templates_test = executable('folder-templates-test',
  files('src/folder_templates.vala', 'tests/folder_templates_test.vala'),
  dependencies: [dependency('glib-2.0'), dependency('gio-2.0'), dependency('json-glib-1.0')],
)
test('folder-templates', folder_templates_test,
  env: ['FOLDER_TEMPLATES_JSON=' + meson.current_source_dir() / 'data' / 'folder-templates.json'],
)
test('folder-templates-strings', find_program('python3'),
  args: [
    files('data/folder-templates-strings.py'),
    '--check',
    meson.current_source_dir() / 'data' / 'folder-templates.json',
    meson.current_source_dir() / 'data' / 'folder-templates.json.h',
  ],
)

subdir('plugins')

# Data files
install_data('data/dev.sinty.files.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/dev.sinty.files.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

install_data('data/folder-templates.json',
  install_dir: get_option('datadir') / 'singularity-files'
)

install_data('data/dev.sinty.files.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)

install_data('data/icons/dev.sinty.files.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

install_data('data/icons/ush-penguin.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

install_data('data/icons/ush-penguin-symbolic.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

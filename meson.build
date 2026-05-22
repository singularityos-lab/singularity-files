project('singularity-files', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0',
)

gnome = import('gnome')

# Dependencies
gtk_dep = dependency('gtk4')
gee_dep = dependency('gee-0.8')

# libsingularity dependency
if meson.is_subproject()
  libsingularity_subproj = subproject('libsingularity')
  libsingularity_dep = libsingularity_subproj.get_variable('libsingularity_dep')
else
  libsingularity_dep = dependency('singularity-1.0')
endif

# Resources
resources = gnome.compile_resources(
  'singularity-files-resources',
  'resources/dev.sinty.files.gresource.xml',
  source_dir: meson.current_source_dir()
)

sources = files(
  'src/main.vala',
  'src/window.vala',
  'src/app.vala',
  'src/connect_server_dialog.vala',
  'src/portal_service.vala',
  'src/file_ops_manager.vala',
)

executable('singularity-files',
  sources: sources + [resources],
  dependencies: [
    gtk_dep, 
    gee_dep, 
    libsingularity_dep,
    dependency('libpeas-2'),
    dependency('json-glib-1.0'),
  ],
  install: true
)

# Data files
install_data('data/dev.sinty.files.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/dev.sinty.files.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

install_data('data/dev.sinty.files.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)

install_data('data/icons/dev.sinty.files.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

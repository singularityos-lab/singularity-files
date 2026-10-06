foreach plugin : [['recent-documents', 'recent_documents.vala'], ['places-dock', 'places_dock.vala'], ['video-thumbnails', 'video_thumbnails.vala']]
  shared_module(plugin[0],
    plugin[0] / plugin[1],
    dependencies: [gtk_dep, libsingularity_dep, dependency('libpeas-2'), dependency('gio-unix-2.0')],
    install: true,
    install_dir: get_option('libdir') / 'singularity' / 'plugins' / plugin[0]
  )
  install_data(plugin[0] / plugin[0] + '.plugin',
    install_dir: get_option('libdir') / 'singularity' / 'plugins' / plugin[0]
  )
endforeach

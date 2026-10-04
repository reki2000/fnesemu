// platform dependent [DiscSource]s: dart:io files on native platforms, and
// browser File objects on the web
export 'disc_source_io.dart'
    if (dart.library.js_interop) 'disc_source_web.dart';

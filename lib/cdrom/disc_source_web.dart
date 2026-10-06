import 'image_file.dart';

/// local paths are not accessible on the web
DiscSource discSourceFromPath(String path) =>
    throw UnsupportedError("cdrom: cannot open $path on the web");

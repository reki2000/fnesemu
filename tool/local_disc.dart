// disc images in the local file system, for the command line tools
import 'dart:io';

import 'package:fnesemu/cdrom/disc_source.dart';
import 'package:fnesemu/gui/picked_disc.dart';
import 'package:mp_bigfile_picker/io.dart';

/// the .cue/.iso/.bin file at [path]. the files referred from a .cue file are
/// in its directory.
DiscSource localDisc(String path) {
  final file = File(path);
  return pickedDiscIn(
      IoDirectory(file.parent.path), file.uri.pathSegments.last);
}

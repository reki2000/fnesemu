import 'package:file_picker/file_picker.dart';

import 'disc_source_local.dart';
import 'image_file.dart';

export 'disc_source_local.dart';

/// lets the user select a .cue, .iso or .bin file. returns null if canceled.
Future<DiscSource?> pickDiscSource() async {
  final picked = await FilePicker.platform.pickFiles(
      dialogTitle: "Select a disc image (.cue, .iso, .bin)",
      type: FileType.custom,
      allowedExtensions: ["cue", "iso", "bin", "img"]);
  final path = picked?.files.firstOrNull?.path;
  return path == null ? null : IoDiscSource(path);
}

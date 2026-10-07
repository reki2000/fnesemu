// directories of disc images selected by the user, and local disc images on
// native platforms
import 'package:mp_bigfile_picker/mp_bigfile_picker.dart';

import 'disc_folder.dart';

export 'disc_source_io.dart'
    if (dart.library.js_interop) 'disc_source_web.dart';

/// lets the user select a directory of disc images. returns null if canceled.
Future<DiscFolder?> pickDiscFolder() async {
  final dir =
      await pickDirectory(dialogTitle: "Select a directory of CD-ROMs / ROMs");
  return dir == null ? null : PickedDiscFolder(dir);
}

/// opens the directory saved by [DiscFolder.persistentPath], or null if it is
/// not available any more
Future<DiscFolder?> openDiscFolderAt(String path,
    {bool requestPermission = false}) async {
  final dir =
      await restoreDirectory(path, requestPermission: requestPermission);
  return dir == null ? null : PickedDiscFolder(dir);
}

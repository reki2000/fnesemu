// discs and directories the user selects through mp_bigfile_picker, given to
// the cdrom drive
import 'dart:typed_data';

import 'package:fnesemu_core/cdrom/disc_folder.dart';
import 'package:fnesemu_core/cdrom/image_file.dart';
import 'package:mp_bigfile_picker/mp_bigfile_picker.dart';

/// an [ImageFile] of a [RandomReadFile] of mp_bigfile_picker
class PickedImageFile extends ImageFile {
  final RandomReadFile file;

  PickedImageFile(this.file);

  @override
  String get name => file.name;

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> read(int offset, int length) => file.read(offset, length);

  @override
  Future<void> close() => file.close();
}

/// a [DiscFolder] of a [PickedDirectory] of mp_bigfile_picker
class PickedDiscFolder extends DiscFolder {
  final PickedDirectory dir;

  PickedDiscFolder(this.dir);

  @override
  String get name => dir.name;

  @override
  String? get persistentPath => dir.restoreKey;

  @override
  String get displayPath => dir.displayPath;

  @override
  String? get identityKey => dir.identityKey;

  @override
  Stream<FolderFile> list() => dir.walk().map(FolderFile.new);

  @override
  ImageFile file(String path) => PickedImageFile(dir.open(path));
}

/// lets the user select a directory of disc images. returns null if canceled.
Future<DiscFolder?> pickDiscFolder({String? initialDirectory}) async {
  final dir = await pickDirectory(
      dialogTitle: "Select a directory of CD-ROMs / ROMs",
      initialDirectory: initialDirectory);
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

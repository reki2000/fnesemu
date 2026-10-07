import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../api.dart';
import 'darwin_impl.dart';
import 'io_impl.dart';
import 'saf_impl.dart';

bool get _isDarwin => Platform.isIOS || Platform.isMacOS;

/// lets the user select a directory. returns null if canceled. the dialog
/// opens at [initialDirectory] where the platform supports it.
Future<PickedDirectory?> pickDirectory(
    {String? dialogTitle, String? initialDirectory}) async {
  if (Platform.isAndroid) return pickSafDirectory();
  if (_isDarwin) return pickDarwinDirectory(dialogTitle: dialogTitle);

  final path = await FilePicker.getDirectoryPath(
      dialogTitle: dialogTitle, initialDirectory: initialDirectory);
  return path == null ? null : IoDirectory(path);
}

/// opens the directory of [PickedDirectory.restoreKey] again, or null if it is
/// not available any more
Future<PickedDirectory?> restoreDirectory(String restoreKey,
    {bool requestPermission = false}) async {
  if (Platform.isAndroid) return restoreSafDirectory(restoreKey);
  if (_isDarwin) return restoreDarwinDirectory(restoreKey);

  return await Directory(restoreKey).exists() ? IoDirectory(restoreKey) : null;
}

/// lets the user select files. returns null if canceled. [extensions] ('cue',
/// without dots) is a hint: Android does not filter by it. the dialog opens
/// at [initialDirectory] where the platform supports it.
Future<List<RandomReadFile>?> pickFiles(
    {List<String>? extensions,
    bool multiple = false,
    String? dialogTitle,
    String? initialDirectory}) async {
  if (Platform.isAndroid) return pickSafFiles(multiple: multiple);
  if (_isDarwin) {
    return pickDarwinFiles(
        extensions: extensions, multiple: multiple, dialogTitle: dialogTitle);
  }

  final type = extensions == null ? FileType.any : FileType.custom;
  final picked = multiple
      ? await FilePicker.pickFiles(
          dialogTitle: dialogTitle,
          initialDirectory: initialDirectory,
          type: type,
          allowedExtensions: extensions)
      : [
          if (await FilePicker.pickFile(
                  dialogTitle: dialogTitle,
                  initialDirectory: initialDirectory,
                  type: type,
                  allowedExtensions: extensions)
              case final file?)
            file
        ];
  if (picked.isEmpty) return null;
  return picked
      .map((f) => f.path)
      .whereType<String>()
      .map((path) => IoReadFile(path, restoreKey: path))
      .toList();
}

/// opens the file of [RandomReadFile.restoreKey] again, or null if it is not
/// available any more
Future<RandomReadFile?> restoreFile(String restoreKey) async {
  if (Platform.isAndroid) return restoreSafFile(restoreKey);
  if (_isDarwin) return restoreDarwinFile(restoreKey);

  return await File(restoreKey).exists()
      ? IoReadFile(restoreKey, restoreKey: restoreKey)
      : null;
}

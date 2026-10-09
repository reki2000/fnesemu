import '../api.dart';
import 'web_access.dart';
import 'web_impl.dart';

/// replaces the directory dialog in tests (not used on the web)
Future<String?> Function({String? dialogTitle, String? initialDirectory})?
    debugDirectoryDialog;

/// lets the user select a directory. returns null if canceled.
Future<PickedDirectory?> pickDirectory(
        {String? dialogTitle, String? initialDirectory}) =>
    pickAccessDirectory();

/// Restores a saved handle; permission requests require a user action.
Future<PickedDirectory?> restoreDirectory(String restoreKey,
        {bool requestPermission = false}) =>
    restoreAccessDirectory(restoreKey, requestPermission: requestPermission);

/// forgets the saved handle, which takes its permission with it
Future<void> releaseDirectory(String restoreKey) =>
    releaseAccessDirectory(restoreKey);

/// lets the user select files. returns null if canceled.
Future<List<RandomReadFile>?> pickFiles(
        {List<String>? extensions,
        bool multiple = false,
        String? dialogTitle,
        String? initialDirectory}) =>
    pickWebFiles(extensions: extensions, multiple: multiple);

/// files of the browser cannot be opened again after a restart
Future<RandomReadFile?> restoreFile(String restoreKey) async => null;

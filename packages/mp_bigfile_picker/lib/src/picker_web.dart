import '../api.dart';
import 'web_impl.dart';

/// lets the user select a directory. returns null if canceled.
Future<PickedDirectory?> pickDirectory({String? dialogTitle}) =>
    pickWebDirectory();

/// directories of the browser cannot be opened again after a restart
Future<PickedDirectory?> restoreDirectory(String restoreKey) async => null;

/// lets the user select files. returns null if canceled.
Future<List<RandomReadFile>?> pickFiles(
        {List<String>? extensions,
        bool multiple = false,
        String? dialogTitle}) =>
    pickWebFiles(extensions: extensions, multiple: multiple);

/// files of the browser cannot be opened again after a restart
Future<RandomReadFile?> restoreFile(String restoreKey) async => null;

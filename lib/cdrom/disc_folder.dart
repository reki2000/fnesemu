import 'dart:async';
import 'dart:convert';

import 'package:mp_bigfile_picker/api.dart';

import 'image_file.dart';

/// a file in a [DiscFolder]. [path] is relative to the folder, separated by '/'
class FolderFile {
  final String path;
  const FolderFile(this.path);
}

/// a directory selected by the user, with all the files below it. implemented
/// per platform.
abstract class DiscFolder {
  String get name;

  /// where the folder can be opened again after a restart, or null if it
  /// cannot (the browser does not allow it)
  String? get persistentPath => null;

  String? get identityKey => persistentPath;

  /// lists the files below the folder recursively
  Stream<FolderFile> list();

  /// returns the file at [path] of [FolderFile]. it is opened when it is read
  ImageFile file(String path);
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
  String? get identityKey => dir.identityKey;

  @override
  Stream<FolderFile> list() => dir.walk().map(FolderFile.new);

  @override
  ImageFile file(String path) => PickedImageFile(dir.open(path));
}

/// normalizes a path written in a .cue file ('\' or '/', '.', '..') relative
/// to [baseDir] ('' or 'a/b'), into a lower case key. returns null if it goes
/// out of the folder.
String? folderKey(String baseDir, String name) {
  final parts = <String>[];
  final all = [
    ...baseDir.split('/'),
    ...name.replaceAll('\\', '/').split('/'),
  ];
  for (final p in all) {
    if (p.isEmpty || p == '.') continue;
    if (p == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
    } else {
      parts.add(p);
    }
  }
  return parts.join('/').toLowerCase();
}

String dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

/// [DiscSource] of a .cue/.iso/.bin file in a [DiscFolder]. the files
/// referred from the .cue file are searched in the folder, ignoring the case.
class FolderDiscSource extends DiscSource {
  final DiscFolder folder;
  final String mainPath;
  final Map<String, String> _index; // key -> path
  final _opened = <ImageFile>[];
  late final ImageFile _main = folder.file(mainPath);

  FolderDiscSource(this.folder, this.mainPath, Iterable<FolderFile> files)
      : _index = {
          for (final f in files) folderKey('', f.path)!: f.path,
        };

  @override
  ImageFile get main => _main;

  @override
  Future<ImageFile> open(String name) async {
    final key = folderKey(dirOf(mainPath), name);
    final path = key == null ? null : _index[key];
    if (path == null) {
      throw ArgumentError("cdrom: file not found in the folder: $name");
    }
    final file = folder.file(path);
    _opened.add(file);
    return file;
  }

  @override
  Future<void> close() async {
    await _main.close();
    for (final f in _opened) {
      await f.close();
    }
    _opened.clear();
  }
}

/// an image found by [DiscScanner]
class DiscItem {
  /// the .cue, .iso or .bin file, relative to the folder
  final String path;

  const DiscItem(this.path);

  bool get isCue => path.toLowerCase().endsWith('.cue');

  @override
  String toString() => path;
}

class ScanProgress {
  /// listing the files, then checking the .cue files
  final bool isListing;

  /// files listed
  final int files;

  /// .cue files found, and checked so far
  final int cues;
  final int checkedCues;

  /// images added to the result so far
  final int found;

  const ScanProgress(
      this.isListing, this.files, this.cues, this.checkedCues, this.found);

  @override
  String toString() => isListing
      ? "listing: $files files"
      : "checking: $checkedCues / $cues cue files";
}

class ScanResult {
  final DiscFolder folder;
  final List<FolderFile> files;
  final List<DiscItem> items;

  /// .cue files which refer to files that do not exist, or cannot be read
  final List<String> skipped;
  final bool cancelled;

  const ScanResult(
      this.folder, this.files, this.items, this.skipped, this.cancelled);

  DiscSource sourceOf(DiscItem item) =>
      FolderDiscSource(folder, item.path, files);
}

/// finds the disc images in a folder: a .cue file if all the files it refers
/// to exist (the files are not listed), and a single .iso/.bin file.
class DiscScanner {
  static const _maxCueBytes = 1 << 20;

  static Future<ScanResult> scan(
    DiscFolder folder, {
    void Function(ScanProgress progress)? onProgress,
    bool Function()? isCancelled,
    bool includeAllFiles = false,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;
    final files = <FolderFile>[];
    final sw = Stopwatch()..start();
    int lastReport = -1;

    void report(bool listing, int cues, int checked, int found,
        {bool force = false}) {
      // at most 20 times per second
      if (!force && sw.elapsedMilliseconds - lastReport < 50) return;
      lastReport = sw.elapsedMilliseconds;
      onProgress
          ?.call(ScanProgress(listing, files.length, cues, checked, found));
    }

    await for (final f in folder.list()) {
      if (cancelled()) {
        return ScanResult(folder, files, const [], const [], true);
      }
      files.add(f);
      report(true, 0, 0, 0);
    }
    report(true, 0, 0, 0, force: true);

    final index = {for (final f in files) folderKey('', f.path)!: f.path};
    final cues = files.where((f) => _ext(f.path) == 'cue').toList();
    final referenced = <String>{};
    final items = <DiscItem>[];
    final skipped = <String>[];

    for (int i = 0; i < cues.length; i++) {
      if (cancelled()) {
        return ScanResult(folder, files, items, skipped, true);
      }
      final cue = cues[i].path;
      report(false, cues.length, i, items.length);

      final names = await _referencedFiles(folder, cue);
      final keys = [
        for (final n in names ?? <String>[]) folderKey(dirOf(cue), n)
      ];
      // the files are excluded from the list even if the .cue file is not
      // usable, as they are not images by themselves
      referenced.addAll(keys.whereType<String>());
      if (names != null &&
          names.isNotEmpty &&
          keys.every((k) => k != null && index.containsKey(k))) {
        items.add(DiscItem(cue));
      } else {
        skipped.add(cue);
        if (includeAllFiles) items.add(DiscItem(cue));
      }
      await Future<void>.delayed(Duration.zero); // let the UI update
    }

    for (final f in files) {
      final ext = _ext(f.path);
      if ((includeAllFiles ? ext != 'cue' : (ext == 'iso' || ext == 'bin')) &&
          !referenced.contains(folderKey('', f.path))) {
        items.add(DiscItem(f.path));
      }
    }

    items.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    report(false, cues.length, cues.length, items.length, force: true);
    return ScanResult(folder, files, items, skipped, false);
  }

  static String _ext(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i + 1).toLowerCase();
  }

  /// the files of the FILE commands of the .cue file, or null if unreadable
  static Future<List<String>?> _referencedFiles(
      DiscFolder folder, String cuePath) async {
    final file = folder.file(cuePath);
    try {
      final length = await file.length();
      final bytes = await file.read(0, length.clamp(0, _maxCueBytes));
      return cueFileNames(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return null;
    } finally {
      await file.close();
    }
  }

  /// the file names of the FILE commands of a .cue file
  static List<String> cueFileNames(String cue) {
    final names = <String>[];
    for (final line in cue.split("\n")) {
      final parts = RegExp(r'(".*?"|\S+)')
          .allMatches(line.trim())
          .map((m) => m.group(0)!.replaceAll('"', ''))
          .toList();
      if (parts.length >= 2 && parts[0].toUpperCase() == "FILE") {
        names.add(parts[1]);
      }
    }
    return names;
  }
}

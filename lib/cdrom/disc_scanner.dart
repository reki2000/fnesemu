import 'dart:async';

import 'package:mp_bigfile_picker/api.dart';

import 'disc_image.dart';
import 'disc_source.dart';

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
  final PickedDirectory folder;

  /// the paths of all the files below [folder]
  final List<String> files;
  final List<DiscItem> items;

  /// .cue files which refer to files that do not exist, or cannot be read
  final List<String> skipped;
  final bool cancelled;

  const ScanResult(
      this.folder, this.files, this.items, this.skipped, this.cancelled);

  DiscSource sourceOf(DiscItem item) =>
      DiscSource.inDirectory(folder, item.path, files);
}

/// finds the disc images in a folder: a .cue file if all the files it refers
/// to exist (the files are not listed), and a single .iso/.bin file.
class DiscScanner {
  static const _maxCueBytes = 1 << 20;

  static Future<ScanResult> scan(
    PickedDirectory folder, {
    void Function(ScanProgress progress)? onProgress,
    bool Function()? isCancelled,
    bool includeAllFiles = false,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;
    final files = <String>[];
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

    await for (final f in folder.walk()) {
      if (cancelled()) {
        return ScanResult(folder, files, const [], const [], true);
      }
      files.add(f);
      report(true, 0, 0, 0);
    }
    report(true, 0, 0, 0, force: true);

    final index = {for (final f in files) folderKey('', f)!: f};
    final cues = files.where((f) => _ext(f) == 'cue').toList();
    final referenced = <String>{};
    final items = <DiscItem>[];
    final skipped = <String>[];

    for (int i = 0; i < cues.length; i++) {
      if (cancelled()) {
        return ScanResult(folder, files, items, skipped, true);
      }
      final cue = cues[i];
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
      final ext = _ext(f);
      if ((includeAllFiles ? ext != 'cue' : (ext == 'iso' || ext == 'bin')) &&
          !referenced.contains(folderKey('', f))) {
        items.add(DiscItem(f));
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
      PickedDirectory folder, String cuePath) async {
    final file = folder.open(cuePath);
    try {
      return DiscImage.cueFileNames(
          await readText(file, maxBytes: _maxCueBytes));
    } catch (_) {
      return null;
    } finally {
      await file.close();
    }
  }
}

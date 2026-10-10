import 'dart:async';

import 'package:cdrom_image/cdrom_image.dart';
import 'package:mp_bigfile_picker/api.dart';

import 'picked_disc.dart';

/// a ROM file found by [RomScanner]: a disc image or a ROM
class RomFile {
  /// relative to the folder
  final String path;

  const RomFile(this.path);

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
  final List<RomFile> items;

  /// .cue files which refer to files that do not exist, or cannot be read
  final List<String> skipped;
  final bool cancelled;

  ScanResult(this.folder, this.files, this.items, this.skipped, this.cancelled);

  late final _files = _discFiles(folder, files);

  /// the disc image of [item]: the arguments of [DiscImage.parse]
  (DiscFile, Iterable<DiscFile>) sourceOf(RomFile item) =>
      (_files[item.path]!, _files.values);
}

Map<String, DiscFile> _discFiles(PickedDirectory folder, List<String> files) =>
    {
      for (final path in files)
        path: PickedDiscFile(path, () => folder.open(path))
    };

/// lists the ROM files in a ROM directory: all the files, except the ones which a .cue
/// file refers to (they are parts of the disc image of the .cue file).
class RomScanner {
  static Future<ScanResult> scan(
    PickedDirectory folder, {
    void Function(ScanProgress progress)? onProgress,
    bool Function()? isCancelled,
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

    final discs = _discFiles(folder, files);
    final cues = files.where((f) => _ext(f) == 'cue').toList();
    final referenced = <String>{};
    final items = <RomFile>[];
    final skipped = <String>[];

    for (int i = 0; i < cues.length; i++) {
      if (cancelled()) {
        return ScanResult(folder, files, items, skipped, true);
      }
      final cue = cues[i];
      report(false, cues.length, i, items.length);

      items.add(RomFile(cue));
      try {
        final (_, refs) = await DiscImage.parse(discs.values, discs[cue]!);
        referenced.addAll(refs.map((file) => file.path));
      } catch (_) {
        skipped.add(cue); // a missing file, or unreadable
      }
      await Future<void>.delayed(Duration.zero); // let the UI update
    }

    for (final f in files) {
      if (_ext(f) != 'cue' && !referenced.contains(f)) {
        items.add(RomFile(f));
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
}

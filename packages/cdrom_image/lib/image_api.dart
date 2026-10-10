import 'dart:typed_data';

import 'filesystem_api.dart';
import 'format/parse.dart' as parser;

/// whether a file can be a disc image, by its name
enum DiscFileKind {
  /// .cue, .iso or .chd
  image,

  /// .bin: a raw disc image, or a ROM
  maybeImage,

  notImage;

  static DiscFileKind of(String name) =>
      switch (name.substring(name.lastIndexOf('.') + 1).toLowerCase()) {
        'cue' || 'iso' || 'chd' => image,
        'bin' => maybeImage,
        _ => notImage,
      };
}

class DiscTrack {
  final int number; // 1..
  final bool isAudio;
  final int startLba; // LBA of INDEX 01, without 2 seconds of lead-in
  final int sectors;

  const DiscTrack(this.number, this.isAudio, this.startLba, this.sectors);

  @override
  String toString() =>
      "track $number ${isAudio ? "audio" : "data"} lba:$startLba sectors:$sectors";
}

class DiscToc {
  final List<DiscTrack> tracks;

  /// number of sectors of the disc, from LBA 0 (without lead-in)
  final int totalSectors;

  const DiscToc(this.tracks, this.totalSectors);

  static const empty = DiscToc([], 0);
}

/// A description cannot be parsed or a referenced track cannot be resolved.
class DiscParseException implements Exception {
  final String imagePath;
  final String message;
  final String? referencedPath;
  final Object? cause;

  const DiscParseException(this.imagePath, this.message,
      {this.referencedPath, this.cause});

  @override
  String toString() => 'DiscParseException: $imagePath: $message';
}

/// Format-independent access to a parsed CD-ROM image.
abstract interface class DiscImage {
  static const sectorSize = 2352;

  /// Async factory. [files] are the files of the directory of [file], with
  /// the paths relative to it; a .cue file's references are found in them.
  /// They are iterated once, to index their paths.
  /// Returns the image and distinct referenced files, excluding [file].
  /// Standalone images have no referenced files.
  /// Throws [DiscParseException] for invalid descriptions or missing references.
  static Future<(DiscImage, List<DiscFile>)> parse(
          Iterable<DiscFile> files, DiscFile file) =>
      parser.parse(files, file);

  DiscToc get toc;
  int get totalSectors;
  bool isReadable(int lba);

  /// Reads raw sectors starting at LBA zero, without the lead-in.
  /// The requested range must be inside [totalSectors].
  Future<List<Uint8List>> readSectors(int lba, int count);
}

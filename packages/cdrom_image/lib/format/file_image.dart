import 'dart:typed_data';

import '../filesystem_api.dart';
import '../image_api.dart';
import 'disc_source.dart';

/// a contiguous region of sectors stored in a file
class Extent {
  final int startLba;
  final int sectors;
  final DiscFile file;
  final int fileSector; // sector offset in the file

  /// true if the file holds 2048 bytes of user data per sector (cooked mode 1)
  final bool cooked;

  const Extent(this.startLba, this.sectors, this.file, this.fileSector,
      {this.cooked = false});

  int get endLba => startLba + sectors;
}

/// a part of a read request: [count] sectors from [lba], stored in [file] from
/// [fileSector], or silence (gap) if [file] is null
class Segment {
  final int lba;
  final int count;
  final DiscFile? file;
  final int fileSector;
  final bool cooked;

  const Segment(this.lba, this.count, this.file, this.fileSector,
      {this.cooked = false});
}

/// a disc image whose sectors are in files (a .cue with its files, or a
/// single .iso/.bin): the TOC, and the raw sectors by LBA (without lead-in)
class FileImage implements DiscImage {
  static const sectorSize = DiscImage.sectorSize;
  static const sync = [
    0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0 // 12 bytes
  ];

  final DiscSource source;
  @override
  final DiscToc toc;
  final List<Extent> extents; // sorted by startLba

  FileImage(this.source, this.toc, this.extents);

  @override
  int get totalSectors => toc.totalSectors;

  @override
  bool isReadable(int lba) => lba >= 0 && lba < totalSectors;

  /// splits [lba, lba+count) into file-backed segments and gaps.
  /// the range must be readable.
  List<Segment> segments(int lba, int count) {
    final result = <Segment>[];
    final end = lba + count;

    var pos = lba;
    for (final e in extents) {
      if (pos >= end) break;
      if (e.endLba <= pos) continue;

      if (pos < e.startLba) {
        final gapEnd = e.startLba < end ? e.startLba : end;
        result.add(Segment(pos, gapEnd - pos, null, 0));
        pos = gapEnd;
        if (pos >= end) break;
      }

      final segEnd = e.endLba < end ? e.endLba : end;
      result.add(Segment(
          pos, segEnd - pos, e.file, e.fileSector + pos - e.startLba,
          cooked: e.cooked));
      pos = segEnd;
    }

    if (pos < end) {
      result.add(Segment(pos, end - pos, null, 0));
    }

    return result;
  }

  /// reads [count] raw sectors (2352 bytes) from [lba]. cooked sectors are
  /// expanded to raw mode 1 ones, and gaps are filled with zero. the range
  /// must be readable.
  @override
  Future<List<Uint8List>> readSectors(int lba, int count) async {
    final result = <Uint8List>[];
    for (final seg in segments(lba, count)) {
      final file = seg.file;
      if (file == null) {
        result.addAll(List.generate(seg.count, (_) => Uint8List(sectorSize)));
        continue;
      }

      final size = seg.cooked ? cookedSectorSize : sectorSize;
      final bytes = await file.read(seg.fileSector * size, seg.count * size);
      for (int i = 0; i < seg.count; i++) {
        final data = Uint8List(size); // zero padded at EOF
        final start = i * size;
        if (start < bytes.length) {
          final end = (start + size).clamp(0, bytes.length);
          data.setRange(0, end - start, bytes, start);
        }
        result.add(seg.cooked ? mode1Sector(data, seg.lba + i) : data);
      }
    }
    return result;
  }

  /// expands 2048 bytes of user data at [lba] to a raw mode 1 sector. EDC/ECC
  /// are left zero, as the cores do not correct errors.
  static Uint8List mode1Sector(Uint8List data, int lba) {
    if (data.length != cookedSectorSize) {
      throw ArgumentError('Mode 1 data must be 2048 bytes');
    }
    final msf = lba + 150; // with lead-in
    int bcd(int value) => ((value ~/ 10) << 4) | (value % 10);
    return Uint8List(sectorSize)
      ..setAll(0, sync)
      ..setAll(
          12, [bcd(msf ~/ (60 * 75)), bcd(msf ~/ 75 % 60), bcd(msf % 75), 1])
      ..setAll(16, data);
  }

  static const cookedSectorSize = 2048;

  /// the sectors of a file of [bytes]
  static int sectorsOf(int bytes, bool cooked) {
    final size = cooked ? cookedSectorSize : sectorSize;
    return (bytes + size - 1) ~/ size;
  }
}

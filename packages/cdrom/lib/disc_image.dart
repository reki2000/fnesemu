import 'dart:typed_data';

import 'disc_source.dart';

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

/// a disc image opened from a .cue or a .iso/.bin file: the TOC, and the raw
/// sectors by LBA (without lead-in)
class DiscImage {
  static const sectorSize = 2352;
  static const sync = [
    0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0 // 12 bytes
  ];

  final DiscSource source;
  final DiscToc toc;
  final List<Extent> extents; // sorted by startLba

  DiscImage(this.source, this.toc, this.extents);

  int get totalSectors => toc.totalSectors;

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

  /// reads the TOC of [source]. the files of [source] are closed by [close].
  static Future<DiscImage> open(DiscSource source) =>
      source.isCue ? _buildCue(source) : _buildImage(source);

  Future<void> close() => source.close();

  /// reads [count] raw sectors (2352 bytes) from [lba]. cooked sectors are
  /// expanded to raw mode 1 ones, and gaps are filled with zero. the range
  /// must be readable.
  Future<List<Uint8List>> readSectors(int lba, int count) async {
    final result = <Uint8List>[];
    for (final seg in segments(lba, count)) {
      final file = seg.file;
      if (file == null) {
        result.addAll(List.generate(seg.count, (_) => Uint8List(sectorSize)));
        continue;
      }

      final size = seg.cooked ? _cookedSectorSize : sectorSize;
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
    if (data.length != _cookedSectorSize) {
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

  /// the file names of the FILE commands of a .cue file
  static List<String> cueFileNames(String cue) => [
        for (final line in cue.split("\n"))
          if (_splitLine(line.trim()) case [final cmd, final name, ...]
              when cmd.toUpperCase() == "FILE")
            name
      ];

  static const _cookedSectorSize = 2048;

  /// a single data track, raw (2352 bytes/sector) or cooked (2048 bytes)
  static Future<DiscImage> _buildImage(DiscSource source) async {
    final file = source.main;
    final length = await file.length();
    final cooked = await _isCooked(file, length, source.name);
    final sectors = _sectorsOf(length, cooked);
    if (sectors == 0) {
      throw const FormatException("cdrom: empty image");
    }
    return DiscImage(
        source,
        DiscToc([DiscTrack(1, false, 0, sectors)], sectors),
        [Extent(0, sectors, file, 0, cooked: cooked)]);
  }

  // raw images start with the sync pattern. cooked ones have "CD001" at
  // sector 16, or are an .iso whose size is a multiple of 2048 without sync
  static Future<bool> _isCooked(DiscFile file, int length, String name) async {
    // a size which is a multiple of 2352 but not of 2048 is a raw image
    if (length % sectorSize == 0 && length % _cookedSectorSize != 0) {
      return false;
    }
    final head = await file.read(0, sync.length);
    var hasSync = head.length == sync.length;
    for (int i = 0; hasSync && i < sync.length; i++) {
      hasSync = head[i] == sync[i];
    }
    if (hasSync) return false;

    const pvd = 16 * _cookedSectorSize + 1;
    if (length > pvd + 5 &&
        String.fromCharCodes(await file.read(pvd, 5)) == "CD001") {
      return true;
    }
    return name.toLowerCase().endsWith(".iso") &&
        length % _cookedSectorSize == 0;
  }

  static int _sectorsOf(int bytes, bool cooked) {
    final size = cooked ? _cookedSectorSize : sectorSize;
    return (bytes + size - 1) ~/ size;
  }

  static Future<DiscImage> _buildCue(DiscSource source) async {
    final files = _parseCue(await readText(source.main));
    if (files.isEmpty || files.every((f) => f.tracks.isEmpty)) {
      throw const FormatException("cdrom: cue: no tracks");
    }

    final extents = <Extent>[];
    final tracks = <(int, bool, int)>[]; // number, isAudio, startLba

    int lba = 0;
    for (final f in files) {
      final file = source.open(f.name);
      final cooked = f.tracks.any((t) => t.isCooked);
      final fileSectors = _sectorsOf(await file.length(), cooked);

      // silence not stored in the file, inserted at the file position
      final gaps = <(int, int)>[]; // (fileSector, sectors)
      for (int i = 0; i < f.tracks.length; i++) {
        final t = f.tracks[i];
        if (t.pregap > 0) {
          gaps.add((t.firstIndex, t.pregap));
        }
        if (t.postgap > 0) {
          final next = i + 1 < f.tracks.length
              ? f.tracks[i + 1].firstIndex
              : fileSectors;
          gaps.add((next, t.postgap));
        }
      }
      gaps.sort((a, b) => a.$1.compareTo(b.$1));

      int fileSector = 0;
      final fileExtents = <Extent>[];
      for (final (pos, len) in gaps) {
        final p = pos.clamp(fileSector, fileSectors);
        if (p > fileSector) {
          fileExtents.add(
              Extent(lba, p - fileSector, file, fileSector, cooked: cooked));
          lba += p - fileSector;
          fileSector = p;
        }
        lba += len;
      }
      if (fileSector < fileSectors) {
        fileExtents.add(Extent(lba, fileSectors - fileSector, file, fileSector,
            cooked: cooked));
        lba += fileSectors - fileSector;
      }
      extents.addAll(fileExtents);

      for (final t in f.tracks) {
        final start = _lbaOfFileSector(fileExtents, t.index1) ?? lba;
        tracks.add((t.number, t.isAudio, start));
      }
    }

    final total = lba;
    final tocTracks = <DiscTrack>[];
    for (int i = 0; i < tracks.length; i++) {
      final (number, isAudio, start) = tracks[i];
      final end = i + 1 < tracks.length ? tracks[i + 1].$3 : total;
      tocTracks.add(DiscTrack(number, isAudio, start, end - start));
    }

    return DiscImage(source, DiscToc(tocTracks, total), extents);
  }

  /// the LBA of [fileSector], placed after the gap inserted at the position
  static int? _lbaOfFileSector(List<Extent> extents, int fileSector) {
    for (final e in extents) {
      if (fileSector >= e.fileSector && fileSector < e.fileSector + e.sectors) {
        return e.startLba + fileSector - e.fileSector;
      }
    }
    return null;
  }

  static List<_CueFile> _parseCue(String cue) {
    final files = <_CueFile>[];
    _CueTrack? track;

    for (final line in cue.split("\n")) {
      final parts = _splitLine(line.trim());
      if (parts.isEmpty) continue;

      switch (parts[0].toUpperCase()) {
        case "FILE":
          if (parts.length < 2) {
            throw const FormatException("cdrom: cue: FILE requires a path");
          }
          if (parts.length > 2 && parts[2].toUpperCase() != "BINARY") {
            throw FormatException(
                "cdrom: cue: unsupported FILE type ${parts[2]}");
          }
          files.add(_CueFile(parts[1]));
          track = null;

        case "TRACK":
          if (files.isEmpty || parts.length < 3) {
            throw const FormatException("cdrom: cue: invalid TRACK");
          }
          track = _CueTrack(
              int.tryParse(parts[1]) ?? 0,
              parts[2].toUpperCase() == "AUDIO",
              parts[2].toUpperCase() == "MODE1/2048");
          files.last.tracks.add(track);

        case "INDEX":
          if (track == null || parts.length < 3) {
            throw const FormatException("cdrom: cue: invalid INDEX");
          }
          final no = int.tryParse(parts[1]) ?? -1;
          final pos = _msfToSectors(parts[2]);
          if (no == 0) {
            track.index0 = pos;
          } else if (no == 1) {
            track.index1 = pos;
          }

        case "PREGAP":
          track?.pregap = _msfToSectors(parts[1]);

        case "POSTGAP":
          track?.postgap = _msfToSectors(parts[1]);
      }
    }

    return files;
  }

  static List<String> _splitLine(String line) => RegExp(r'(".*?"|\S+)')
      .allMatches(line)
      .map((m) => m.group(0)!.replaceAll('"', ''))
      .toList();

  static int _msfToSectors(String msf) {
    final p = msf.split(":").map(int.parse).toList();
    if (p.length != 3) {
      throw FormatException("cdrom: cue: invalid MSF '$msf'");
    }
    return (p[0] * 60 + p[1]) * 75 + p[2];
  }
}

class _CueFile {
  final String name;
  final tracks = <_CueTrack>[];
  _CueFile(this.name);
}

class _CueTrack {
  final int number;
  final bool isAudio;
  final bool isCooked; // MODE1/2048
  int index0 = -1;
  int index1 = 0;
  int pregap = 0;
  int postgap = 0;

  _CueTrack(this.number, this.isAudio, this.isCooked);

  int get firstIndex => index0 >= 0 ? index0 : index1;
}

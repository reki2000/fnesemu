import '../core/cdrom_drive.dart';
import '../core/disc.dart';
import 'image_file.dart';

/// a contiguous region of sectors stored in a file
class Extent {
  final int startLba;
  final int sectors;
  final ImageFile file;
  final int fileSector; // sector offset in the file

  const Extent(this.startLba, this.sectors, this.file, this.fileSector);

  int get endLba => startLba + sectors;
}

/// a part of a read request: [count] sectors from [lba], stored in [file] from
/// [fileSector], or silence (gap) if [file] is null
class Segment {
  final int lba;
  final int count;
  final ImageFile? file;
  final int fileSector;

  const Segment(this.lba, this.count, this.file, this.fileSector);
}

/// maps LBAs to the image files, built from a .cue or a .iso/.bin file
class DiscLayout {
  final CdromToc toc;
  final List<Extent> extents; // sorted by startLba

  DiscLayout(this.toc, this.extents);

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
      result.add(
          Segment(pos, segEnd - pos, e.file, e.fileSector + pos - e.startLba));
      pos = segEnd;
    }

    if (pos < end) {
      result.add(Segment(pos, end - pos, null, 0));
    }

    return result;
  }

  static Future<DiscLayout> build(DiscSource source) =>
      source.isCue ? _buildCue(source) : _buildImage(source);

  /// a single raw (2352 bytes/sector) data track
  static Future<DiscLayout> _buildImage(DiscSource source) async {
    final file = source.main;
    final sectors = _sectorsOf(await file.length());
    if (sectors == 0) {
      throw const FormatException("cdrom: empty image");
    }
    return DiscLayout(CdromToc([CdromTrack(1, false, 0, sectors)], sectors),
        [Extent(0, sectors, file, 0)]);
  }

  static int _sectorsOf(int bytes) =>
      (bytes + Disc.sectorSize - 1) ~/ Disc.sectorSize;

  static Future<DiscLayout> _buildCue(DiscSource source) async {
    final files = _parseCue(await source.main.readText());
    if (files.isEmpty || files.every((f) => f.tracks.isEmpty)) {
      throw const FormatException("cdrom: cue: no tracks");
    }

    final extents = <Extent>[];
    final tracks = <(int, bool, int)>[]; // number, isAudio, startLba

    int lba = 0;
    for (final f in files) {
      final file = await source.open(f.name);
      final fileSectors = _sectorsOf(await file.length());

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
          fileExtents.add(Extent(lba, p - fileSector, file, fileSector));
          lba += p - fileSector;
          fileSector = p;
        }
        lba += len;
      }
      if (fileSector < fileSectors) {
        fileExtents
            .add(Extent(lba, fileSectors - fileSector, file, fileSector));
        lba += fileSectors - fileSector;
      }
      extents.addAll(fileExtents);

      for (final t in f.tracks) {
        final start = _lbaOfFileSector(fileExtents, t.index1) ?? lba;
        tracks.add((t.number, t.isAudio, start));
      }
    }

    final total = lba;
    final tocTracks = <CdromTrack>[];
    for (int i = 0; i < tracks.length; i++) {
      final (number, isAudio, start) = tracks[i];
      final end = i + 1 < tracks.length ? tracks[i + 1].$3 : total;
      tocTracks.add(CdromTrack(number, isAudio, start, end - start));
    }

    return DiscLayout(CdromToc(tocTracks, total), extents);
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
              int.tryParse(parts[1]) ?? 0, parts[2].toUpperCase() == "AUDIO");
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
  int index0 = -1;
  int index1 = 0;
  int pregap = 0;
  int postgap = 0;

  _CueTrack(this.number, this.isAudio);

  int get firstIndex => index0 >= 0 ? index0 : index1;
}

// .cue sheets: the tracks in one or more BINARY files, with INDEX 00/01,
// PREGAP and POSTGAP
import '../../image_api.dart';
import '../disc_source.dart';
import '../file_image.dart';

class CueImage {
  static Future<FileImage> open(DiscSource source) async {
    final files = _parseCue(await readText(source.main));
    if (files.isEmpty || files.every((f) => f.tracks.isEmpty)) {
      throw const FormatException("cdrom: cue: no tracks");
    }

    final extents = <Extent>[];
    final tracks = <(int, bool, int)>[]; // number, isAudio, startLba

    int lba = 0;
    for (final f in files) {
      final file = source.resolve(f.name);
      final cooked = f.tracks.any((t) => t.isCooked);
      final fileSectors = FileImage.sectorsOf(await file.length(), cooked);

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

    return FileImage(source, DiscToc(tocTracks, total), extents);
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
          if (parts.length < 2) {
            throw const FormatException("cdrom: cue: PREGAP requires a time");
          }
          track?.pregap = _msfToSectors(parts[1]);

        case "POSTGAP":
          if (parts.length < 2) {
            throw const FormatException("cdrom: cue: POSTGAP requires a time");
          }
          track?.postgap = _msfToSectors(parts[1]);
      }
    }

    return files;
  }

  /// the file names of the FILE commands of a .cue file
  static List<String> fileNames(String cue) => [
        for (final line in cue.split("\n"))
          if (_splitLine(line.trim()) case [final cmd, final name, ...]
              when cmd.toUpperCase() == "FILE")
            name
      ];

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

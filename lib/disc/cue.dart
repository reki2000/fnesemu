import 'dart:io';
import 'dart:typed_data';

import '../util/debug.dart';
import '../util/int.dart';
import 'disc.dart';

enum TrackMode { audio, mode1, mode2 }

class _Track {
  final int number;
  final TrackMode mode;
  final int fileIndex; // index into _images, -1 for untracked files
  int startLBA = 0; // relative to file start, set later from INDEX
  int pregap = 0; // implicit silence sectors before this track (not in file)
  int postgap = 0; // implicit silence sectors after this track (not in file)
  int dataSectors = 0; // set later from file size and INDEX
  _Track(this.number, this.mode, this.fileIndex);
}

List<String> _splitLine(String line) {
  final parts = <String>[];
  final regex = RegExp(r'(".*?"|\S+)');
  for (final match in regex.allMatches(line)) {
    parts.add(match.group(0)!.replaceAll('"', ''));
  }
  return parts;
}

int _msfToLBA(String msf) {
  final p = msf.split(":").map(int.parse).toList();
  if (p.length != 3) {
    throw FormatException("disc: cue: invalid MSF '$msf'");
  }
  return (p[0] * 60 + p[1]) * 75 + p[2];
}

TrackMode _parseMode(String s) {
  final u = s.toUpperCase();
  if (u == "AUDIO") return TrackMode.audio;
  if (u.startsWith("MODE2")) return TrackMode.mode2;
  return TrackMode.mode1;
}

class CueDisc extends Disc {
  final String _cuePath;
  final List<Uint8List> _images = [];
  final List<_Track> _tracks = [];

  CueDisc(this._cuePath) {
    try {
      final cue = File(_cuePath).readAsStringSync();
      debugLog("disc: cue: Loaded cue $_cuePath. ${cue.length.format3} bytes.");
      _parse(cue);
      _logSummary();
    } catch (e) {
      debugLog("disc: cue: Error on loading cue from $_cuePath. $e");
    }
  }

  @override
  int get trackCount => _tracks.length;

  @override
  int get totalSectors =>
      _tracks.isEmpty ? 0 : _tracks.last.startLBA + _tracks.last.dataSectors;

  @override
  int startLba(int trackNo) {
    if (trackNo < 1 || trackNo > _tracks.length) {
      throw RangeError("disc: cue: invalid track number $trackNo");
    }
    return _tracks[trackNo - 1].startLBA;
  }

  @override
  bool get isEmpty => _tracks.isEmpty;

  // returns whole sector date without sync
  @override
  Uint8List read(int sector) {
    sector -= 2 * 75; // skip lead-in (sector is MSF-style)
    if (sector < 0) return Uint8List(0);

    // Linear scan; region count is small (one per FILE + optional gaps).
    for (final t in _tracks) {
      if (t.startLBA <= sector && sector < t.startLBA + t.dataSectors) {
        // before track start: in pregap silence
        final sectorPosition = sector - t.startLBA;
        return _images[t.fileIndex].sublist(sectorPosition * Disc.sectorSize,
            (sectorPosition + 1) * Disc.sectorSize);
      }
    }

    return Uint8List(0); // out of range
  }

  void _parse(String cue) {
    int fileIndex = -1;
    _Track currentTrack =
        _Track(0, TrackMode.mode1, -1); // dummy track for untracked files

    for (final line in cue.split("\n")) {
      final parts = _splitLine(line.trim());
      if (parts.isEmpty) continue;

      final cmd = parts[0].toUpperCase();

      switch (cmd) {
        case "FILE":
          final filePath = parts[1];
          final fullPath = "${File(_cuePath).parent.absolute.path}/$filePath";
          try {
            final bytes = File(fullPath).readAsBytesSync();
            _images.add(bytes);
            fileIndex = _images.length - 1;
            debugLog(
                "disc: .cue $filePath ${bytes.length.format3} bytes (${bytes.length ~/ Disc.sectorSize} sectors)");
          } catch (e) {
            debugLog("disc: cue: error reading $fullPath: $e");
            return;
          }

        case "TRACK":
          if (fileIndex == -1) {
            debugLog("disc: cue: TRACK before FILE, ignored");
            return;
          }
          final number = int.tryParse(parts[1]) ?? 0;
          if (number != _tracks.length + 1) {
            debugLog(
                "disc: cue: non-sequential track number $number, expected ${_tracks.length + 1}");
            return;
          }
          final mode = _parseMode(parts[2]);
          currentTrack = _Track(number, mode, fileIndex);
          _tracks.add(currentTrack);

        case "INDEX":
          if (parts[1] != "01") {
            debugLog("disc: cue: unsupported INDEX ${parts[1]}, ignored");
            return;
          }
          final lba = _msfToLBA(parts[2]);
          if (currentTrack.number == 0) {
            debugLog(
                "disc: cue: INDEX before TRACK, treating as untracked file with single INDEX");
            return;
          }
          if (currentTrack.number == 1) {
            currentTrack.startLBA =
                currentTrack.pregap + lba; // relative to file start4
          } else {
            final prevTrack = _tracks.last;

            final prevTrackEndLba =
                prevTrack.startLBA + prevTrack.pregap + prevTrack.postgap;

            prevTrack.dataSectors = lba -
                currentTrack.pregap -
                prevTrack.postgap -
                prevTrack.startLBA;

            currentTrack.startLBA = prevTrackEndLba +
                currentTrack.pregap +
                lba; // relative to file start4
          }

        case "PREGAP":
          currentTrack.pregap = _msfToLBA(parts[1]);

        case "POSTGAP":
          currentTrack.postgap = _msfToLBA(parts[1]);
      }

      if (currentTrack.number > 0) {
        currentTrack.dataSectors =
            (_images[currentTrack.fileIndex].length ~/ Disc.sectorSize) -
                currentTrack.startLBA;
      }
    }

    _logSummary();
  }

  void _logSummary() {
    debugLog(
        "disc: cue: parsed $trackCount track(s), total $totalSectors sectors:");
    for (final t in _tracks) {
      debugLog(
          "disc: cue: track ${t.number} mode:${t.mode.name} startLBA:${t.startLBA} size:${t.dataSectors} pregap:${t.pregap} postgap:${t.postgap}");
    }
  }
}

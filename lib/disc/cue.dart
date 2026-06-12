import 'dart:io';
import 'dart:typed_data';

import '../core/disc.dart';
import '../util/debug.dart';
import '../util/int.dart';

enum TrackMode { audio, mode1, mode2 }

class _Track {
  int offsetInImage = 0; // byte offset from _images[fileIndex]
  int startLBA = 0; // relative to file start, set later from INDEX
  int dataSectors = 0; // set later from file size and INDEX

  final int number;
  final TrackMode mode;
  final int imageIndex; // index into _images, -1 for untracked files

  List<int> index = [];
  int pregap = 0; // implicit silence sectors before this track (not in file)
  int postgap = 0; // implicit silence sectors after this track (not in file)
  _Track(this.number, this.mode, this.imageIndex);
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

  @override
  bool isAudio(int trackNo) => _tracks[trackNo - 1].mode == TrackMode.audio;

  // returns whole sector date without sync
  @override
  Uint8List read(int sector) {
    sector -= 2 * 75; // skip lead-in (sector is MSF-style)

    for (final t in _tracks) {
      if (t.startLBA <= sector && sector < t.startLBA + t.dataSectors) {
        final offset =
            (sector - t.startLBA) * Disc.sectorSize + t.offsetInImage;
        final sectorData =
            _images[t.imageIndex].sublist(offset, offset + Disc.sectorSize);
        _logReadSector(sector, sectorData);
        return sectorData;
      }
    }

    debugLog("cue: gap or out of range: ${Disc.dumpSector(sector)}");
    return Uint8List(0); // out of range
  }

  void _parse(String cue) {
    int imageIndex = -1;
    _Track currentTrack =
        _Track(0, TrackMode.mode1, -1); // dummy track for untracked files

    for (final line in cue.split("\n")) {
      final parts = _splitLine(line.trim());
      if (parts.isEmpty) continue;

      final cmd = parts[0].toUpperCase();

      switch (cmd) {
        case "FILE":
          if (parts.length > 2 && parts[2] != "BINARY") {
            debugLog("disc: cue: unsupported FILE type ${parts[2]}, ignored");
            return;
          }

          if (parts.length < 2) {
            debugLog("disc: cue: FILE command requires a file path");
            return;
          }
          final filePath = parts[1];
          final fullPath = "${File(_cuePath).parent.absolute.path}/$filePath";
          try {
            final bytes = File(fullPath).readAsBytesSync();
            if (bytes.length % Disc.sectorSize != 0) {
              debugLog(
                  "cue: file size is not the multiple of sector size, applied padding: ${bytes.length}");
              bytes.addAll(
                  Uint8List(Disc.sectorSize - bytes.length % Disc.sectorSize));
            }
            _images.add(bytes);
            imageIndex = _images.length - 1;
            debugLog(
                "disc: cue $filePath ${bytes.length.format3} bytes (${bytes.length ~/ Disc.sectorSize} sectors)");
          } catch (e) {
            debugLog("disc: cue: error reading $fullPath: $e");
            return;
          }

        case "TRACK":
          if (imageIndex == -1) {
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
          currentTrack = _Track(number, mode, imageIndex);
          _tracks.add(currentTrack);

        case "INDEX":
          final relativeSector = _msfToLBA(parts[2]);
          if (parts[1] == "01" && currentTrack.index.isEmpty) {
            currentTrack.index
                .add(relativeSector); // add index:00 as the same of index:01
          }
          currentTrack.index.add(relativeSector);

        case "PREGAP":
          currentTrack.pregap = _msfToLBA(parts[1]);

        case "POSTGAP":
          currentTrack.postgap = _msfToLBA(parts[1]);
      }
    }

    int imageLba = 0;
    int offsetInImage = 0;
    _tracks[0].startLBA = _tracks[0].index[1];

    for (int i = 1; i < _tracks.length; i++) {
      final prev = _tracks[i - 1];
      final t = _tracks[i];

      if (prev.imageIndex != t.imageIndex) {
        prev.dataSectors =
            (_images[prev.imageIndex].length - prev.offsetInImage) ~/
                Disc.sectorSize;
        imageLba = prev.startLBA + prev.dataSectors + prev.postgap;
        offsetInImage = 0;
      } else {
        prev.dataSectors =
            (t.index[0] - t.pregap - prev.postgap - prev.startLBA);
        offsetInImage += prev.dataSectors * Disc.sectorSize;
      }
      t.startLBA = t.index[1] + imageLba;
      t.offsetInImage = offsetInImage;
    }
    _tracks.last.dataSectors = (_images[_tracks.last.imageIndex].length -
            _tracks.last.offsetInImage) ~/
        Disc.sectorSize;
  }

  void _logSummary() {
    debugLog(
        "disc: cue: parsed $trackCount track(s), total $totalSectors sectors:");
    for (final t in _tracks) {
      debugLog(
          "disc: cue: track ${t.number} mode:${t.mode.name} startLBA:${Disc.dumpSector(t.startLBA)} size:${t.dataSectors} pregap:${t.pregap} postgap:${t.postgap}");
    }
  }

  void _logReadSector(int sector, List<int> data) {
    final headerOffset = Disc.sync.length;
    final minutes = data[headerOffset];
    final seconds = data[headerOffset + 1];
    final sectorNumber = data[headerOffset + 2];
    final mode = data[headerOffset + 3];
    final file = data[headerOffset + 4];
    final channel = data[headerOffset + 5];
    final submode = data[headerOffset + 6];
    final codinginfo = data[headerOffset + 7];
    debugLog(
        "iso: read sector $sector cue: (${minutes.hex8}:${seconds.hex8}:${sectorNumber.hex8}) "
        "mode:$mode file:$file channel:$channel submode:${submode.hex8} codinginfo:${codinginfo.hex8}"
        "[${data.sublist(Disc.sync.length, Disc.sync.length + 16).map((e) => e.hex8).join(" ")}...]");
  }
}

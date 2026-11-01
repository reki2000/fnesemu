import 'dart:typed_data';

import '../../cdrom_drive.dart';
import '../../state.dart';
import 'fault.dart';

/// Functional CD-DA transport; seek and sample-boundary timing need hardware tests.
class DcOpticalAudio {
  bool playing = false, resumable = false;
  int fad = 150, _start = 150, _end = 150, _repeat = 0, _frame = 0;
  Uint8List? _sector;
  int _scanStep = 0;
  bool get scanning => playing && _scanStep != 0;
  int _terminalStatus = 0x15;
  int get repeatRemaining => resumable ? _repeat : 0;
  int get status => playing
      ? 0x11
      : resumable
          ? 0x12
          : _terminalStatus;

  void saveState(StateWriter writer) {
    writer.section('dc.drive.audio');
    writer
        .ints([fad, _start, _end, _repeat, _frame, _scanStep, _terminalStatus]);
    writer.boolean(playing);
    writer.boolean(resumable);
    writer.boolean(_sector != null);
    if (_sector != null) writer.bytes(_sector!);
  }

  void loadState(StateReader reader) {
    reader.section('dc.drive.audio');
    final values = reader.ints();
    final active = reader.boolean(), paused = reader.boolean();
    final sector = reader.boolean() ? reader.bytes() : null;
    if (values.length != 7 ||
        values.take(3).any((value) => value < 150) ||
        values[3] < 0 ||
        values[3] > 15 ||
        values[4] < 0 ||
        values[4] >= 588 ||
        ![0, -2, 2, -5, 5, -9, 9, -16, 16].contains(values[5]) ||
        ![0x13, 0x14, 0x15].contains(values[6]) ||
        (active && !paused) ||
        (paused && values[2] <= values[1]) ||
        (sector != null && sector.length != 2352)) {
      throw const StateMismatch('Drive audio transport state');
    }
    fad = values[0];
    _start = values[1];
    _end = values[2];
    _repeat = values[3];
    _frame = values[4];
    _scanStep = values[5];
    _terminalStatus = values[6];
    playing = active;
    resumable = paused;
    _sector = sector;
  }

  /// End results are reported once by a subchannel response carrying status.
  int takeStatus() {
    final result = status;
    if (result == 0x13 || result == 0x14) _terminalStatus = 0x15;
    return result;
  }

  void fail() {
    _scanStep = 0;
    playing = resumable = false;
    _sector = null;
    _terminalStatus = 0x14;
  }

  void reset() {
    _scanStep = 0;
    _terminalStatus = 0x15;
    playing = resumable = false;
    fad = _start = _end = 150;
    _repeat = _frame = 0;
    _sector = null;
  }

  void start(int start, int end, int repeat) {
    if (start < 150 || end <= start || repeat < 0 || repeat > 15) {
      throw ArgumentError('Invalid CD audio range');
    }
    _scanStep = 0;
    fad = _start = start;
    _end = end;
    _repeat = repeat;
    _frame = 0;
    _sector = null;
    _terminalStatus = 0x15;
    playing = resumable = true;
  }

  void pause() {
    playing = false;
    _scanStep = 0;
  }

  bool scan({required bool reverse, required int speed}) {
    if (speed < 0 || speed > 255) throw ArgumentError.value(speed, 'speed');
    if (!resumable) return false;
    final rate = speed < 3
        ? 2
        : speed < 6
            ? 5
            : speed < 10
                ? 9
                : 16;
    _scanStep = reverse ? -rate : rate;
    playing = true;
    return true;
  }

  bool resume() {
    if (!resumable) return false;
    _scanStep = 0;
    if (fad >= _end) {
      playing = resumable = false;
      _terminalStatus = 0x13;
    } else {
      playing = true;
    }
    return true;
  }

  void _advanceScan(int sectors) {
    final position = (fad - 150) * 588 + _frame + _scanStep;
    final end = sectors * 588;
    if (position < 0 || position >= end) {
      fad = position < 0 ? 150 : sectors + 150;
      _frame = 0;
      _sector = null;
      pause();
      return;
    }
    final nextFad = 150 + position ~/ 588;
    if (nextFad != fad) _sector = null;
    fad = nextFad;
    _frame = position % 588;
  }

  /// One stereo frame in the drive adapter's little-endian raw-sector order.
  /// Host cache misses emit silence and retain the next unconsumed frame.
  (int, int) sample(CdromDrive drive) {
    if (!playing || drive.status.isSeeking) return (0, 0);
    if (!drive.status.isReady || drive.status.seekError) {
      fail();
      return (0, 0);
    }
    final sectors = drive.status.toc.totalSectors;
    var sourceFad = fad, sourceFrame = _frame;
    if (scanning && fad >= sectors + 150) {
      if (_scanStep > 0 || sectors == 0) {
        pause();
        return (0, 0);
      }
      sourceFad = sectors + 149;
      sourceFrame = 587;
    }
    final audio = drive.status.toc.isAudioLba(sourceFad - 150);
    if (audio && _sector == null) {
      final raw = drive.read(sourceFad - 150);
      if (raw == null) return (0, 0);
      if (raw.length != 2352) {
        throw const DcUnsupported(
            'Optical drive invalid CD audio sector length');
      }
      _sector = raw;
    }
    var left = 0, right = 0;
    if (audio) {
      final offset = sourceFrame * 4, raw = _sector!;
      left = (raw[offset] | raw[offset + 1] << 8).toSigned(16);
      right = (raw[offset + 2] | raw[offset + 3] << 8).toSigned(16);
    }
    fad = sourceFad;
    _frame = sourceFrame;
    if (scanning) {
      _advanceScan(sectors);
      return (left, right);
    }
    _frame++;
    if (_frame == 588) {
      _frame = 0;
      _sector = null;
      fad++;
      if (fad == _end) {
        // Reaching physical lead-out terminates even an endless request.
        if (_repeat != 0 && fad < drive.status.toc.totalSectors + 150) {
          if (_repeat != 15) _repeat--;
          fad = _start;
          drive.seek(fad - 150);
        } else {
          playing = resumable = false;
          _terminalStatus = 0x13;
        }
      }
    }
    return (left, right);
  }
}

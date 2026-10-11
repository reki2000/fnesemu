import 'dart:typed_data';

import '../../../cdrom.dart';
import '../../../util/int.dart';

/// Ten-nibble CDD command/status protocol and 75 Hz disc transport.
class CdDrive {
  CdromDrive disc = EmptyCdromDrive();
  final command = Uint8List(10);
  final response = Uint8List(10);
  final void Function(Uint8List) onSector;
  final void Function() interrupt;
  CdDrive(this.onSector, this.interrupt) {
    reset();
  }

  int status = 0xb, lba = 0, track = 1;
  bool hostClock = false;
  int _query = 0, _seekTicks = 0, _sectorAudioLba = -1;
  int _seekStatus = 4, _currentLba = -1;
  Uint8List _audio = Uint8List(0);
  int _audioPhase = 0;
  double volume = 1;

  void mount(CdromDrive value) {
    disc = value;
    reset();
    value.clearEvents();
  }

  void _pollDriveEvent() {
    final event = disc.takeEvent();
    switch (event?.type) {
      case CdromDriveEventType.trayOpened || CdromDriveEventType.trayClosed:
        _noDisc();
      case CdromDriveEventType.discReady:
        if (event!.discId != disc.status.discId) return;
        status = 9;
        lba = 0;
      case CdromDriveEventType.discError:
        if (event!.discId == disc.status.discId) _noDisc();
      case null:
        break;
    }
  }

  void _noDisc() {
    status = 0xb;
    lba = _seekTicks = 0;
    track = 1;
    _sectorAudioLba = _currentLba = -1;
    _audio = Uint8List(0);
  }

  void reset() {
    disc.clearEvents();
    status = disc.isEmpty ? 0xb : 9;
    lba = _query = _seekTicks = _audioPhase = 0;
    track = 1;
    hostClock = false;
    volume = 1;
    _sectorAudioLba = _currentLba = -1;
    _audio = Uint8List(0);
    command.fillRange(0, 10, 0);
    _holdResponse = true;
    // The host sees a reset packet until it submits its first command.
    response.fillRange(0, 10, 0);
    response[9] = 15;
  }

  int trackAt(int position) {
    int result = 1;
    for (int i = 1; i <= disc.trackCount; i++) {
      if (position >= disc.startLba(i)) result = i;
    }
    return result;
  }

  bool get playingAudio =>
      status == 1 &&
      _currentLba >= 0 &&
      !disc.isEmpty &&
      disc.isAudio(trackAt(_currentLba));

  void submit() {
    if (!hostClock) return;
    final checksum = (~command.take(9).fold<int>(0, (a, b) => a + b)).mask4;
    if (checksum != command[9]) return;
    final op = command[0];
    if (op != 0 && op != 2) _seekTicks = 0;
    if (op == 0xd) {
      status = 5;
    } else if (op == 0xc) {
      status = disc.isEmpty ? 0xb : 9;
    } else if (disc.isEmpty || status == 5) {
      status = status == 5 ? 5 : 0xb;
    } else {
      switch (op) {
        case 1:
          status = 9;
          lba = 0;
        case 2:
          _query = command[3];
        case 3 || 4:
          final position = Msf.ofParts(
                command[2] * 10 + command[3],
                command[4] * 10 + command[5],
                command[6] * 10 + command[7],
              ).frames() -
              cdLbaOffset;
          final target = position.clamp(-cdLbaOffset, disc.totalSectors);
          // the pickup takes a while to move: a fixed latency plus the
          // distance, so the first sector does not come before the host has
          // set up the decoder
          _seekTicks = 10 + (target - lba).abs() ~/ 4500;
          lba = target;
          track = trackAt(lba);
          _audioPhase = 0;
          _seekStatus = op == 3 ? 1 : 4;
          status = 2;
          _sectorAudioLba = _currentLba = -1;
        case 0xa:
          status = 4;
        case 6:
          status = 4;
        case 7:
          status = 1;
        case 8:
          status = 3;
          _scanDirection = 1;
        case 9:
          status = 3;
          _scanDirection = -1;
      }
    }
    if (op == 1 || op == 0xc) {
      _query = 15;
      _updateResponse(transientStatus: disc.isEmpty ? 0xb : 0);
      _holdResponse = true;
    } else {
      _holdResponse = false;
      _updateResponse();
    }
  }

  int _scanDirection = 1;
  bool _settling = false;
  bool _holdResponse = false;

  void tick() {
    _pollDriveEvent();
    if (!hostClock) return;
    if (_seekTicks > 0) {
      _seekTicks--;
      if (_seekTicks == 0) {
        status = _seekStatus;
        _settling = status == 1;
      }
    } else if (_settling) {
      // the drive reports playing a tick before the first sector, so the host
      // sees the status and enables the decoder in time
      _settling = false;
    } else if (status == 1 && !disc.isEmpty) {
      if (lba >= disc.totalSectors) {
        status = 0xc;
      } else {
        final next = trackAt(lba);
        final sector = lba < 0
            ? _pregapSector(lba)
            : !disc.isAudio(next)
                ? disc.read(lba)
                : null;
        if (lba >= 0 && !disc.isAudio(next) && sector == null) {
          // the drive has not read the sector yet: retry on the next tick
        } else {
          _currentLba = lba;
          track = next;
          if (sector != null) onSector(sector);
          lba++;
        }
      }
    } else if (status == 3) {
      lba = (lba + 10 * _scanDirection).clamp(0, disc.totalSectors);
    }
    // the drive reports its status and position every tick. a Stop/Close
    // acknowledgement is kept until the next command, so the host reads it.
    if (!_holdResponse) _updateResponse();
    interrupt();
  }

  /// a sector of the pregap before the first track: no data, but a valid
  /// header, which the BIOS reads to find the start of the data track
  Uint8List _pregapSector(int lba) {
    final sector = Uint8List(2352);
    sector.fillRange(1, 11, 0xff); // sync
    final (m, s, f) = Msf.ofLba(lba).bcd();
    sector[12] = m;
    sector[13] = s;
    sector[14] = f;
    sector[15] = 1; // mode 1
    return sector;
  }

  void _writeTime(Msf time, int offset) {
    final (m, s, f) = time.parts();
    response[offset] = (m ~/ 10).mask4;
    response[offset + 1] = m % 10;
    response[offset + 2] = s ~/ 10;
    response[offset + 3] = s % 10;
    response[offset + 4] = f ~/ 10;
    response[offset + 5] = f % 10;
  }

  void _updateResponse({int? transientStatus}) {
    response.fillRange(0, 10, 0);
    response[0] = transientStatus ?? status;
    response[1] = _query;
    if (!disc.isEmpty && status != 5) {
      track = trackAt(lba);
      switch (_query) {
        case 0:
          _writeTime(Msf.ofLba(lba), 2);
        case 1:
          _writeTime(
              Msf.ofFrames(
                  (lba - disc.startLba(track)).clamp(0, disc.totalSectors)),
              2);
        case 2:
          response[2] = track ~/ 10;
          response[3] = track % 10;
        case 3:
          _writeTime(Msf.ofLba(disc.totalSectors), 2);
        case 4:
          response[2] = 0;
          response[3] = 1;
          response[4] = disc.trackCount ~/ 10;
          response[5] = disc.trackCount % 10;
        case 5:
          final requested = command[4] * 10 + command[5];
          if (requested >= 1 && requested <= disc.trackCount) {
            _writeTime(Msf.ofLba(disc.startLba(requested)), 2);
            if (!disc.isAudio(requested)) response[6] |= 8;
            response[8] = requested % 10;
          }
      }
      if (_query < 3) response[8] = disc.isAudio(track) ? 0 : 4;
    }
    response[9] = (~response.take(9).fold<int>(0, (a, b) => a + b)).mask4;
  }

  (double, double) sample(int outputHz) {
    if (!playingAudio) return (0, 0);
    final lba = _currentLba;
    if (_sectorAudioLba != lba) {
      final data = disc.read(lba);
      if (data == null) return (0, 0); // not read yet: silence, retry
      _sectorAudioLba = lba;
      _audio = data;
      _audioPhase = (_audioPhase - 588 * outputHz).clamp(0, outputHz);
    }
    final frame = _audioPhase ~/ outputHz;
    _audioPhase += 44100;
    final offset = frame * 4;
    if (offset + 3 >= _audio.length) return (0, 0);
    int signed(int i) => (_audio[i] | _audio[i + 1].shl8).rel16;
    return (
      signed(offset) / 32768 * volume,
      signed(offset + 2) / 32768 * volume
    );
  }
}

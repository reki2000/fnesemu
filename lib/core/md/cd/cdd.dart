import 'dart:typed_data';

import '../../disc.dart';
import '../../../disc/empty.dart';

/// Ten-nibble CDD command/status protocol and 75 Hz disc transport.
class CdDrive {
  Disc disc = EmptyDisc();
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

  void mount(Disc value) {
    disc = value;
    reset();
  }

  void reset() {
    status = disc.isEmpty ? 0xb : 9;
    lba = _query = _seekTicks = _audioPhase = 0;
    track = 1;
    hostClock = false;
    volume = 1;
    _sectorAudioLba = _currentLba = -1;
    _audio = Uint8List(0);
    command.fillRange(0, 10, 0);
    _updateResponse();
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
    final checksum = (~command.take(9).fold<int>(0, (a, b) => a + b)) & 15;
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
          final position = ((command[2] * 10 + command[3]) * 60 +
                      command[4] * 10 +
                      command[5]) *
                  75 +
              command[6] * 10 +
              command[7] -
              150;
          lba = position.clamp(0, disc.totalSectors);
          track = trackAt(lba);
          _audioPhase = 0;
          _seekStatus = op == 3 ? 1 : 4;
          status = 2;
          _seekTicks = 1;
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
    } else {
      _updateResponse();
    }
  }

  int _scanDirection = 1;

  void tick() {
    if (!hostClock) return;
    if (_seekTicks > 0) {
      _seekTicks--;
      if (_seekTicks == 0) status = _seekStatus;
    } else if (status == 1 && !disc.isEmpty) {
      if (lba >= disc.totalSectors) {
        status = 0xc;
      } else {
        _currentLba = lba;
        track = trackAt(lba);
        if (!disc.isAudio(track)) onSector(disc.read(lba + 150));
        lba++;
      }
    } else if (status == 3) {
      lba = (lba + 10 * _scanDirection).clamp(0, disc.totalSectors);
    }
    _updateResponse();
    interrupt();
  }

  void _msf(int position, int offset) {
    final (m, s, f) = Disc.lbaToMsf(position);
    response[offset] = (m ~/ 10) & 15;
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
          _msf(lba + 150, 2);
        case 1:
          _msf((lba - disc.startLba(track)).clamp(0, disc.totalSectors), 2);
        case 2:
          response[2] = track ~/ 10;
          response[3] = track % 10;
        case 3:
          _msf(disc.totalSectors + 150, 2);
        case 4:
          response[2] = 0;
          response[3] = 1;
          response[4] = disc.trackCount ~/ 10;
          response[5] = disc.trackCount % 10;
        case 5:
          final requested = command[4] * 10 + command[5];
          if (requested >= 1 && requested <= disc.trackCount) {
            _msf(disc.startLba(requested) + 150, 2);
            if (!disc.isAudio(requested)) response[6] |= 8;
            response[8] = requested % 10;
          }
      }
      if (_query < 3) response[8] = disc.isAudio(track) ? 0 : 4;
    }
    response[9] = (~response.take(9).fold<int>(0, (a, b) => a + b)) & 15;
  }

  (double, double) sample(int outputHz) {
    if (!playingAudio) return (0, 0);
    final sector = _currentLba;
    if (_sectorAudioLba != sector) {
      _sectorAudioLba = sector;
      _audio = disc.read(sector + 150);
      _audioPhase = (_audioPhase - 588 * outputHz).clamp(0, outputHz);
    }
    final frame = _audioPhase ~/ outputHz;
    _audioPhase += 44100;
    final offset = frame * 4;
    if (offset + 3 >= _audio.length) return (0, 0);
    int signed(int i) => (_audio[i] | (_audio[i + 1] << 8)).toSigned(16);
    return (
      signed(offset) / 32768 * volume,
      signed(offset + 2) / 32768 * volume
    );
  }
}

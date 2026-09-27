import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../../disc.dart';
import '../../../disc/empty.dart';
import 'bus.dart';

// Register-level CD interface. Disc.read uses absolute MSF sectors (LBA + 150).
// SCSI bytes advance on ACK edges; $1808 provides the automatic data ACK port.
enum CdPhase { idle, command, data, status, message }

class PceCdrom {
  final Bus bus;
  Disc disc = EmptyDisc();
  bool enabled = false;
  bool backupEnabled = false;
  CdPhase phase = CdPhase.idle;
  final _ports = Uint8List(16);
  final _command = <int>[];
  Uint8List _data = Uint8List(0);
  int _dataIndex = 0;
  bool _ack = false;
  int _status = 0;
  int _sense = 0;
  int _senseCode = 0;
  int _readLba = 0, _remaining = 0, _readClocks = 0;
  int _dmaClocks = 0;
  bool _request = false;
  static const _sectorClocks = 21477270 ~/ 75;

  final adpcmRam = Uint8List(0x10000);
  int _address = 0, _readAddress = 0, _writeAddress = 0, _length = 0;
  int _adpcmControl = 0, _frequency = 0, _nibble = 0, _stepIndex = 0;
  int _sample = 0;
  bool _adpcmPlaying = false, _adpcmEnd = false;
  double _adpcmFraction = 0;
  int _audioStart = 0, _audioEnd = 0, _audioLba = 0, _audioOffset = 0;
  int _audioMode = 0; // 1: repeat, 2: interrupt, 3: stop
  bool _audioPlaying = false, _audioPaused = false;
  Uint8List _audioSector = Uint8List(0);
  double _audioFraction = 0, _cdVolume = 1, _adpcmVolume = 1;
  int _fade = 0;
  final _pcm = [0, 0];
  final _latchedPcm = [0, 0];

  PceCdrom(this.bus);

  void setDisc(Disc value) {
    disc = value;
    enabled = !value.isEmpty;
    reset();
  }

  void reset() {
    backupEnabled = false;
    _ports.fillRange(0, 16, 0);
    _resetDrive();
    _resetAdpcm();
    _frequency = _fade = 0;
    _cdVolume = _adpcmVolume = 1;
    _pcm.fillRange(0, 2, 0);
    _latchedPcm.fillRange(0, 2, 0);
    _irq();
  }

  void _resetDrive() {
    phase = CdPhase.idle;
    _command.clear();
    _data = Uint8List(0);
    _dataIndex = _remaining = _readClocks = _dmaClocks = 0;
    _request = _ack = _audioPlaying = _audioPaused = false;
    _audioSector = Uint8List(0);
    _audioOffset = 0;
    _audioFraction = 0;
    _sense = _senseCode = _status = 0;
    _ports[3] &= ~0x60;
  }

  void _resetAdpcm() {
    _address = _readAddress = _writeAddress = _length = 0;
    _adpcmControl = _nibble = _stepIndex = _sample = 0;
    _adpcmPlaying = _adpcmEnd = false;
    _adpcmFraction = 0;
    _ports[3] &= ~0x0c;
  }

  void _irq() {
    if ((_ports[2] & _ports[3] & 0x7c) != 0) {
      bus.pic.holdIrq2();
    } else {
      bus.pic.acknoledgeIrq2();
    }
  }

  int get _byte => switch (phase) {
        CdPhase.data => _dataIndex < _data.length ? _data[_dataIndex] : 0,
        CdPhase.status => _status,
        CdPhase.message => 0,
        _ => _ports[1],
      };

  int read(int address) {
    if ((address & 0x18c0) == 0x18c0) {
      return (address & 12) == 0 ? const [0, 0xaa, 0x55, 3][address & 3] : 0xff;
    }
    switch (address.mask4) {
      case 0:
        return (phase == CdPhase.idle ? 0 : 0x80) |
            (_request && !_ack ? 0x40 : 0) |
            (phase == CdPhase.message ? 0x20 : 0) |
            (phase == CdPhase.command ||
                    phase == CdPhase.status ||
                    phase == CdPhase.message
                ? 0x10
                : 0) |
            (phase == CdPhase.data ||
                    phase == CdPhase.status ||
                    phase == CdPhase.message
                ? 8
                : 0);
      case 1:
        return _byte;
      case 3:
        backupEnabled = false;
        final result = _ports[3];
        _ports[3] ^= 2;
        return result;
      case 5:
        return _latchedPcm[_ports[3].shr1.mask1].mask8;
      case 6:
        return _latchedPcm[_ports[3].shr1.mask1].shr8;
      case 7:
        return 0;
      case 8:
        final result = _byte;
        if (phase == CdPhase.data && _request && !_ack) _consume();
        return result;
      case 10:
        final result = adpcmRam[_readAddress];
        _readAddress = (_readAddress + 1).mask16;
        _decrementLength();
        return result;
      case 12:
        return (_adpcmPlaying ? 8 : 0) | (_adpcmEnd ? 1 : 0);
      case 13:
        return _adpcmControl;
      default:
        return _ports[address.mask4];
    }
  }

  void write(int address, int value) {
    value &= 0xff;
    final register = address.mask4;
    switch (register) {
      case 0:
        if (phase == CdPhase.idle && !_ports[4].bit1) {
          _command.clear();
          phase = CdPhase.command;
          _request = true;
          _ack = _ports[2].bit7;
          _ports[3] &= ~0x60;
        }
        break;
      case 1:
        _ports[1] = value;
        break;
      case 2:
        final nextAck = value.bit7;
        if (nextAck && !_ack && _request) {
          _consume();
        }
        _ack = nextAck;
        _ports[2] = value;
        break;
      case 3:
      case 12:
        break;
      case 4:
        _ports[4] = value;
        if (value.bit1) _resetDrive();
        break;
      case 5:
      case 6:
        for (var i = 0; i < 2; i++) {
          _latchedPcm[i] = _pcm[i].abs();
        }
        break;
      case 7:
        if (value.bit7) backupEnabled = true;
        break;
      case 8:
      case 9:
        if (!_adpcmControl.bit7) {
          _address = register == 8
              ? (_address & 0xff00) | value
              : _address.mask8 | value.shl8;
          if (_adpcmControl.bit4) _length = _address;
        }
        break;
      case 10:
        _writeAdpcm(value);
        break;
      case 11:
        _ports[11] = value;
        break;
      case 13:
        if (value.bit7) {
          _resetAdpcm();
        } else {
          if (value.bit3 && !_adpcmControl.bit3) {
            _readAddress = (_address - (!value.bit2 ? 1 : 0)).mask16;
          }
          if (value.bit1 && !_adpcmControl.bit1) {
            _writeAddress = (_address - (!value.bit0 ? 1 : 0)).mask16;
          }
          if (value.bit4) {
            _length = _address;
            _adpcmEnd = false;
            _ports[3] &= ~8;
          }
          if (!_adpcmPlaying && value.bit5) {
            _nibble = _sample = _stepIndex = 0;
            _adpcmFraction = 0;
            _ports[3] &= ~4;
          }
          _adpcmPlaying = value.bit5;
          _adpcmControl = value;
        }
        break;
      case 14:
        _frequency = value.mask4;
        break;
      case 15:
        _fade = value;
        if (!value.bit3) _cdVolume = _adpcmVolume = 1;
        break;
    }
    _irq();
  }

  void _consume() {
    switch (phase) {
      case CdPhase.command:
        _command.add(_ports[1]);
        final length = _command.first < 0x20 ? 6 : 10;
        if (_command.length == length) _executeCommand();
        break;
      case CdPhase.data:
        _dataIndex++;
        if (_dataIndex >= _data.length) {
          _ports[3] &= ~0x40;
          if (_remaining > 0) {
            _request = false;
            _readClocks = _sectorClocks;
          } else {
            _finish();
          }
        }
        break;
      case CdPhase.status:
        phase = CdPhase.message;
        break;
      case CdPhase.message:
        phase = CdPhase.idle;
        _request = false;
        _ports[3] &= ~0x20;
        break;
      case CdPhase.idle:
        break;
    }
    _irq();
  }

  void _finish([int status = 0]) {
    _status = status;
    phase = CdPhase.status;
    _request = true;
    _ports[3] = (_ports[3] & ~0x40) | 0x20;
  }

  void _error(int sense, int code) {
    _sense = sense;
    _senseCode = code;
    _remaining = 0;
    _finish(2);
  }

  void _send(List<int> bytes) {
    _data = Uint8List.fromList(bytes);
    _dataIndex = 0;
    phase = CdPhase.data;
    _request = true;
    _ports[3] |= 0x40;
  }

  static int _bcd(int value) => (value ~/ 10 << 4) | value % 10;
  static int _unbcd(int value) => value.shr4 * 10 + value.mask4;
  List<int> _msf(int lba) {
    final (m, s, f) = Disc.lbaToMsf(lba);
    return [_bcd(m), _bcd(s), _bcd(f)];
  }

  int _position() {
    switch (_command[9] & 0xc0) {
      case 0x40:
        return (_unbcd(_command[2]) * 60 + _unbcd(_command[3])) * 75 +
            _unbcd(_command[4]) -
            150;
      case 0x80:
        final track = _unbcd(_command[2]);
        return track > disc.trackCount
            ? disc.totalSectors
            : disc.startLba(math.max(1, track));
      default:
        return _command[3].shl16 | _command[4].shl8 | _command[5];
    }
  }

  void _executeCommand() {
    _remaining = 0;
    if (disc.isEmpty && _command[0] != 3) {
      _error(2, 0x0b);
      return;
    }
    switch (_command[0]) {
      case 0: // TEST UNIT READY
        _finish();
        break;
      case 3: // REQUEST SENSE
        final sense = Uint8List(18)..[0] = 0x70;
        sense[2] = _sense;
        sense[7] = 10;
        sense[12] = _senseCode;
        _sense = _senseCode = 0;
        final length = math.min(_command[4], sense.length);
        if (length == 0) {
          _finish();
        } else {
          _send(sense.sublist(0, length));
        }
        break;
      case 8: // READ(6)
        _audioPlaying = _audioPaused = false;
        _readLba = _command[1].mask5.shl16 | _command[2].shl8 | _command[3];
        _remaining = _command[4] == 0 ? 256 : _command[4];
        if (_readLba + _remaining > disc.totalSectors) {
          _error(5, 0x21);
          break;
        }
        phase = CdPhase.data;
        _request = false;
        _readClocks = _sectorClocks;
        break;
      case 0xd8:
        _audioStart = _audioLba = _position();
        _audioEnd = disc.totalSectors;
        if (_audioStart < 0 || _audioStart >= _audioEnd) {
          _error(5, 0x21);
          break;
        }
        _audioOffset = 0;
        _audioSector = Uint8List(0);
        _audioFraction = 0;
        _audioMode = 3;
        _audioPlaying = _command[1] != 0;
        _audioPaused = !_audioPlaying;
        _finish();
        break;
      case 0xd9:
        _audioEnd = _position();
        if (_audioEnd <= _audioStart || _audioEnd > disc.totalSectors) {
          _error(5, 0x21);
          break;
        }
        _audioMode = _command[1].mask2;
        _audioPlaying = _audioMode != 0;
        _audioPaused = false;
        _finish();
        break;
      case 0xda:
        if (!_audioPlaying && !_audioPaused) {
          _error(5, 0x2c);
          break;
        }
        _audioPaused = true;
        _audioPlaying = false;
        _finish();
        break;
      case 0xdd:
        var track = 1;
        while (
            track < disc.trackCount && disc.startLba(track + 1) <= _audioLba) {
          track++;
        }
        _send([
          _audioPlaying ? 0 : (_audioPaused ? 2 : 3),
          disc.isAudio(track) ? 0 : 4,
          _bcd(track),
          1,
          ..._msf(math.max(0, _audioLba - disc.startLba(track))),
          ..._msf(_audioLba + 150)
        ]);
        break;
      case 0xde:
        switch (_command[1]) {
          case 0:
            _send([1, _bcd(disc.trackCount)]);
            break;
          case 1:
            _send(_msf(disc.totalSectors + 150));
            break;
          case 2:
            final track = _command[2] == 0xaa
                ? disc.trackCount + 1
                : math.max(1, _unbcd(_command[2]));
            if (track > disc.trackCount && _command[2] != 0xaa) {
              _error(5, 0x22);
              break;
            }
            final end = track > disc.trackCount;
            _send([
              ..._msf((end ? disc.totalSectors : disc.startLba(track)) + 150),
              end || disc.isAudio(track) ? 0 : 4
            ]);
            break;
          default:
            _error(5, 0x22);
        }
        break;
      default:
        _error(5, 0x20);
    }
  }

  void exec(int clocks) {
    if (!enabled) return;
    var transferClocks = clocks;
    if (_remaining > 0 && !_request && phase == CdPhase.data) {
      _readClocks -= clocks;
      if (_readClocks <= 0) {
        transferClocks = -_readClocks;
        final sector = disc.read(_readLba + 150);
        if (sector.length != Disc.sectorSize || sector[15] != 1) {
          _error(3, 0x11);
        } else {
          _readLba++;
          _remaining--;
          _send(sector.sublist(16, 16 + 2048));
        }
      }
    }
    // DMA follows the same data handshake as CPU reads. Pace it to the
    // ADPCM RAM write interval instead of copying an entire transfer at once.
    if (_ports[11].mask2 != 0 && phase == CdPhase.data && _request && !_ack) {
      _dmaClocks += transferClocks;
      while (_dmaClocks >= 33 && phase == CdPhase.data && _request) {
        _dmaClocks -= 33;
        _writeAdpcm(_byte);
        _consume();
      }
    }
    if (phase == CdPhase.status) {
      _ports[11] &= ~3;
      _dmaClocks = 0;
    }
    _irq();
  }

  void _writeAdpcm(int value) {
    adpcmRam[_writeAddress] = value;
    _writeAddress = (_writeAddress + 1).mask16;
    if (!_adpcmControl.bit4 && _length < 0xffff) _length++;
    if (_length >= 0x8000) _ports[3] &= ~4;
  }

  void _decrementLength() {
    if (!_adpcmControl.bit4 && _length > 0) _length--;
    if (_length < 0x8000) _ports[3] |= 4;
    if (_length == 0 && !_adpcmControl.bit4) {
      _adpcmEnd = true;
      _ports[3] |= 8;
      if (_adpcmControl.bit6) _adpcmPlaying = false;
    }
    _irq();
  }

  static final _steps =
      List<int>.generate(49, (i) => (16 * math.pow(1.1, i)).floor());

  void _decodeAdpcm() {
    if (_length == 0) {
      _decrementLength();
      if (!_adpcmPlaying) return;
    }
    final packed = adpcmRam[_readAddress];
    final nibble = _nibble == 0 ? packed.shr4 : packed.mask4;
    // MSM5205 uses a 49-entry geometric step table and a 12-bit accumulator.
    final step = _steps[_stepIndex];
    final delta = step ~/ 8 +
        (nibble.bit0 ? step ~/ 4 : 0) +
        (nibble.bit1 ? step ~/ 2 : 0) +
        (nibble.bit2 ? step : 0);
    _sample = (_sample + (nibble.bit3 ? -delta : delta)).clamp(-2048, 2047);
    _stepIndex = (_stepIndex + const [-1, -1, -1, -1, 2, 4, 6, 8][nibble & 7])
        .clamp(0, 48);
    _nibble ^= 1;
    if (_nibble == 0) {
      _readAddress = (_readAddress + 1).mask16;
      _decrementLength();
    }
  }

  void _nextAudioSample() {
    if (_audioLba >= _audioEnd) {
      if (_audioMode == 1) {
        _audioLba = _audioStart;
      } else {
        _audioPlaying = false;
        _pcm.fillRange(0, 2, 0);
        if (_audioMode == 2) {
          _ports[3] |= 0x20;
          _irq();
        }
        return;
      }
    }
    if (_audioSector.isEmpty) {
      _audioSector = disc.read(_audioLba + 150);
      _audioOffset = 0;
    }
    for (var channel = 0; channel < 2; channel++) {
      final offset = _audioOffset + channel * 2;
      final unsigned = offset + 1 < _audioSector.length
          ? _audioSector[offset] | _audioSector[offset + 1].shl8
          : 0;
      _pcm[channel] = unsigned >= 0x8000 ? unsigned - 0x10000 : unsigned;
    }
    _audioOffset += 4;
    if (_audioOffset >= Disc.sectorSize) {
      _audioLba++;
      _audioSector = Uint8List(0);
    }
  }

  void mixAudio(Float32List buffer, int sampleRate) {
    if (!enabled) return;
    for (var i = 0; i < buffer.length; i += 2) {
      if (_audioPlaying) {
        _audioFraction += 44100 / sampleRate;
        while (_audioFraction >= 1) {
          _audioFraction--;
          _nextAudioSample();
        }
      }
      if (_adpcmPlaying) {
        _adpcmFraction += 32087.5 / (16 - _frequency) / sampleRate;
        while (_adpcmFraction >= 1) {
          _adpcmFraction--;
          _decodeAdpcm();
        }
      }
      if (_fade.bit3) {
        final decrement = 1 / (sampleRate * (_fade.bit2 ? 2.5 : 6));
        if (_fade.bit1) {
          _adpcmVolume = math.max(0, _adpcmVolume - decrement);
        } else {
          _cdVolume = math.max(0, _cdVolume - decrement);
        }
      }
      final adpcm =
          _adpcmPlaying ? _sample / 2048 * _adpcmVolume * 0.42735 : 0.0;
      for (var channel = 0; channel < 2; channel++) {
        final cd =
            _audioPlaying ? _pcm[channel] / 32768 * _cdVolume * 0.5 : 0.0;
        buffer[i + channel] =
            (buffer[i + channel] + cd + adpcm).clamp(-1.0, 1.0);
      }
    }
  }
}

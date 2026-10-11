import 'dart:typed_data';

import '../../../util/int.dart';
import '../mapper/mapper.dart';
import '../mapper/mirror.dart';
import 'fds_audio.dart';
import 'fds_image.dart';

/// FDS RAM adapter and byte-clocked disk drive (149 1/3 CPU clocks/byte).
class FdsMapper extends Mapper {
  final Uint8List bios;
  final ram = Uint8List(0x8000), chr = Uint8List(0x2000);
  final audio = FdsAudio();
  final List<int> sideOffsets, sideLengths;
  int? selectedSide;
  int _cycle = 0, _reload = 0, _counter = 0, _control = 0, _io = 0;
  int _head = 0, _byteDelay = 0, _insertDelay = 0, _data = 0, _writeData = 0;
  int _crc = 0, _crcBytes = 0, _external = 0x80;
  bool _timerEnabled = false, _repeat = false, _timerIrq = false;
  bool _diskIrq = false, _readyByte = false, _gapEnded = false;
  bool _scanning = false, _motor = false, _badCrc = false;

  FdsMapper(this.bios, this.sideOffsets, this.sideLengths) {
    if (bios.length != 0x2000) {
      throw ArgumentError('FDS BIOS must be 8192 bytes');
    }
    selectedSide = sideOffsets.isEmpty ? null : 0;
  }
  int get sideCount => sideOffsets.length;
  bool get _inserted => selectedSide != null && _insertDelay == 0;
  @override
  bool get hasExpansionArea => true;

  @override
  void init() {
    _cycle = _reload = _counter = _control = _io = 0;
    _head =
        _byteDelay = _insertDelay = _data = _writeData = _crc = _crcBytes = 0;
    _external = 0x80;
    _timerEnabled = _repeat = _timerIrq = _diskIrq = _readyByte = false;
    _gapEnded = _scanning = _motor = _badCrc = false;
    audio.reset();
    mirror(Mirror.vertical);
    _updateIrq();
  }

  void selectSide(int? side) {
    if (side != null && (side < 0 || side >= sideCount)) {
      throw RangeError.range(side, 0, sideCount - 1);
    }
    selectedSide = side;
    // Expose an ejected interval so running software notices a side change.
    _insertDelay = side == null ? 0 : 1789773;
    _head = 0;
    _motor = _scanning = _gapEnded = false;
    _diskIrq = _readyByte = false;
    _updateIrq();
  }

  void _updateIrq() => holdIrq(_timerIrq || _diskIrq);
  void _ackDisk() {
    _diskIrq = _readyByte = false;
    _updateIrq();
  }

  @override
  int read(int addr) {
    if (addr >= 0xe000) return bios[addr.mask13];
    if (addr >= 0x6000) return ram[addr - 0x6000];
    if (addr >= 0x4040) return _io.bit1 ? audio.read(addr) : 0xff;
    if (!_io.bit0) return 0xff;
    switch (addr) {
      case 0x4030:
        final status = (_timerIrq ? 1 : 0) |
            (_readyByte ? 2 : 0) |
            (_badCrc ? 0x10 : 0) |
            (_control & 8);
        _timerIrq = false;
        _ackDisk();
        return status;
      case 0x4031:
        _ackDisk();
        return _data;
      case 0x4032:
        return (_inserted ? 0 : 5) | (_inserted && _scanning ? 0 : 2);
      case 0x4033:
        return _external | 0x80;
    }
    return 0xff;
  }

  @override
  void write(int addr, int data) {
    data &= 0xff;
    if (addr >= 0xe000) return;
    if (addr >= 0x6000) {
      ram[addr - 0x6000] = data;
      return;
    }
    if (addr >= 0x4040) {
      if (_io.bit1) audio.write(addr, data);
      return;
    }
    switch (addr) {
      case 0x4020:
        _reload = (_reload & 0xff00) | data;
      case 0x4021:
        _reload = _reload.mask8 | data.shl8;
      case 0x4022:
        _repeat = data.bit0;
        _timerEnabled = data.bit1 && _io.bit0;
        if (_timerEnabled) {
          _counter = _reload;
        } else {
          _timerIrq = false;
        }
        _updateIrq();
      case 0x4023:
        _io = data;
        if (!_io.bit0) {
          _timerEnabled = _timerIrq = _diskIrq = _readyByte = false;
          _updateIrq();
        }
      case 0x4024:
        if (!_io.bit0) return;
        _writeData = data;
        _ackDisk();
      case 0x4025:
        if (!_io.bit0) return;
        if (!data.bit4) _crcBytes = 0;
        if (data.bit4 && !_control.bit4) {
          _crcBytes = data.bit2 ? 2 : 0;
        }
        _control = data;
        mirror(data.bit3 ? Mirror.horizontal : Mirror.vertical);
        if (!data.bit0) {
          _motor = _scanning = false;
        } else if (!_motor && _inserted) {
          _startMotor();
        }
        _ackDisk();
      case 0x4026:
        if (_io.bit0) _external = data;
    }
  }

  void _startMotor() {
    _motor = true;
    _scanning = _gapEnded = false;
    _head = 0;
    _byteDelay = 50000 * 3;
    _crc = 0;
  }

  @override
  void handleClock(int cycles) {
    final elapsed = cycles - _cycle;
    _cycle = cycles;
    if (elapsed <= 0) return;
    if (_timerEnabled) {
      if (elapsed <= _counter) {
        _counter -= elapsed;
      } else {
        _timerIrq = true;
        if (_repeat) {
          _counter = _reload - (elapsed - _counter - 1) % (_reload + 1);
        } else {
          _timerEnabled = false;
        }
        _updateIrq();
      }
    }
    if (_insertDelay > 0) {
      _insertDelay -= elapsed;
      if (_insertDelay > 0) return;
      _insertDelay = 0;
      if (_control.bit0) _startMotor();
      return;
    }
    if (!_inserted || !_motor || (_control.bit1 && !_scanning)) return;
    _byteDelay -= elapsed * 3;
    while (_byteDelay <= 0 && _motor) {
      _scanning = true;
      _transfer();
      _byteDelay += 448;
    }
  }

  void _transfer() {
    final side = selectedSide!;
    final offset = sideOffsets[side] + _head;
    final blockEnabled = _control.bit6;
    if (_control.bit2) {
      final data = readSram(offset);
      if (!blockEnabled) {
        _crc = 0;
        _gapEnded = _badCrc = false;
      } else if (!_gapEnded) {
        if (data != 0) {
          _gapEnded = true;
          _crc = FdsImage.crcByte(0, data);
        }
      } else {
        _data = data;
        _readyByte = true;
        if (!_control.bit4 || _crcBytes > 0) {
          _crc = FdsImage.crcByte(_crc, data);
          if (_crcBytes > 0 && --_crcBytes == 0) _badCrc = _crc != 0;
        }
        if (_control.bit7) _diskIrq = true;
      }
    } else {
      var data = _writeData;
      if (!blockEnabled) {
        data = 0;
        _crc = 0;
      } else if (_control.bit4) {
        data = _crc.mask8;
        _crc >>= 8;
      } else {
        _crc = FdsImage.crcByte(_crc, data);
      }
      writeSram(offset, data);
      _gapEnded = _badCrc = false;
      if (!_control.bit4) {
        _readyByte = true;
        if (_control.bit7) _diskIrq = true;
      }
    }
    _head++;
    if (_head >= sideLengths[side]) {
      _motor = _scanning = false;
      if (_control.bit7) _diskIrq = true;
    }
    _updateIrq();
  }

  @override
  int readVram(int addr) => chr[addr.mask13];
  @override
  void writeVram(int addr, int data) => chr[addr.mask13] = data.mask8;
  @override
  Float32List handleApu(int cycles) =>
      _io.bit1 ? audio.synth(cycles) : Float32List(0);
  @override
  String dump() =>
      'fds: side:${selectedSide == null ? "ejected" : selectedSide! + 1} head:$_head irq:${_timerIrq || _diskIrq} control:${_control.toRadixString(16)} crc:${_crc.toRadixString(16)} crcBytes:$_crcBytes bad:$_badCrc\n';
}

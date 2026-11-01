import '../../state.dart';

import 'fault.dart';

/// SH7750 SCI asynchronous and synchronous communication (hardware manual §15).
/// Endpoints exchange decoded frames rather than pin-level waveforms.
class DcSci {
  int _mode = 0, _baud = 255, _control = 0, _transmit = 255;
  int _status = 0x84, _receive = 0, _port = 0, _observed = 0;
  int? _shift, _preload;
  int _remaining = 0, _stopClocks = 0;
  int _transmittedMpBit = -1;
  bool _stopPrepared = false, _clockEnabled = true;
  bool rxHigh = true, clockHigh = true;
  void Function(int byte)? onTransmit;

  /// Completed data and its MP bit, or null outside multiprocessor format.
  void Function(int byte, bool? multiprocessorBit)? onTransmitFrame;

  bool get clockEnabled => _clockEnabled;
  set clockEnabled(bool value) {
    if (_clockEnabled && !value) reset(moduleStop: true);
    _clockEnabled = value;
  }

  bool get synchronous => _mode & 0x80 != 0;
  bool get multiprocessor => !synchronous && _mode & 4 != 0;
  bool get externalClock => _control & 2 != 0;
  int get bitClocks =>
      (synchronous ? 4 : 32) * (_baud + 1) * (1 << (2 * (_mode & 3)));
  int get _transferBitClocks =>
      externalClock ? (synchronous ? 1 : 16) : bitClocks;
  bool get _blocked => synchronous && _status & 0x38 != 0;
  int get _dataMask => synchronous || _mode & 0x40 == 0 ? 255 : 127;
  int get frameBits => synchronous
      ? 8
      : 1 +
          (_mode & 0x40 == 0 ? 8 : 7) +
          (multiprocessor || _mode & 0x20 != 0 ? 1 : 0) +
          (_mode & 8 == 0 ? 1 : 2);
  bool get transmitRequest =>
      _clockEnabled && _control & 0x20 != 0 && _status & 0x80 != 0;
  bool get receiveRequest => _clockEnabled && _status & 0x40 != 0;

  int get interruptEvent {
    if (!_clockEnabled) return 0;
    if (_control & 0x40 != 0) {
      if (_status & 0x38 != 0) return 0x4e0;
      if (_status & 0x40 != 0 && _port & 0x80 == 0) return 0x500;
    }
    if (_control & 0x80 != 0 && _status & 0x80 != 0) return 0x520;
    if (_control & 4 != 0 && _status & 4 != 0) return 0x540;
    return 0;
  }

  void reset({bool moduleStop = false}) {
    _mode = _control = _receive = _observed = 0;
    _baud = _transmit = 255;
    _status = 0x84;
    if (!moduleStop) _port = 0;
    _shift = _preload = null;
    _remaining = _stopClocks = 0;
    _transmittedMpBit = -1;
    _stopPrepared = false;
  }

  void saveState(StateWriter writer) {
    writer.section('dc.sh4.sci');
    writer.ints([
      _mode,
      _baud,
      _control,
      _transmit,
      _status,
      _receive,
      _port,
      _observed,
      _shift ?? -1,
      _preload ?? -1,
      _remaining,
      _stopClocks,
      _transmittedMpBit
    ]);
    for (final value in [_stopPrepared, _clockEnabled, rxHigh, clockHigh]) {
      writer.boolean(value);
    }
  }

  /// Do not start a frame, reset a stopped module or replay a transmitted byte.
  void loadState(StateReader reader) {
    reader.section('dc.sh4.sci');
    final values = reader.ints();
    final stop = reader.boolean(), clock = reader.boolean();
    final receiveHigh = reader.boolean(), serialClockHigh = reader.boolean();
    const masks = [255, 255, 255, 255, 0xfd, 255, 0x8f, 0xf8];
    if (values.length != 13) throw const StateMismatch('SH4 SCI layout');
    for (var i = 0; i < masks.length; i++) {
      if (values[i] < 0 || values[i] & ~masks[i] != 0) {
        throw const StateMismatch('SH4 SCI register');
      }
    }
    if ([8, 9].any((index) => values[index] < -1 || values[index] > 255) ||
        values[10] < 0 ||
        values[11] < 0 ||
        values[12] < -1 ||
        values[12] > 1 ||
        (values[12] != -1 && (values[0] & 0x84 != 4 || values[8] == -1))) {
      throw const StateMismatch('SH4 SCI transfer');
    }
    _mode = values[0];
    _baud = values[1];
    _control = values[2];
    _transmit = values[3];
    _status = values[4];
    _receive = values[5];
    _port = values[6];
    _observed = values[7];
    _shift = values[8] == -1 ? null : values[8];
    _preload = values[9] == -1 ? null : values[9];
    _remaining = values[10];
    _stopClocks = values[11];
    _transmittedMpBit = values[12];
    _stopPrepared = stop;
    _clockEnabled = clock;
    rxHigh = receiveHigh;
    clockHigh = serialClockHigh;
  }

  int read(int offset, int size, {bool sideEffects = true}) {
    if (size != 1) throw DcUnsupported('SCI requires byte accesses');
    return switch (offset) {
      0 => _mode,
      4 => _baud,
      8 => _control,
      12 => _transmit,
      16 => _readStatus(sideEffects),
      20 => _receive,
      28 => (_port & 0x8a) | (clockHigh ? 4 : 0) | (rxHigh ? 1 : 0),
      _ => throw DcUnsupported('unsupported SCI register: $offset'),
    };
  }

  int _readStatus(bool sideEffects) {
    if (sideEffects) _observed |= _status & 0xf8;
    return _status;
  }

  void _setStatus(int bits) {
    _status |= bits;
    _observed &= ~bits;
  }

  void write(int offset, int size, int value) {
    if (size != 1) throw DcUnsupported('SCI requires byte accesses');
    value &= 255;
    if (![0, 4, 8, 12, 16, 28].contains(offset)) {
      throw DcUnsupported('unsupported SCI write: $offset');
    }
    // SCI registers other than SCSPTR are initialized throughout module stop.
    if (!_clockEnabled && offset != 28) return;
    switch (offset) {
      case 0:
        if (_control & 0x30 != 0 && value != _mode) {
          throw DcUnsupported(
              'SCI format changes require TE and RE to be clear');
        }
        _mode = value;
      case 4:
        _baud = value;
      case 8:
        _control = value;
        if (value & 0x20 == 0) {
          _shift = _preload = null;
          _transmittedMpBit = -1;
          _setStatus(0x84);
        }
      case 12:
        _transmit = value;
      case 16:
        final cleared = _observed & ~value & 0xf8;
        _status = (_status & ~cleared & ~1) | (value & 1);
        _observed &= ~cleared;
        if (cleared & 0x80 != 0 && _control & 0x20 != 0) _status &= ~4;
        if (_control & 0x20 == 0) _setStatus(0x84);
      case 28:
        _port = value & 0x8f;
      default:
        throw DcUnsupported('unsupported SCI write: $offset');
    }
    _startIfIdle();
  }

  void _startIfIdle() {
    if (!_clockEnabled ||
        _blocked ||
        _control & 0x20 == 0 ||
        _shift != null ||
        _status & 0x80 != 0) {
      return;
    }
    _shift = _takeTransmit();
    _remaining = frameBits * _transferBitClocks;
    _stopClocks = (synchronous || _mode & 8 == 0 ? 1 : 2) * _transferBitClocks;
    _stopPrepared = false;
    _transmittedMpBit = -1;
  }

  int _takeTransmit() {
    _setStatus(0x80);
    return _transmit & _dataMask;
  }

  /// Injects a completed frame; errors retain data but do not set RDRF.
  void receiveFrame(int byte,
      {bool parityError = false,
      bool framingError = false,
      bool multiprocessorBit = false}) {
    if (!_clockEnabled || _control & 0x10 == 0 || _status & 0x38 != 0) return;
    if (multiprocessor) {
      if (multiprocessorBit) _control &= ~8;
      if (_control & 8 != 0) return;
      // SCSSR.MPB is undefined on this LSI (manual section 15.2.7).
      // Retain its deterministic reset value instead of exposing the input bit.
    }
    if (_status & 0x40 != 0) {
      _setStatus(0x20);
      return;
    }
    _receive = byte & _dataMask;
    final errors = synchronous
        ? 0
        : (parityError && !multiprocessor && _mode & 0x20 != 0 ? 8 : 0) |
            (framingError ? 0x10 : 0);
    _setStatus(errors == 0 ? 0x40 : errors);
  }

  void dmaWrite(int byte) {
    if (!_clockEnabled) return;
    _transmit = byte & 255;
    _status &= ~0x84;
    _observed &= ~0x80;
    if (_control & 0x20 == 0) _setStatus(0x84);
    _startIfIdle();
  }

  int dmaRead() {
    _status &= ~0x40;
    _observed &= ~0x40;
    return _receive;
  }

  void tickPeripheralClocks(int clocks) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    if (externalClock) return;
    _advance(clocks);
  }

  /// Advances complete SCK input cycles (16 per asynchronous bit, one per synchronous bit).
  /// Receiver endpoints still inject already decoded frames independently.
  void tickExternalClocks(int clocks) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    if (!externalClock) return;
    _advance(clocks);
  }

  void _advance(int clocks) {
    if (!_clockEnabled || _blocked) return;
    _startIfIdle();
    while (_shift != null && clocks > 0 && !_blocked) {
      // MPBT is not buffered with TDR.
      // Sample it when the MP bit begins, after the start/data bits and before the stop bit(s) (section 15.3.3).
      final sampleMp = multiprocessor && _transmittedMpBit == -1;
      final boundary = sampleMp
          ? _remaining - _stopClocks - _transferBitClocks
          : _stopPrepared
              ? _remaining
              : _remaining - _stopClocks;
      final elapsed = clocks < boundary ? clocks : boundary;
      clocks -= elapsed;
      _remaining -= elapsed;
      if (sampleMp && _remaining == _stopClocks + _transferBitClocks) {
        _transmittedMpBit = _status & 1;
      }
      if (!_stopPrepared && _remaining == _stopClocks) {
        _stopPrepared = true;
        if (_status & 0x80 == 0) {
          _preload = _takeTransmit();
        } else {
          _setStatus(4);
        }
      }
      if (_remaining == 0) {
        final completed = _shift!;
        final completedMp = _transmittedMpBit;
        _shift = _preload;
        _preload = null;
        _transmittedMpBit = -1;
        if (_shift != null) {
          _remaining = frameBits * _transferBitClocks;
          _stopPrepared = false;
        }
        onTransmit?.call(completed);
        onTransmitFrame?.call(
            completed, completedMp < 0 ? null : completedMp != 0);
        _startIfIdle();
      }
    }
  }
}

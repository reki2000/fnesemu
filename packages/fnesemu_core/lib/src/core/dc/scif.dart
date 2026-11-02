import 'dart:collection';

import '../../state.dart';

import 'fault.dart';

/// SH7750 asynchronous SCIF with completed-frame input and output endpoints.
class DcScif {
  final _transmit = Queue<int>();
  final _receive = Queue<(int, int)>();
  int _mode = 0, _baud = 255, _control = 0, _fifoControl = 0, _port = 0;
  int _status = 0x60, _observed = 0, _line = 0;
  bool _observedOverrun = false, _ctsHigh = false;
  int? _shift, _nextShift;
  int _remaining = 0, _stopClocks = 0, _idle = 0;
  bool _stopPrepared = false, _dataWritten = false;
  bool rxHigh = true, rtsInputHigh = false;
  bool clockEnabled = true;
  void Function(int byte)? onTransmit;

  int get bitClocks => 32 * (_baud + 1) * (1 << (2 * (_mode & 3)));
  int get frameBits =>
      1 +
      (_mode & 0x40 == 0 ? 8 : 7) +
      (_mode & 0x20 == 0 ? 0 : 1) +
      (_mode & 8 == 0 ? 1 : 2);
  int get _receiveTrigger => [1, 4, 8, 14][(_fifoControl >> 6) & 3];
  int get _transmitTrigger => [8, 4, 2, 1][(_fifoControl >> 4) & 3];
  bool get ctsHigh => _ctsHigh;
  set ctsHigh(bool value) {
    _ctsHigh = value;
    _startIfIdle();
  }

  bool get _rtsHigh => _fifoControl & 8 != 0
      ? (_control & 0x10 == 0 || _receive.length >= 15)
      : (_port & 0x80 != 0 ? _port & 0x40 != 0 : rtsInputHigh);
  bool get _canStart =>
      _control & 0x20 != 0 &&
      (_fifoControl & 8 == 0 || !(_fifoControl & 1 != 0 ? _rtsHigh : _ctsHigh));

  void reset() {
    _transmit.clear();
    _receive.clear();
    _mode = _control = _fifoControl = _port = _observed = _line = _idle = 0;
    _baud = 255;
    _status = 0x60;
    _shift = _nextShift = null;
    _remaining = _stopClocks = 0;
    _observedOverrun = _stopPrepared = _dataWritten = false;
  }

  void saveState(StateWriter writer) {
    writer.section('dc.sh4.scif');
    writer.bytes(_transmit.toList());
    writer.ints([
      for (final entry in _receive) ...[entry.$1, entry.$2]
    ]);
    writer.ints([
      _mode,
      _baud,
      _control,
      _fifoControl,
      _port,
      _status,
      _observed,
      _line,
      _shift ?? -1,
      _nextShift ?? -1,
      _remaining,
      _stopClocks,
      _idle
    ]);
    for (final value in [
      _observedOverrun,
      _ctsHigh,
      _stopPrepared,
      _dataWritten,
      rxHigh,
      rtsInputHigh,
      clockEnabled
    ]) {
      writer.boolean(value);
    }
  }

  /// Restore FIFO/shifter history without sampling CTS or consuming a frame.
  void loadState(StateReader reader) {
    reader.section('dc.sh4.scif');
    final transmit = reader.bytes(),
        receive = reader.ints(),
        values = reader.ints();
    final overrunObserved = reader.boolean(), cts = reader.boolean();
    final stop = reader.boolean(),
        written = reader.boolean(),
        rx = reader.boolean();
    final rts = reader.boolean(), clock = reader.boolean();
    const masks = [0x7b, 255, 0xf8, 255, 0xf3, 0xf3, 0xf3, 1];
    if (transmit.length > 16 ||
        receive.length > 32 ||
        receive.length.isOdd ||
        values.length != 13) {
      throw const StateMismatch('SH4 SCIF layout');
    }
    for (var i = 0; i < receive.length; i += 2) {
      if (receive[i] < 0 ||
          receive[i] > 255 ||
          receive[i + 1] < 0 ||
          receive[i + 1] & ~12 != 0) {
        throw const StateMismatch('SH4 SCIF receive frame');
      }
    }
    for (var i = 0; i < masks.length; i++) {
      if (values[i] < 0 || values[i] & ~masks[i] != 0) {
        throw const StateMismatch('SH4 SCIF register');
      }
    }
    if ([8, 9].any((index) => values[index] < -1 || values[index] > 255) ||
        values.skip(10).any((value) => value < 0)) {
      throw const StateMismatch('SH4 SCIF transfer');
    }
    _transmit
      ..clear()
      ..addAll(transmit);
    _receive
      ..clear()
      ..addAll([
        for (var i = 0; i < receive.length; i += 2) (receive[i], receive[i + 1])
      ]);
    _mode = values[0];
    _baud = values[1];
    _control = values[2];
    _fifoControl = values[3];
    _port = values[4];
    _status = values[5];
    _observed = values[6];
    _line = values[7];
    _shift = values[8] == -1 ? null : values[8];
    _nextShift = values[9] == -1 ? null : values[9];
    _remaining = values[10];
    _stopClocks = values[11];
    _idle = values[12];
    _observedOverrun = overrunObserved;
    _ctsHigh = cts;
    _stopPrepared = stop;
    _dataWritten = written;
    rxHigh = rx;
    rtsInputHigh = rts;
    clockEnabled = clock;
  }

  void _setStatus(int flags) {
    _observed &= ~(flags & ~_status);
    _status |= flags;
  }

  int get interruptEvent {
    final errorsEnabled = _control & 0x48 != 0;
    if (errorsEnabled && _status & 0x80 != 0) return 0x700;
    if (_control & 0x40 != 0 && _status & 3 != 0) return 0x720;
    if (errorsEnabled && (_status & 0x10 != 0 || _line != 0)) return 0x740;
    if (_control & 0x80 != 0 && _status & 0x20 != 0) return 0x760;
    return 0;
  }

  bool get transmitRequest => _status & 0x20 != 0;
  bool get receiveRequest => _status & 3 != 0;

  void dmaWrite(int byte) {
    write(0xc, 1, byte);
    _status &= ~0x40;
    if (_transmit.length > _transmitTrigger) _status &= ~0x20;
    _observed &= _status;
  }

  int dmaRead() {
    final result = read(0x14, 1);
    if (_receive.length < _receiveTrigger) _status &= ~2;
    if (_receive.isEmpty) _status &= ~1;
    _observed &= _status;
    return result;
  }

  int get _statusValue {
    var parity = 0, framing = 0;
    for (final entry in _receive) {
      if (entry.$2 & 4 != 0) parity++;
      if (entry.$2 & 8 != 0) framing++;
    }
    final head = _receive.isEmpty ? 0 : _receive.first.$2;
    return _status | head | ((parity & 15) << 12) | ((framing & 15) << 8);
  }

  int read(int offset, int size, {bool sideEffects = true}) {
    if (size == 1 && offset == 4) return _baud;
    if (size == 1 && offset == 0x14) {
      if (_receive.isEmpty) return 0;
      final result = sideEffects ? _receive.removeFirst() : _receive.first;
      if (sideEffects) _startIfIdle();
      return result.$1;
    }
    if (size != 2) {
      throw DcUnsupported('unsupported SCIF read width: $offset/$size');
    }
    switch (offset) {
      case 0:
        return _mode;
      case 8:
        return _control;
      case 0x10:
        if (sideEffects) _observed |= _status;
        return _statusValue;
      case 0x18:
        return _fifoControl;
      case 0x1c:
        return (_transmit.length << 8) | _receive.length;
      case 0x20:
        final cts = _fifoControl & 8 == 0 && _port & 0x20 != 0
            ? _port & 0x10 != 0
            : _ctsHigh;
        return (_port & 0xa2) |
            (_rtsHigh ? 0x40 : 0) |
            (cts ? 0x10 : 0) |
            (rxHigh ? 1 : 0);
      case 0x24:
        if (sideEffects && _line != 0) _observedOverrun = true;
        return _line;
      default:
        throw DcUnsupported('unsupported SCIF read: $offset');
    }
  }

  void write(int offset, int size, int value) {
    if (size == 1 && offset == 4) {
      _baud = value & 255;
      return;
    }
    if (size == 1 && offset == 0xc) {
      if (_fifoControl & 4 == 0 && _transmit.length < 16) {
        _transmit.add(value & 255);
        _dataWritten = true;
        _startIfIdle();
      }
      return;
    }
    if (size != 2) {
      throw DcUnsupported('unsupported SCIF write width: $offset/$size');
    }
    switch (offset) {
      case 0:
        _mode = value & 0x7b;
      case 8:
        if (value & 2 != 0) {
          throw DcUnsupported('SCIF external clock is unimplemented');
        }
        _control = value & 0xfa;
        if (_control & 0x20 == 0) {
          _shift = _nextShift = null;
          _remaining = 0;
          _setStatus(0x40);
        } else {
          _startIfIdle();
        }
      case 0x10:
        var clear = _observed & ~value & 0x90;
        if (_dataWritten && _control & 0x20 != 0) {
          clear |= _observed & ~value & 0x40;
        }
        if (_transmit.length > _transmitTrigger) {
          clear |= _observed & ~value & 0x20;
        }
        if (_receive.length < _receiveTrigger) clear |= _observed & ~value & 2;
        if (_receive.isEmpty) clear |= _observed & ~value & 1;
        _status &= ~clear;
        _observed &= ~clear;
      case 0x18:
        _fifoControl = value & 255;
        if (_fifoControl & 4 != 0) {
          _transmit.clear();
          _setStatus(0x20);
        }
        if (_fifoControl & 2 != 0) _receive.clear();
        _startIfIdle();
      case 0x20:
        _port = value & 0xf3;
      case 0x24:
        if (value & 1 == 0 && _observedOverrun) {
          _line = 0;
          _observedOverrun = false;
        }
      default:
        throw DcUnsupported('unsupported SCIF write: $offset');
    }
  }

  void receiveFrame(int byte,
      {bool parityError = false, bool framingError = false}) {
    if (!clockEnabled ||
        _control & 0x10 == 0 ||
        _fifoControl & 2 != 0 ||
        _status & 0x10 != 0 ||
        _line != 0) {
      return;
    }
    if (_receive.length == 16) {
      _line = 1;
      _observedOverrun = false;
      return;
    }
    final errors =
        (parityError && _mode & 0x20 != 0 ? 4 : 0) | (framingError ? 8 : 0);
    _receive.add((byte & (_mode & 0x40 == 0 ? 255 : 127), errors));
    _idle = 0;
    if (errors != 0) _setStatus(0x80);
    if (_receive.length >= _receiveTrigger) _setStatus(2);
  }

  /// Injects an already detected break, not a raw pin transition.
  void receiveBreak() {
    if (!clockEnabled ||
        _control & 0x10 == 0 ||
        _fifoControl & 2 != 0 ||
        _status & 0x10 != 0) {
      return;
    }
    receiveFrame(0, framingError: true);
    _setStatus(0x10);
  }

  int _takeTransmit() {
    final result = _transmit.removeFirst() & (_mode & 0x40 == 0 ? 255 : 127);
    if (_transmit.length <= _transmitTrigger) _setStatus(0x20);
    return result;
  }

  void _startIfIdle() {
    if (!clockEnabled ||
        _shift != null ||
        !_canStart ||
        _transmit.isEmpty ||
        _fifoControl & 4 != 0) {
      return;
    }
    _shift = _takeTransmit();
    _remaining = bitClocks * frameBits;
    _stopClocks = bitClocks * (_mode & 8 == 0 ? 1 : 2);
    _stopPrepared = false;
  }

  void tickPeripheralClocks(int clocks) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    if (!clockEnabled) return;
    _startIfIdle();
    while (clocks > 0) {
      var elapsed = clocks;
      if (_shift != null) {
        final boundary = _stopPrepared ? _remaining : _remaining - _stopClocks;
        if (boundary < elapsed) elapsed = boundary;
      }
      final timeout = bitClocks * 15;
      final waiting = _receive.isNotEmpty &&
          _receive.length < _receiveTrigger &&
          _status & 1 == 0;
      if (waiting && timeout - _idle < elapsed) elapsed = timeout - _idle;
      if (elapsed < 0) elapsed = 0;
      clocks -= elapsed;
      if (_shift != null) _remaining -= elapsed;
      if (_receive.isNotEmpty) _idle += elapsed;
      if (waiting && _idle >= timeout) _setStatus(1);
      if (_shift == null) continue;
      if (!_stopPrepared && _remaining == _stopClocks) {
        _stopPrepared = true;
        if (_canStart && _transmit.isNotEmpty) _nextShift = _takeTransmit();
        if (_nextShift == null && _transmit.isEmpty) {
          _setStatus(0x40);
          _dataWritten = false;
        }
      }
      if (_remaining == 0) {
        final sent = _shift!;
        _shift = _nextShift;
        _nextShift = null;
        if (_shift != null) {
          _remaining = bitClocks * frameBits;
          _stopClocks = bitClocks * (_mode & 8 == 0 ? 1 : 2);
          _stopPrepared = false;
        } else {
          _startIfIdle();
        }
        if (_fifoControl & 1 != 0) receiveFrame(sent);
        onTransmit?.call(sent);
      }
    }
  }
}

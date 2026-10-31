import 'dart:typed_data';

import '../../pad_source.dart';
import '../../state.dart';
import '../../util/uint8list.dart';
import 'dmac.dart';
import 'fault.dart';
import 'maple_controller.dart';
import 'memory_card.dart';

/// Functional Maple software/hardware DMA with channel-0 DDT RAM transfers.
/// Root-bus arbitration and pin timing still require hardware validation.
/// Dev.Box System Architecture §§5.1 and 8.4.1.2.
class DcMaple {
  DcMaple(this.ram,
      {required this.dma, required this.onNormal, required this.onError});
  final DcDmac dma;
  final Uint8List ram;
  final void Function(int) onNormal, onError;
  final controllers = <DcMapleController?>[
    DcMapleController(),
    null,
    null,
    null
  ];

  /// where the controllers read their held buttons and axes from, set by
  /// the core; handed to a controller whenever it exchanges, so a
  /// controller attached later reads from the same source
  PadSource source = const NoPadSource();
  int _start = 0, _trigger = 0, _enable = 0, _system = 0x3a980000;
  int _top = 0xff00000, _bottom = 0x80fffff, _selection = 1;
  int _cursor = 0, _tx = 0, _rx = 0, _rxBase = 0, _remaining = 0;
  int _resetPort = -1, _writeOffset = 0, _ddtAddress = 0;
  final _source = <int, Uint8List>{};
  bool _pendingDdt = false, _writing = false;
  bool _busy = false, _last = false, _data = false, _aborting = false;
  bool _waitingDelay = false, _armed = true;
  Uint8List? _response;
  bool get busy => _busy;
  int get clocksToEvent => _busy && _remaining > 0 ? _remaining : 0x7fffffff;
  bool get hardwareEnabled => _enable != 0 && _trigger != 0;

  void validateStateTarget() {
    if (controllers.length != 4) {
      throw const StateMismatch('Maple port layout');
    }
    for (final controller in controllers) {
      if (controller == null) continue;
      if (controller.runtimeType != DcMapleController) {
        throw const StateMismatch('unregistered Maple controller state');
      }
      controller.validateStateTarget();
    }
  }

  void saveState(StateWriter writer) {
    validateStateTarget();
    writer.section('dc.maple');
    writer.ints([
      _start,
      _trigger,
      _enable,
      _system,
      _top,
      _bottom,
      _selection,
      _cursor,
      _tx,
      _rx,
      _rxBase,
      _remaining,
      _resetPort,
      _writeOffset,
      _ddtAddress
    ]);
    for (final flag in [
      _pendingDdt,
      _writing,
      _busy,
      _last,
      _data,
      _aborting,
      _waitingDelay,
      _armed
    ]) {
      writer.boolean(flag);
    }
    writer.boolean(_response != null);
    if (_response != null) writer.bytes(_response!);
    writer.int32(_source.length);
    for (final entry in _source.entries) {
      writer.int64(entry.key);
      writer.bytes(entry.value);
    }
    for (final controller in controllers) {
      writer.boolean(controller != null);
      if (controller == null) continue;
      final port = StateWriter('dc.maple.port', 1, 0);
      controller.saveState(port);
      writer.bytes(port.take());
    }
  }

  void loadState(StateReader reader) {
    validateStateTarget();
    reader.section('dc.maple');
    final v = reader.ints();
    final f = [for (var i = 0; i < 8; i++) reader.boolean()];
    final response = reader.boolean() ? reader.bytes() : null;
    final count = reader.int32();
    if (count < 0 || count > 0x200000) {
      throw const StateMismatch('Maple source snapshot layout');
    }
    final source = <int, Uint8List>{};
    for (var i = 0; i < count; i++) {
      final address = reader.int64(), bytes = reader.bytes();
      if (address < 0x0c000000 ||
          address > 0x0fffffe0 ||
          address & 31 != 0 ||
          bytes.length != 32 ||
          source.containsKey(address)) {
        throw const StateMismatch('Maple source snapshot state');
      }
      source[address] = bytes;
    }
    final ports = <Uint8List?>[];
    for (final controller in controllers) {
      final present = reader.boolean();
      if (present != (controller != null)) {
        throw const StateMismatch('Maple controller configuration mismatch');
      }
      if (controller == null) {
        ports.add(null);
        continue;
      }
      final bytes = reader.bytes();
      final staged = DcMapleController();
      for (var slot = 0; slot < 2; slot++) {
        final child = controller.expansions[slot];
        if (child is DcMemoryCard)
          staged.expansions[slot] = DcMemoryCard(unit: child.unit);
      }
      final port = StateReader(bytes, 'dc.maple.port', 1, 0);
      staged.loadState(port);
      port.end();
      ports.add(bytes);
    }
    if (v.length != 15 ||
        [
          for (var i = 0; i < v.length; i++)
            if (i != 12) v[i]
        ].any((x) => x < 0) ||
        v[0] & ~0x1fffffe0 != 0 ||
        v[1] > 1 ||
        v[2] > 1 ||
        v[3] & ~0xffff130f != 0 ||
        (v[3] >> 8) & 3 > 1 ||
        v[3] & 15 > 10 ||
        v[4] & ~0x07f00000 != 0x08000000 ||
        v[5] & ~0x07f00000 != 0x080fffff ||
        v[6] > 1 ||
        v[7] & ~0xfffffffc != 0 ||
        v[8] & ~0xfffffffc != 0 ||
        v[9] & ~0xffffffe0 != 0 ||
        v[10] & ~0x1fffffe0 != 0 ||
        v[12] < -1 ||
        v[12] > 3 ||
        v[13] & ~0xffffffe0 != 0 ||
        (f[1] && v[13] >= (((response?.length ?? 4) + 31) & ~31)) ||
        v[14] > 0x1fffffe0 ||
        v[14] & 31 != 0 ||
        (f[0] &&
            (!f[2] ||
                v[11] != 0 ||
                f[6] ||
                v[14] < 0x0c000000 ||
                v[14] > 0x0fffffe0)) ||
        (f[0] && f[1] && v[14] != v[10] + v[13]) ||
        (f[0] && !f[1] && source.containsKey(v[14]))) {
      throw const StateMismatch('Maple DMA state');
    }
    for (var i = 0; i < ports.length; i++) {
      final bytes = ports[i];
      if (bytes == null) continue;
      final port = StateReader(bytes, 'dc.maple.port', 1, 0);
      controllers[i]!.loadState(port);
      port.end();
    }
    _start = v[0];
    _trigger = v[1];
    _enable = v[2];
    _system = v[3];
    _top = v[4];
    _bottom = v[5];
    _selection = v[6];
    _cursor = v[7];
    _tx = v[8];
    _rx = v[9];
    _rxBase = v[10];
    _remaining = v[11];
    _resetPort = v[12];
    _writeOffset = v[13];
    _ddtAddress = v[14];
    _pendingDdt = f[0];
    _writing = f[1];
    _busy = f[2];
    _last = f[3];
    _data = f[4];
    _aborting = f[5];
    _waitingDelay = f[6];
    _armed = f[7];
    _response = response;
    _source
      ..clear()
      ..addAll(source);
  }

  void verticalBlankOut() {
    if (!hardwareEnabled || _busy || (_system & 0x1000 != 0 && !_armed)) {
      return;
    }
    _begin(hardware: true);
  }

  void _begin({required bool hardware}) {
    if (!_valid(_start, 4)) {
      _fail(8);
      return;
    }
    if (hardware) _armed = false;
    dma.cancelDdt(this);
    _source.clear();
    _pendingDdt = _writing = false;
    _writeOffset = 0;
    _busy = true;
    _resetPort = -1;
    _aborting = _data = false;
    _cursor = _start;
    _remaining = hardware ? (_system & 15) * 260000 : 0;
    _waitingDelay = _remaining != 0;
    if (!_waitingDelay && !hardware) _prepare();
  }

  void verticalBlankIn() {
    if (_busy && _data && !_writing && _remaining > 0) onNormal(1 << 13);
  }

  void reset() {
    dma.cancelDdt(this);
    _source.clear();
    _pendingDdt = _writing = false;
    _writeOffset = _ddtAddress = 0;
    _start =
        _trigger = _enable = _cursor = _tx = _rx = _rxBase = _remaining = 0;
    _system = 0x3a980000;
    _top = 0xff00000;
    _bottom = 0x80fffff;
    _selection = 1;
    _busy = _last = _data = _aborting = _waitingDelay = false;
    _armed = true;
    _response = null;
    _resetPort = -1;
    for (final controller in controllers) {
      controller?.resetDevice();
    }
  }

  bool _valid(int address, int length) =>
      address >= 0x0c000000 &&
      address + length <= 0x10000000 &&
      address >= _top &&
      address + length - 1 <= _bottom;
  bool _check(int address, int length) {
    if (_valid(address, length)) return true;
    _fail(9);
    return false;
  }

  void _fail(int bit) {
    dma.cancelDdt(this);
    _pendingDdt = _writing = false;
    _source.clear();
    _busy = _waitingDelay = false;
    _remaining = 0;
    _response = null;
    _resetPort = -1;
    onError(1 << bit);
  }

  int _word(int address) {
    final block = _source[address & ~31]!;
    return block.getUint32LE(address & 31);
  }

  int _byte(int address) => _source[address & ~31]![address & 31];

  /// Invoked at the current bus time, never during credit for an earlier slice.
  void prepare() {
    if (!_busy || _remaining > 0 || _waitingDelay) return;
    if (_pendingDdt && !dma.ownsDdtRequest(this)) _pendingDdt = false;
    if (_writing) {
      _requestWrite();
    } else {
      _prepare();
    }
  }

  bool _fetch(int address, int length) {
    if (!_check(address, length)) return false;
    for (var block = address & ~31; block < address + length; block += 32) {
      if (_source.containsKey(block)) continue;
      if (!_check(block, 32)) return false;
      if (!_pendingDdt) {
        _ddtAddress = block;
        _pendingDdt =
            dma.requestDdt32(this, block, write: false, transfer: _transferDdt);
      }
      return false;
    }
    return true;
  }

  void _finishDescriptor() {
    _source.removeWhere((address, _) => address < (_cursor & ~31));
    _response = null;
    _writing = false;
    _remaining = 0;
    if (_aborting || _last) {
      _busy = false;
      if (!_aborting) onNormal(1 << 12);
    }
  }

  void _requestWrite() {
    if (_pendingDdt) return;
    final address = _rxBase + _writeOffset;
    if (!_check(address, 32)) return;
    _ddtAddress = address;
    _pendingDdt =
        dma.requestDdt32(this, address, write: true, transfer: _transferDdt);
  }

  bool _transferDdt(int actual, bool write) {
    if (!_busy || actual != _ddtAddress || !_check(actual, 32)) {
      if (_busy) _fail(9);
      return false;
    }
    if (!write) {
      _source[actual] = Uint8List.fromList(
          ram.sublist(actual & 0xffffff, (actual & 0xffffff) + 32));
      _pendingDdt = false;
      return true;
    }
    final response = _response;
    for (var i = 0; i < 32; i++) {
      final source = _writeOffset + (_selection == 0 ? i ^ 3 : i);
      ram[(actual + i) & 0xffffff] = response == null
          ? (_writeOffset == 0 && i < 4 ? 255 : 0)
          : source < response.length
              ? response[source]
              : 0;
    }
    _writeOffset += 32;
    _rx = _rxBase + _writeOffset;
    _pendingDdt = false;
    if (_writeOffset >= (((_response?.length ?? 4) + 31) & ~31)) {
      _finishDescriptor();
    }
    return true;
  }

  String? identifyDdtOwner(Object owner) =>
      identical(owner, this) ? 'maple' : null;

  DcDdtStateBinding? resolveDdtOwner(String id, int address, bool write) {
    if (id != 'maple' ||
        !_busy ||
        !_pendingDdt ||
        address != _ddtAddress ||
        write != _writing) {
      return null;
    }
    return (owner: this, transfer: _transferDdt);
  }

  int read(int offset, int size) {
    if (size != 4) throw const DcUnsupported('Maple requires longword access');
    return switch (offset) {
      4 => _start,
      0x10 => _trigger,
      0x14 => _enable,
      0x18 => _busy ? 1 : 0,
      0x80 => _system,
      0x84 => (_busy && !_waitingDelay ? 0x80000000 : 0) | 0xff,
      0xe8 => _selection,
      0xf4 => _tx & 0x1fffffe0,
      0xf8 => _rx & 0x1fffffe0,
      0xfc => _rxBase,
      _ => throw DcUnsupported('unimplemented Maple read: $offset'),
    };
  }

  void write(int offset, int size, int value) {
    if (size != 4) throw const DcUnsupported('Maple requires longword access');
    switch (offset) {
      case 4:
        _start = value & 0x1fffffe0;
        if (!_valid(_start, 4)) _fail(8);
      case 0x10:
        if (_trigger == (value & 1)) return;
        if (_enable != 0) {
          throw const DcUnsupported('Maple trigger write while enabled');
        }
        if (_trigger == 0 && value & 1 != 0) _armed = true;
        _trigger = value & 1;
      case 0x14:
        _enable = value & 1;
        if (_busy && _enable == 0) {
          _aborting = true;
          if (_waitingDelay || (_remaining == 0 && !_writing)) {
            dma.cancelDdt(this);
            _pendingDdt = false;
            _busy = _waitingDelay = false;
            _remaining = 0;
          }
        }
      case 0x18:
        if (value & 1 == 0 || _trigger != 0 || _busy) return;
        // A disabled interface cannot initiate a transfer, including BIOS teardown.
        if (_enable == 0) return;
        _begin(hardware: false);
      case 0x80:
        if (_enable != 0) {
          throw const DcUnsupported('Maple system write while enabled');
        }
        if ((value >> 8) & 3 > 1 || value & 15 > 10) {
          throw const DcUnsupported('prohibited Maple system configuration');
        }
        _system = value & 0xffff130f;
      case 0x88:
        if (value & 1 != 0 && _trigger != 0 && _system & 0x1000 != 0) {
          _armed = true;
        }
      case 0x8c:
        if (value >>> 16 == 0x6155) {
          _top = 0x08000000 | ((value >> 8) & 127) << 20;
          _bottom = 0x080fffff | (value & 127) << 20;
        }
      case 0xe8:
        if (_busy) {
          throw const DcUnsupported('Maple byte order change while busy');
        }
        _selection = value & 1;
      default:
        throw DcUnsupported('unimplemented Maple write: $offset');
    }
  }

  void _prepare() {
    if (!_fetch(_cursor, 4)) return;
    final instruction = _word(_cursor);
    if (instruction & 0x7ffcf800 != 0) {
      _fail(11);
      return;
    }
    final pattern = (instruction >> 8) & 7;
    final port = (instruction >> 16) & 3;
    if (pattern == 2 || pattern == 4) {
      throw DcUnsupported('Maple control pattern $pattern');
    }
    if (pattern != 0 && pattern != 3 && pattern != 7) {
      _fail(11);
      return;
    }
    final length = ((instruction & 255) + 1) * 4;
    if (pattern == 0) {
      if (!_fetch(_cursor + 4, length + 4)) return;
      final packet = Uint8List(length);
      for (var i = 0; i < length; i++) {
        // Device packets use logical words in SH4 little-endian byte order.
        // MMSEL=1 sends bit 31 first; the wire header ends with the command.
        packet[i] = _byte(_cursor + 8 + (_selection == 0 ? i ^ 3 : i));
      }
      // Keep the transport descriptor replayable if a device has a development stop.
      final controller = controllers[port];
      if (controller != null) controller.source = source;
      final response = controller?.exchange(packet, port);
      _rxBase = _word(_cursor + 4) & 0x1fffffe0;
      _rx = _rxBase;
      _cursor += length + 8;
      _source.removeWhere((address, _) => address < (_cursor & ~31));
      _response = response;
      final period = _system & 0x100 != 0 ? 200 : 100;
      // Functional serial budget: bytes plus parity, not START/END/pin timing.
      _remaining = (length + 1) * 8 * period +
          (response == null
              ? (_system >> 16) * 4
              : (response.length + 1) * 8 * period);
    } else {
      _cursor += 4;
      _response = null;
      if (pattern == 3) {
        _resetPort = port;
        // Fourteen SDCKB falling edges; physical setup/hold timing is unmodeled.
        _remaining = 28 * (_system & 0x100 != 0 ? 200 : 100);
      } else {
        _remaining =
            32000; // About 160 microseconds, System Architecture §5.1.6.
      }
    }
    _last = instruction & 0x80000000 != 0;
    _data = pattern == 0;
    _tx = _cursor;
  }

  void _tickDevices(int clocks) {
    if (clocks == 0) return;
    for (final controller in controllers) {
      controller?.tickMasterClocks(clocks);
    }
  }

  void tickMasterClocks(int clocks) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    if (_busy && _remaining == 0) {
      _tickDevices(clocks);
      return;
    }
    while (_busy && _remaining > 0 && clocks >= _remaining) {
      _tickDevices(_remaining);
      clocks -= _remaining;
      if (_waitingDelay) {
        _waitingDelay = false;
        _remaining = 0;
        _check(_cursor, 4);
        _tickDevices(clocks);
        return;
      }
      if (_resetPort >= 0) {
        controllers[_resetPort]?.resetDevice();
        _resetPort = -1;
      }
      if (_data) {
        _writing = true;
        _writeOffset = 0;
      } else {
        _finishDescriptor();
      }
      _remaining = 0;
      _tickDevices(clocks);
      return;
    }
    _tickDevices(clocks);
    if (_busy && _remaining > 0) _remaining -= clocks;
  }
}

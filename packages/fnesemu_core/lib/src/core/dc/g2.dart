import 'dart:typed_data';

import '../../state.dart';
import '../../util/uint8list.dart';
import 'dmac.dart';
import 'fault.dart';

/// HOLLY G2-DMA, System Architecture §2.6.6, §4.1.3 and §8.4.1.4.
/// One longword takes two nominal 25 MHz data cycles; protocol waits are pending.
class DcG2 {
  DcG2(this.dma,
      {required this.readRoot,
      required this.writeRoot,
      required this.readG2,
      required this.writeG2,
      required this.hardwareRequest,
      required this.onNormal,
      required this.onError});
  final DcDmac dma;
  final Uint8List Function(int address) readRoot;
  final void Function(int address, Uint8List bytes) writeRoot;
  final int Function(int address) readG2;
  final void Function(int address, int value) writeG2;
  final bool Function() hardwareRequest;
  final void Function(int) onNormal, onError;
  final _channels = List.generate(4, (_) => _Channel());
  int _top = 0xff00000, _bottom = 0x80fffff;
  int _dsTimeout = 0x3ff, _trTimeout = 0x3ff, _modemTimeout = 0, _modemWait = 0;
  int _nextSerial = 0, _nextRoot = 0, _epoch = 0, _serialClocks = 0;
  int _busyMask = 0, _hardwareMask = 0;
  int? _serial;
  int? get serialTicket => _serial == null ? null : _epoch;
  int get clocksToEvent => _serial == null ? 0 : _serialClocks;
  bool get needsHardwareTrigger => _hardwareMask & ~_busyMask != 0;
  bool get hasDirectRootRequest => directRootMask != 0;
  int get directRootMask {
    if (_busyMask == 0) return 0;
    var result = 0;
    for (var i = 0; i < 4; i++) {
      final c = _channels[i];
      if (c.busy &&
          (c.stage == 1 || c.stage == 4) &&
          !_ram(c.root) &&
          _canTransfer(c)) {
        result |= 1 << i;
      }
    }
    return result;
  }

  static bool _ram(int address) =>
      address >= 0x0c000000 && address < 0x10000000;
  static bool _rootRange(int address) =>
      _ram(address) || (address >= 0x04000000 && address < 0x05800000);
  static bool _deviceRange(int channel, int address) => channel == 0
      ? (address >= 0x00700000 && address < 0x00708000) ||
          (address >= 0x00800000 && address < 0x00a00000) ||
          (address >= 0x02700000 && address < 0x03000000)
      : (address >= 0x01000000 && address < 0x02000000) ||
          (address >= 0x03000000 && address < 0x04000000) ||
          (address >= 0x14000000 && address < 0x18000000);

  bool _canTransfer(_Channel c) =>
      c.started ||
      (!(c.suspend && c.program[4] & 4 != 0) &&
          (c.program[4] & 1 == 0 || c.request));
  bool _validBlock(int index) {
    final c = _channels[index];
    return _rootRange(c.root) &&
        _rootRange(c.root + 31) &&
        _deviceRange(index, c.device) &&
        _deviceRange(index, c.device + 31) &&
        (!_ram(c.root) || (c.root >= _top && c.root + 31 <= _bottom));
  }

  void reset({bool clearPins = false}) {
    for (var i = 0; i < 4; i++) {
      final c = _channels[i];
      _abort(i);
      c.regs.fillRange(0, 5, 0);
      c.program.fillRange(0, 5, 0);
      c.enable = c.suspend = false;
      c.device = c.root = c.remaining = 0;
      c.debugDevice = c.debugRoot = 0;
      if (clearPins) c.request = false;
    }
    _top = 0xff00000;
    _bottom = 0x80fffff;
    _dsTimeout = _trTimeout = 0x3ff;
    _modemTimeout = _modemWait = _nextSerial = _nextRoot = 0;
    _busyMask = _hardwareMask = 0;
  }

  void saveState(StateWriter writer) {
    writer.section('dc.g2');
    writer.ints([
      _top,
      _bottom,
      _dsTimeout,
      _trTimeout,
      _modemTimeout,
      _modemWait,
      _nextSerial,
      _nextRoot,
      _epoch,
      _serialClocks,
      _busyMask,
      _hardwareMask,
      _serial ?? -1
    ]);
    for (final c in _channels) {
      writer.ints(c.regs);
      writer.ints(c.program);
      writer.bytes(c.fifo);
      writer.ints([
        c.device,
        c.root,
        c.remaining,
        c.stage,
        c.word,
        c.debugDevice,
        c.debugRoot
      ]);
      for (final flag in [
        c.enable,
        c.busy,
        c.queued,
        c.started,
        c.suspend,
        c.request
      ]) {
        writer.boolean(flag);
      }
    }
  }

  /// Restore G2 before resolving the SH-4 DMA endpoint registry.
  void loadState(StateReader reader) {
    reader.section('dc.g2');
    final values = reader.ints();
    if (values.length != 13 ||
        values.take(12).any((v) => v < 0) ||
        values[0] & ~0x07f00000 != 0x08000000 ||
        values[1] & ~0x07f00000 != 0x080fffff ||
        values[2] > 0xfff ||
        values[3] > 0xfff ||
        (values[4] != 0 && values[4] != 255) ||
        values[5] > 0x17 ||
        values[6] > 3 ||
        values[7] > 3 ||
        values[9] > 16 ||
        values[10] > 15 ||
        values[11] > 15 ||
        values[12] < -1 ||
        values[12] > 3) {
      throw const StateMismatch('G2 controller state');
    }
    final channels = <_Channel>[];
    var busyMask = 0;
    for (var index = 0; index < 4; index++) {
      final regs = reader.ints(), program = reader.ints();
      final fifo = reader.bytes(), fields = reader.ints();
      final flags = [for (var i = 0; i < 6; i++) reader.boolean()];
      for (final registers in [regs, program]) {
        if (registers.length != 5) {
          throw const StateMismatch('G2 register layout');
        }
        for (var i = 0; i < 5; i++) {
          if (registers[i] < 0 ||
              registers[i] & ~[0x1fffffe0, 0x1fffffe0, 0x81ffffe0, 1, 7][i] !=
                  0) {
            throw const StateMismatch('G2 register state');
          }
        }
      }
      if (fifo.length != 32 ||
          fields.length != 7 ||
          fields.any((v) => v < 0) ||
          fields[0] > 0x21ffffe0 ||
          fields[0] & 31 != 0 ||
          fields[1] > 0x21ffffe0 ||
          fields[1] & 31 != 0 ||
          fields[2] > 0x2000000 ||
          fields[2] & 31 != 0 ||
          fields[3] > 4 ||
          fields[4] > 7 ||
          fields[5] > 0x22000000 ||
          fields[5] & 31 != 0 ||
          fields[6] > 0x22000000 ||
          fields[6] & 31 != 0 ||
          (flags[1] && (!flags[0] || fields[2] == 0 || fields[3] == 0)) ||
          (!flags[1] && (fields[3] != 0 || flags[2] || flags[3])) ||
          (flags[2] && (fields[3] != 1 && fields[3] != 4))) {
        throw const StateMismatch('G2 channel state');
      }
      final c = _Channel();
      c.regs.setAll(0, regs);
      c.program.setAll(0, program);
      c.fifo.setAll(0, fifo);
      c.device = fields[0];
      c.root = fields[1];
      c.remaining = fields[2];
      c.stage = fields[3];
      c.word = fields[4];
      c.debugDevice = fields[5];
      c.debugRoot = fields[6];
      c.enable = flags[0];
      c.busy = flags[1];
      c.queued = flags[2];
      c.started = flags[3];
      c.suspend = flags[4];
      c.request = flags[5];
      if (c.busy) busyMask |= 1 << index;
      channels.add(c);
    }
    final serial = values[12];
    if (busyMask != values[10] ||
        (serial >= 0 &&
            (!channels[serial].busy ||
                !channels[serial].started ||
                (channels[serial].stage != 2 && channels[serial].stage != 3) ||
                values[9] == 0))) {
      throw const StateMismatch('G2 scheduling state');
    }
    _top = values[0];
    _bottom = values[1];
    _dsTimeout = values[2];
    _trTimeout = values[3];
    _modemTimeout = values[4];
    _modemWait = values[5];
    _nextSerial = values[6];
    _nextRoot = values[7];
    _epoch = values[8];
    _serialClocks = values[9];
    _busyMask = values[10];
    _hardwareMask = values[11];
    _serial = serial < 0 ? null : serial;
    // Keep channel identities stable for destination-owned DDT callbacks.
    for (var i = 0; i < 4; i++) {
      _channels[i].copyFrom(channels[i]);
    }
  }

  String? identifyDdtOwner(Object owner) {
    for (var i = 0; i < 4; i++) {
      if (identical(owner, _channels[i])) return 'g2.$i';
    }
    return null;
  }

  DcDdtStateBinding? resolveDdtOwner(String id, int address, bool write) {
    for (var i = 0; i < 4; i++) {
      final c = _channels[i];
      if (id == 'g2.$i' &&
          c.busy &&
          c.queued &&
          _ram(c.root) &&
          (c.stage == 1 || c.stage == 4) &&
          address == c.root &&
          write == (c.stage == 4)) {
        return (owner: c, transfer: (address, write) => _ddtTransfer(i));
      }
    }
    return null;
  }

  bool _ddtTransfer(int index) {
    final c = _channels[index];
    c.queued = false;
    if (!c.busy || !_validBlock(index)) {
      _error(index, 19);
      return false;
    }
    _rootTransfer(index);
    return true;
  }

  void _abort(int index) {
    final c = _channels[index];
    dma.cancelDdt(c);
    c.busy = c.queued = c.started = false;
    _busyMask &= ~(1 << index);
    c.stage = c.word = 0;
    if (_serial == index) {
      _serial = null;
      _epoch++;
    }
  }

  void _error(int index, int base) {
    _abort(index);
    onError(1 << (base + index));
  }

  void _start(int index) {
    final c = _channels[index];
    if (!c.enable || c.busy) return;
    final trigger = c.program[4], repeat = c.program[2] & 0x80000000 == 0;
    if (trigger & 4 == 0 &&
        ((repeat && trigger & 1 != 0) || trigger & 3 == 3)) {
      throw const DcUnsupported(
          'prohibited G2 DMA trigger/restart combination');
    }
    if (!_deviceRange(index, c.program[0]) || !_rootRange(c.program[1])) {
      _error(index, 15);
      return;
    }
    c.device = c.program[0];
    c.root = c.program[1];
    c.debugDevice = c.device;
    c.debugRoot = c.root;
    c.remaining = c.program[2] & 0x1ffffe0;
    if (c.remaining == 0) c.remaining = 0x2000000;
    c.busy = true;
    _busyMask |= 1 << index;
    c.started = c.queued = false;
    c.word = 0;
    c.stage = c.program[3] == 0 ? 1 : 3;
  }

  /// Normal interrupt pulses and rising external levels initiate armed channels.
  void trigger() {
    for (var i = 0; i < 4; i++) {
      if (_channels[i].program[4] & 2 != 0) _start(i);
    }
  }

  void setTransferRequest(int index, bool asserted) {
    final c = _channels[index];
    c.request = asserted;
    if (asserted && c.program[4] & 3 == 1) _start(index);
  }

  int read(int offset, int size) {
    if (size != 4 || offset & 3 != 0) {
      throw const DcUnsupported('G2 requires aligned longword registers');
    }
    if (offset < 0x80) {
      final c = _channels[offset ~/ 0x20], register = offset & 31;
      if (register < 0x14) return c.regs[register ~/ 4];
      return switch (register) {
        0x14 => c.enable ? 1 : 0,
        0x18 => c.busy ? 1 : 0,
        0x1c => c.program[4] & 4 == 0
            ? 0
            : (c.request ? 0x20 : 0) |
                (!c.busy || (!c.started && !_canTransfer(c)) ? 0x10 : 0),
        _ => throw const DcUnsupported('unimplemented G2 DMA register'),
      };
    }
    if (offset >= 0xc0 && offset <= 0xf8 && offset & 15 <= 8) {
      final c = _channels[(offset - 0xc0) ~/ 16];
      return switch (offset & 15) {
        0 => c.debugDevice & 0x1fffffe0,
        4 => c.debugRoot & 0x1fffffe0,
        _ => (c.busy ? c.remaining : c.program[2]) & 0x1ffffe0,
      };
    }
    return switch (offset) {
      0x80 => 0x12,
      0x90 => _dsTimeout,
      0x94 => _trTimeout,
      0x98 => _modemTimeout,
      0x9c => _modemWait,
      _ => throw DcUnsupported('unimplemented/write-only G2 read: $offset'),
    };
  }

  void write(int offset, int size, int value) {
    if (size != 4 || offset & 3 != 0) {
      throw const DcUnsupported('G2 requires aligned longword registers');
    }
    if (offset < 0x80) {
      final index = offset ~/ 0x20, c = _channels[offset ~/ 0x20];
      final register = offset & 31;
      if (register < 0x14) {
        final field = register ~/ 4;
        c.regs[field] =
            value & [0x1fffffe0, 0x1fffffe0, 0x81ffffe0, 1, 7][field];
        if (!c.enable) c.program[field] = c.regs[field];
        if ((field == 0 && !_deviceRange(index, c.regs[field])) ||
            (field == 1 && !_rootRange(c.regs[field]))) {
          onError(1 << (15 + index));
        }
        return;
      }
      switch (register) {
        case 0x14:
          c.enable = value & 1 != 0;
          if (c.enable && c.program[4] & 2 != 0) {
            _hardwareMask |= 1 << index;
          } else {
            _hardwareMask &= ~(1 << index);
          }
          if (!c.enable) {
            _abort(index);
            c.program.setAll(0, c.regs);
          } else if (!_deviceRange(index, c.program[0]) ||
              !_rootRange(c.program[1])) {
            _error(index, 15);
          } else if ((c.program[4] & 2 != 0 && hardwareRequest()) ||
              (c.program[4] & 3 == 1 && c.request)) {
            _start(index);
          }
        case 0x18:
          // The retail BIOS writes zero here during initialization.
          // Treat it as inert despite the manual marking zero prohibited.
          if (value & 1 == 0) return;
          // A disabled channel cannot start a transfer, including a trailing
          // start write after an automatically initiated short DMA completes.
          if (!c.enable) return;
          if (c.program[4] & 2 == 0) _start(index);
        case 0x1c:
          c.suspend = c.program[4] & 4 != 0 && value & 1 != 0;
        default:
          throw const DcUnsupported('unimplemented G2 DMA register');
      }
      return;
    }
    switch (offset) {
      case 0xa0:
      case 0xa4:
      case 0xa8:
      case 0xac:
      case 0xb0:
      case 0xb4:
      case 0xb8:
        if (value != 0) {
          throw DcUnsupported('unimplemented G2 setup write: $offset');
        }
        return; // Retail BIOS clears these undocumented registers.
      case 0x90:
        _dsTimeout = value & 0xfff;
      case 0x94:
        _trTimeout = value & 0xfff;
      case 0x98:
        if (value & 255 != 0 && value & 255 != 255) {
          throw const DcUnsupported('prohibited G2 modem timeout');
        }
        _modemTimeout = value & 255;
      case 0x9c:
        if (value & 255 > 0x17) {
          throw const DcUnsupported('prohibited G2 modem wait');
        }
        _modemWait = value & 255;
      case 0xbc:
        if ((value >> 16) & 0xffff == 0x4659) {
          _top = 0x08000000 | (((value >> 8) & 127) << 20);
          _bottom = 0x080fffff | ((value & 127) << 20);
        }
      default:
        throw DcUnsupported('unimplemented/read-only G2 write: $offset');
    }
  }

  void prepare() {
    if (_busyMask == 0) return;
    final firstRoot = _nextRoot;
    for (var step = 0; step < 4; step++) {
      final i = (firstRoot + step) & 3, c = _channels[i];
      if (!c.busy || (c.stage != 1 && c.stage != 4)) continue;
      if (c.queued && !dma.ownsDdtRequest(c)) c.queued = false;
      if (!_canTransfer(c)) {
        if (c.queued) {
          dma.cancelDdt(c);
          c.queued = false;
        }
        continue;
      }
      if (!_validBlock(i)) {
        _error(i, 19);
        continue;
      }
      if (_ram(c.root) && !c.queued) {
        c.queued = dma.requestDdt32(c, c.root, write: c.stage == 4,
            transfer: (address, write) {
          return _ddtTransfer(i);
        });
        if (c.queued) _nextRoot = (i + 1) & 3;
      }
    }
    if (_serial != null) return;
    for (var step = 0; step < 4; step++) {
      final i = (_nextSerial + step) & 3, c = _channels[i];
      if (!c.busy || (c.stage != 2 && c.stage != 3) || !_canTransfer(c)) {
        continue;
      }
      final valid = c.stage == 2 && c.started
          ? _deviceRange(i, c.device) && _deviceRange(i, c.device + 31)
          : _validBlock(i);
      if (!valid) {
        _error(i, 19);
        continue;
      }
      c.started = true;
      _serial = i;
      _serialClocks = 16;
      _epoch++;
      break;
    }
  }

  void _rootTransfer(int index) {
    final c = _channels[index];
    if (c.stage == 1) {
      c.fifo.setAll(0, readRoot(c.root));
      c.debugRoot = c.root + 32;
      c.stage = 2;
      c.started = true;
    } else {
      writeRoot(c.root, c.fifo);
      c.debugRoot = c.root + 32;
      _commit(index);
    }
  }

  /// Eligibility is sampled before other devices advance, avoiding retroactive grants.
  void tickRootUnits(int units, {int eligibleMask = 15}) {
    if (units == 0 || _busyMask == 0) return;
    for (var step = 0; step < 4; step++) {
      final i = (_nextRoot + step) & 3, c = _channels[i];
      if (eligibleMask & (1 << i) == 0 ||
          !c.busy ||
          _ram(c.root) ||
          (c.stage != 1 && c.stage != 4) ||
          !_canTransfer(c)) {
        continue;
      }
      if (!_validBlock(i)) {
        _error(i, 19);
        return;
      }
      _rootTransfer(i);
      _nextRoot = (i + 1) & 3;
      return;
    }
  }

  /// Only the timer present at the beginning of this bus slice consumes clocks.
  void tickMasterClocks(int clocks, int? ticket) {
    if (ticket == null || ticket != serialTicket) return;
    if (clocks > _serialClocks) {
      throw const DcUnsupported('G2 scheduler crossed a data deadline');
    }
    _serialClocks -= clocks;
    if (_serialClocks != 0) return;
    _serialClocks = 16;
    final index = _serial!,
        c = _channels[index],
        address = c.device + c.word * 4;
    if (c.stage == 2) {
      writeG2(address, c.fifo.getUint32LE(c.word * 4));
    } else {
      c.fifo.setUint32LE(c.word * 4, readG2(address));
    }
    c.word++;
    if (c.word < 8) {
      _serialClocks = 16;
      return;
    }
    c.word = 0;
    c.debugDevice = c.device + 32;
    _serial = null;
    _epoch++;
    _nextSerial = (index + 1) & 3;
    if (c.stage == 2) {
      _commit(index);
    } else {
      c.stage = 4;
    }
  }

  void _commit(int index) {
    final c = _channels[index];
    c.device += 32;
    c.root += 32;
    c.remaining -= 32;
    c.started = false;
    if (c.remaining != 0) {
      c.stage = c.program[3] == 0 ? 1 : 3;
      return;
    }
    c.busy = false;
    _busyMask &= ~(1 << index);
    c.stage = 0;
    if (c.program[2] & 0x80000000 != 0) {
      c.enable = false;
      _hardwareMask &= ~(1 << index);
      c.program.setAll(0, c.regs);
    }
    onNormal(1 << (15 + index));
  }
}

class _Channel {
  void copyFrom(_Channel c) {
    regs.setAll(0, c.regs);
    program.setAll(0, c.program);
    fifo.setAll(0, c.fifo);
    device = c.device;
    root = c.root;
    remaining = c.remaining;
    stage = c.stage;
    word = c.word;
    debugDevice = c.debugDevice;
    debugRoot = c.debugRoot;
    enable = c.enable;
    busy = c.busy;
    queued = c.queued;
    started = c.started;
    suspend = c.suspend;
    request = c.request;
  }

  final regs = Uint32List(5), program = Uint32List(5), fifo = Uint8List(32);
  int device = 0, root = 0, remaining = 0, stage = 0, word = 0;
  int debugDevice = 0, debugRoot = 0;
  bool enable = false, busy = false, queued = false, started = false;
  bool suspend = false, request = false;
}

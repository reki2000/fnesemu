import 'dart:typed_data';

import '../../state.dart';
import 'dmac.dart';
import 'fault.dart';
import 'optical_drive.dart';

/// HOLLY G1 control and drive DMA, System Architecture §8.4.1.3.
/// A 32-byte FIFO separates device serial transfers from root-bus commits.
class DcG1 {
  DcG1(this.device, this.dma,
      {required this.writeRoot,
      required this.onNormal,
      required this.onError,
      this.systemMode = 1});
  final DcOpticalDrive device;
  final DcDmac dma;
  final void Function(int address, Uint8List bytes) writeRoot;
  final void Function(int) onNormal, onError;
  final int systemMode;
  final _fifo = Uint8List(32);
  final _timing = Uint32List.fromList(
      [0x1ff7, 0x1ff7, 0x1ff7, 0x1ff7, 0xff7, 0xff7, 0xffff, 0xffff]);
  int _start = 0, _length = 0, _direction = 0, _enable = 0, _readyControl = 1;
  int _top = 0xff00000, _bottom = 0x80fffff;
  int _address = 0, _debugAddress = 0, _transferred = 0, _target = 0;
  int _filled = 0, _wanted = 0, _remaining = 0, _fetching = 0;
  int? _epoch;
  int? _biosVerificationRequest;

  /// Diagnostic bring-up only; this does not implement the HOLLY checksum.
  bool bypassBiosVerification = false;
  int? get biosVerificationRequest => _biosVerificationRequest;
  bool _busy = false, _rootReady = false, _pendingDdt = false;
  bool get busy => _busy;
  bool get hasDirectRootRequest => _rootReady;
  bool get pioReadyEnabled => _readyControl != 0;
  int get clocksToEvent => _remaining;

  void saveState(StateWriter writer) {
    writer.section('dc.g1');
    writer.int64(systemMode);
    writer.bytes(_fifo);
    writer.ints(_timing);
    writer.ints([
      _start,
      _length,
      _direction,
      _enable,
      _readyControl,
      _top,
      _bottom,
      _address,
      _debugAddress,
      _transferred,
      _target,
      _filled,
      _wanted,
      _remaining,
      _fetching,
      _epoch ?? -1,
      _biosVerificationRequest ?? -1
    ]);
    writer.boolean(_busy);
    writer.boolean(_rootReady);
    writer.boolean(_pendingDdt);
  }

  /// Restore the optical drive stream separately before scheduling this controller.
  void loadState(StateReader reader) {
    reader.section('dc.g1');
    final mode = reader.int64();
    final fifo = reader.bytes(), timing = reader.ints(), v = reader.ints();
    final busy = reader.boolean(), rootReady = reader.boolean();
    final pending = reader.boolean();
    if (mode != systemMode ||
        fifo.length != 32 ||
        timing.length != 8 ||
        v.length != 17) {
      throw const StateMismatch('G1 layout or board configuration');
    }
    for (var i = 0; i < 8; i++) {
      final mask = i < 4
          ? 0x1ff7
          : i < 6
              ? 0xff7
              : 0xffff;
      if (timing[i] < 0 || timing[i] & ~mask != 0) {
        throw const StateMismatch('G1 timing state');
      }
    }
    if (v.take(15).any((value) => value < 0) ||
        v[0] & ~0x1fffffe0 != 0 ||
        v[1] > 0x1ffffff ||
        v[2] > 1 ||
        v[3] > 1 ||
        v[4] > 1 ||
        v[5] & ~0x07f00000 != 0x08000000 ||
        v[6] & ~0x07f00000 != 0x080fffff ||
        v[7] > 0x20000000 ||
        v[7] & 31 != 0 ||
        v[8] > 0x20000000 ||
        v[8] & 31 != 0 ||
        v[9] > 0x2000000 ||
        v[9] & 31 != 0 ||
        v[10] > 0x2000000 ||
        v[11] > 32 ||
        v[12] > 32 ||
        v[11] > v[12] ||
        v[13] > 2240 ||
        v[14] > v[12] - v[11] ||
        v[15] < -1 ||
        v[16] < -1 ||
        v[16] > 0xffffffff ||
        (busy && (v[3] == 0 || v[10] == 0 || v[12] == 0 || v[9] >= v[10])) ||
        ((rootReady || pending) && (!busy || v[11] != v[12] || v[15] < 0)) ||
        (rootReady && (pending || _ram(v[7]))) ||
        (pending && !_ram(v[7])) ||
        (v[13] != 0 && (!busy || v[14] == 0 || v[15] < 0))) {
      throw const StateMismatch('G1 transfer state');
    }
    _fifo.setAll(0, fifo);
    _timing.setAll(0, timing);
    _start = v[0];
    _length = v[1];
    _direction = v[2];
    _enable = v[3];
    _readyControl = v[4];
    _top = v[5];
    _bottom = v[6];
    _address = v[7];
    _debugAddress = v[8];
    _transferred = v[9];
    _target = v[10];
    _filled = v[11];
    _wanted = v[12];
    _remaining = v[13];
    _fetching = v[14];
    _epoch = v[15] < 0 ? null : v[15];
    _biosVerificationRequest = v[16] < 0 ? null : v[16];
    _busy = busy;
    _rootReady = rootReady;
    _pendingDdt = pending;
  }

  String? identifyDdtOwner(Object owner) =>
      identical(owner, this) ? 'g1' : null;

  DcDdtStateBinding? resolveDdtOwner(String id, int address, bool write) {
    if (id != 'g1' || !_busy || !_pendingDdt || address != _address || !write) {
      return null;
    }
    return (owner: this, transfer: _ddtTransfer);
  }

  bool _ddtTransfer(int address, bool write) {
    if (!_busy || _epoch != device.dmaEpoch) {
      _abort();
      return false;
    }
    if (!_valid(address, 32)) {
      _fail(13);
      return false;
    }
    writeRoot(address, _fifo);
    _pendingDdt = false;
    _commit();
    return true;
  }

  void reset() {
    _biosVerificationRequest = null;
    _abort();
    _start = _length = _direction = _enable = 0;
    _readyControl = 1;
    _top = 0xff00000;
    _bottom = 0x80fffff;
    _address = _debugAddress = _transferred = 0;
    _timing.setAll(
        0, [0x1ff7, 0x1ff7, 0x1ff7, 0x1ff7, 0xff7, 0xff7, 0xffff, 0xffff]);
  }

  void _abort() {
    dma.cancelDdt(this);
    _busy = _rootReady = _pendingDdt = false;
    _filled = _wanted = _remaining = _fetching = 0;
    _epoch = null;
  }

  void _fail(int bit) {
    _abort();
    onError(1 << bit);
  }

  static bool _ram(int address) =>
      address >= 0x0c000000 && address < 0x10000000;
  bool _valid(int address, int size) {
    if (size < 1 || address & 31 != 0) return false;
    if (_ram(address)) {
      // The drive register tables explicitly exclude the 0D/0F RAM banks.
      final bank = address >> 24;
      return (bank == 12 || bank == 14) &&
          address + size <= (bank + 1) << 24 &&
          address >= _top &&
          address + size - 1 <= _bottom;
    }
    for (final (first, end) in const [
      (0x00700000, 0x00708000),
      (0x00800000, 0x00a00000),
      (0x01000000, 0x02000000),
      (0x02700000, 0x04000000),
      (0x04000000, 0x04800000),
      (0x05000000, 0x05800000),
      (0x06000000, 0x06800000),
      (0x07000000, 0x07800000),
      (0x14000000, 0x18000000),
    ]) {
      if (address >= first && address + size <= end) return true;
    }
    return false;
  }

  void observeRootAccess(int address) {
    final physical = address & 0x1fffffff;
    if (physical >= 0x005f7000 && physical < 0x005f70a0) {
      _requireBiosVerification();
    }
    if (!_busy) return;
    if (physical < 0x220000 ||
        (physical >= 0x005f7000 && physical < 0x005f70a0)) {
      onError(1 << 14);
      throw const DcUnsupported('root-bus G1 access during drive DMA');
    }
  }

  // Keep the unknown verification result separate from accepting its request.
  // Conservatively stop before optical drive traffic instead of assuming authentication.
  void _requireBiosVerification() {
    if (_biosVerificationRequest != null && !bypassBiosVerification) {
      throw const DcUnsupported(
          'HOLLY BIOS verification result is unimplemented');
    }
  }

  int read(int offset, int size) {
    if (size != 4) {
      throw const DcUnsupported('G1 registers require longword access');
    }
    return switch (offset) {
      4 => _start,
      8 => _length,
      12 => _direction,
      0x14 => _enable,
      0x18 => _busy ? 1 : 0,
      0xb0 => systemMode & 255,
      0xec => bypassBiosVerification && _biosVerificationRequest != null
          ? 3
          : throw const DcUnsupported(
              'HOLLY BIOS verification status is unimplemented'),
      0xf4 => _debugAddress & 0x1fffffe0,
      0xf8 => _transferred & 0x01ffffe0,
      _ => throw DcUnsupported('unimplemented/write-only G1 read: $offset'),
    };
  }

  void write(int offset, int size, int value) {
    final lowWordConfiguration = size == 2 &&
        const [0x80, 0x84, 0x88, 0x8c, 0x90, 0x94, 0xa0, 0xa4, 0xb4]
            .contains(offset);
    if (size != 4 && !lowWordConfiguration) {
      throw const DcUnsupported('G1 registers require longword access');
    }
    switch (offset) {
      case 4:
        _start = value & 0x1fffffe0;
        if (!_valid(_start, 32)) _fail(12);
      case 8:
        _length = value & 0x01ffffff;
      case 12:
        _direction = value & 1;
      case 0x14:
        _enable = value & 1;
        if (_enable == 0) _abort();
      case 0x18:
        if (value & 1 == 0 || _busy) return;
        _requireBiosVerification();
        if (_enable == 0) {
          throw const DcUnsupported('Drive DMA start while disabled');
        }
        if (!_valid(_start, 32)) {
          _fail(12);
          return;
        }
        if (_direction == 0) {
          throw const DcUnsupported('Drive DMA writes to device');
        }
        _busy = true;
        _address = _debugAddress = _start;
        _transferred = _filled = _remaining = _fetching = 0;
        _target = _length == 0 ? 0x2000000 : _length;
        _wanted = _target < 32 ? _target : 32;
        _epoch = null;
      case 0x80:
      case 0x84:
      case 0x88:
      case 0x8c:
        _timing[(offset - 0x80) >> 2] = value & 0x1ff7;
      case 0x90:
      case 0x94:
        _timing[4 + ((offset - 0x90) >> 2)] = value & 0xff7;
      case 0xa0:
      case 0xa4:
        _timing[6 + ((offset - 0xa0) >> 2)] = value & 0xffff;
      case 0xb4:
        _readyControl = value & 1;
      case 0xb8:
        if (value >>> 16 == 0x8843) {
          _top = 0x08000000 | ((value >> 8) & 127) << 20;
          _bottom = 0x080fffff | (value & 127) << 20;
        }
      case 0xe4:
        if (_busy) {
          throw const DcUnsupported(
              'HOLLY BIOS verification requested during drive DMA');
        }
        _biosVerificationRequest = value & 0xffffffff;
      default:
        throw DcUnsupported('unimplemented/read-only G1 write: $offset');
    }
  }

  /// Called at the current time before choosing the next device deadline.
  void prepare() {
    if (!_busy) return;
    if (_epoch == null && device.dmaActive) _epoch = device.dmaEpoch;
    if (_epoch != null && _epoch != device.dmaEpoch) {
      _abort();
      return;
    }
    if (_pendingDdt && !dma.ownsDdtRequest(this)) _pendingDdt = false;
    if (_filled == _wanted && !_valid(_address, 32)) {
      _fail(13);
      return;
    }
    if (_filled == _wanted && !_pendingDdt && !_rootReady) {
      if (!_valid(_address, 32)) {
        _fail(13);
        return;
      }
      _fifo.fillRange(
          _wanted, 32, 0); // Undefined final padding is deterministic.
      _debugAddress = _address;
      if (_ram(_address)) {
        _pendingDdt = dma.requestDdt32(this, _address,
            write: true, transfer: _ddtTransfer);
      } else {
        _rootReady = true;
      }
      return;
    }
    if (_remaining == 0 && _filled < _wanted && device.dmaAvailable > 0) {
      final available = device.dmaAvailable;
      _fetching = available < _wanted - _filled ? available : _wanted - _filled;
      final timing = _timing[6];
      final a = ((timing >> 12) & 15) + 3;
      final b = ((timing >> 8) & 15) + 3;
      final c = ((timing >> 4) & 15) + 1;
      final d = (timing & 15) + 1;
      _remaining = ((b + c) + (a + d) * ((_fetching + 1) ~/ 2) - a) * 4;
    }
  }

  void tickMasterClocks(int clocks) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    if (!_busy || _remaining == 0) return;
    if (clocks > _remaining) {
      throw StateError('G1 deadline was crossed without scheduling');
    }
    _remaining -= clocks;
    if (_remaining != 0) return;
    if (_epoch != device.dmaEpoch) {
      _abort();
      return;
    }
    final bytes = device.takeDmaBytes(_fetching);
    if (bytes == null) {
      if (_epoch != device.dmaEpoch) _abort();
      return;
    }
    _fifo.setRange(_filled, _filled + bytes.length, bytes);
    _filled += bytes.length;
    _fetching = 0;
    prepare();
  }

  /// VRAM/G2 commits are root-bus units; RAM commits use DMAC arbitration.
  void tickRootUnits(int units) {
    if (units < 0) throw ArgumentError.value(units, 'units');
    if (!_busy || !_rootReady || units == 0) return;
    if (_epoch != device.dmaEpoch) {
      _abort();
      return;
    }
    if (!_valid(_address, 32)) {
      _fail(13);
      return;
    }
    writeRoot(_address, _fifo);
    _rootReady = false;
    _commit();
  }

  void _commit() {
    _debugAddress = _address;
    _address += 32;
    _transferred += 32;
    _filled = 0;
    if (_transferred >= _target) {
      _busy = false;
      onNormal(1 << 14);
      return;
    }
    _wanted = _target - _transferred < 32 ? _target - _transferred : 32;
  }
}

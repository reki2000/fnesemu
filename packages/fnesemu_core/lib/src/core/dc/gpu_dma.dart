import 'dart:typed_data';

import '../../state.dart';
import 'dmac.dart';
import 'fault.dart';

/// GPU interface DMA, System Architecture sections 2.6.9 and 8.4.1.5.
/// Transfers use channel-0 DDT arbitration; physical GPU bus latency is pending.
class DcGpuDma {
  DcGpuDma({required this.onNormal, required this.onError});
  final void Function(int) onNormal, onError;
  final _registers = Uint32List(8);
  DcDmac? _dma;
  bool Function(int target, int root, bool toRoot)? _transfer;
  int _target = 0, _root = 0, _remaining = 0, _direction = 0;
  bool _pending = false;
  (int, bool)? _restoredBinding;
  bool get busy => _registers[6] != 0;
  bool get needsHardwareTrigger =>
      !busy && _registers[5] != 0 && _registers[4] != 0;

  void bind(
      DcDmac dma, bool Function(int target, int root, bool toRoot) transfer) {
    _dma = dma;
    _transfer = transfer;
  }

  List<int> saveRegisters() =>
      [..._registers, _target, _root, _remaining, _direction, _pending ? 1 : 0];

  void loadRegisters(List<int> values) {
    if ((values.length != 8 && values.length != 13) ||
        values.any((v) => v < 0 || v > 0xffffffff)) {
      throw const StateMismatch('GPU DMA register state');
    }
    _registers.setAll(0, values.take(8));
    if (values.length == 8) {
      // Earlier bring-up states retained raw, inactive register writes only.
      if (_registers[6] != 0) {
        throw const StateMismatch('legacy active GPU DMA');
      }
      _registers[0] &= 0x0fffffe0;
      _registers[1] &= 0x0fffffe0;
      _registers[2] &= 0x00ffffe0;
      for (var i = 3; i < 6; i++) {
        _registers[i] &= 1;
      }
      _registers[7] =
          _registers[7] >> 16 == 0x6702 ? _registers[7] & 0x7f7f : 0x7f00;
      _target = _root = _remaining = _direction = 0;
      _pending = false;
      return;
    }
    if (_registers[0] & ~0x0fffffe0 != 0 ||
        _registers[1] & ~0x0fffffe0 != 0 ||
        _registers[2] & ~0x00ffffe0 != 0 ||
        _registers[3] > 1 ||
        _registers[4] > 1 ||
        _registers[5] > 1 ||
        _registers[7] & ~0x7f7f != 0 ||
        values[8] > 0x10000000 ||
        values[9] > 0x10000000 ||
        values[8] & 31 != 0 ||
        values[9] & 31 != 0 ||
        values[10] > 0x1000000 ||
        values[10] & 31 != 0 ||
        values[11] > 1 ||
        values[12] > 1 ||
        _registers[6] > 1 ||
        (busy && (values[10] == 0 || _registers[5] == 0)) ||
        (!busy && values[12] != 0)) {
      throw const StateMismatch('GPU DMA transfer state');
    }
    _target = values[8];
    _root = values[9];
    _remaining = values[10];
    _direction = values[11];
    _pending = values[12] != 0;
  }

  void reset() {
    _dma?.cancelDdt(this);
    // Address and length registers are not initialized by hardware reset.
    _registers.fillRange(3, 8, 0);
    _registers[7] = 0x7f00;
    _target = _root = _remaining = _direction = 0;
    _pending = false;
    _restoredBinding = null;
  }

  static bool _gpuAddress(int address) {
    address &= 0x1dffffff;
    return (address >= 0x005f8000 && address <= 0x005f9fe0) ||
        (address >= 0x04000000 && address <= 0x047fffe0) ||
        (address >= 0x05000000 && address <= 0x057fffe0);
  }

  static bool _rootAddress(int address) =>
      address >= 0x0c000000 && address <= 0x0fffffe0;
  bool _protected(int address, int bytes) =>
      address >= (0x08000000 | ((_registers[7] >> 8) & 127) << 20) &&
      address + bytes - 1 <= (0x080fffff | (_registers[7] & 127) << 20);

  int read(int offset) => switch (offset) {
        >= 0 && <= 0x18 when offset & 3 == 0 => _registers[offset ~/ 4],
        0xf0 => _target,
        0xf4 => _root,
        0xf8 => _remaining,
        _ => throw const DcUnsupported('GPU DMA read-only/register address'),
      };

  void write(int offset, int value) {
    if (offset == 0x80) {
      if (value >> 16 == 0x6702) _registers[7] = value & 0x7f7f;
      return;
    }
    if (offset < 0 || offset > 0x18 || offset & 3 != 0) {
      throw const DcUnsupported('GPU DMA register address');
    }
    final index = offset ~/ 4;
    if (index == 6) {
      if (value & 1 != 0 && _registers[4] == 0) _start();
      return;
    }
    _registers[index] = value &
        switch (index) {
          0 => 0x0fffffe0,
          1 => 0x0fffffe0,
          2 => 0x00ffffe0,
          _ => 1,
        };
    if ((index == 0 && !_gpuAddress(_registers[0])) ||
        (index == 1 && !_rootAddress(_registers[1]))) {
      onError(1 << 6);
    }
    if (index == 5 && _registers[5] == 0) _abort();
  }

  void trigger() {
    if (_registers[4] != 0) _start();
  }

  void _start() {
    if (busy || _registers[5] == 0) return;
    if (!_gpuAddress(_registers[0]) || !_rootAddress(_registers[1])) {
      onError(1 << 6);
      return;
    }
    final length = _registers[2] == 0 ? 0x1000000 : _registers[2];
    if (!_protected(_registers[1], length)) {
      onError(1 << 7);
      return;
    }
    _target = _registers[0];
    _root = _registers[1];
    _remaining = length;
    _direction = _registers[3];
    _registers[6] = 1;
  }

  void _abort() {
    _dma?.cancelDdt(this);
    _pending = false;
    _registers[6] = 0;
  }

  void prepare() {
    final dma = _dma;
    if (!busy || dma == null) return;
    if (_pending && !dma.ownsDdtRequest(this)) _pending = false;
    if (_pending) return;
    if (!_gpuAddress(_target) || !_rootAddress(_root)) {
      _abort();
      onError(1 << 6);
    } else if (!_protected(_root, 32)) {
      _abort();
      onError(1 << 7);
    } else {
      _pending = dma.requestDdt32(this, _root,
          write: _direction != 0, transfer: _burst);
    }
  }

  bool _burst(int address, bool write) {
    if (!busy || address != _root || write != (_direction != 0)) return false;
    if (!(_transfer?.call(_target, _root, write) ?? false)) return false;
    _pending = false;
    _target += 32;
    _root += 32;
    _remaining -= 32;
    if (_remaining == 0) {
      _registers[6] = 0;
      onNormal(1 << 11);
    }
    return true;
  }

  String? identifyDdtOwner(Object owner) =>
      identical(owner, this) ? 'gpu' : null;

  // HOLLY registers restore after DMAC; validate the binding once both exist.
  DcDdtStateBinding? resolveDdtOwner(String id, int address, bool write) {
    if (id != 'gpu') return null;
    _restoredBinding = (address, write);
    return (owner: this, transfer: _burst);
  }

  void validateDdtBinding() {
    if (_pending != (_dma?.ownsDdtRequest(this) ?? false) ||
        (_pending &&
            (_dma!.read(_direction == 0 ? 0 : 4, sideEffects: false) != _root ||
                _restoredBinding != (_root, _direction != 0)))) {
      throw const StateMismatch('GPU DMA DDT binding');
    }
    _restoredBinding = null;
  }
}

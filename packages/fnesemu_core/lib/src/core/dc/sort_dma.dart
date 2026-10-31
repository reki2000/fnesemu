import 'dart:typed_data';

import '../../state.dart';
import 'dmac.dart';
import 'fault.dart';

/// Linked TA parameter transfer, System Architecture sections 2.6.5.3 and 8.4.1.1.
/// Start links are fetched with aligned DDT bursts; table-prefetch timing is pending.
class DcSortDma {
  DcSortDma({required this.onNormal, required this.onError});
  final void Function(int) onNormal, onError;
  int _table = 0x08000000, _base = 0x08000000, _width = 0, _shift = 0;
  int _divisions = 0, _current = 0, _sent = 0, _length = 0, _next = 0;
  bool _busy = false, _tablePhase = true, _pending = false, _stop = false;
  DcDmac? _dma;
  Uint8List Function(int)? _read;
  void Function(Uint8List)? _write;
  (int, bool)? _restoredBinding;
  bool get busy => _busy;
  int get _requestAddress => _tablePhase ? _table & ~31 : _current;

  void bind(DcDmac dma, Uint8List Function(int) read,
      void Function(Uint8List) write) {
    _dma = dma;
    _read = read;
    _write = write;
  }

  List<int> saveRegisters() => [
        _table,
        _base,
        _width,
        _shift,
        _busy ? 1 : 0,
        _divisions,
        _current,
        _sent,
        _length,
        _next,
        _tablePhase ? 1 : 0,
        _pending ? 1 : 0,
        _stop ? 1 : 0
      ];

  void loadRegisters(List<int> v) {
    if (v.length != 13 ||
        v.any((x) => x < 0 || x > 0xffffffff) ||
        v[0] < 0x08000000 ||
        v[0] > 0x10000000 ||
        v[0] & 1 != 0 ||
        (v[4] != 0 && v[0] & (v[2] == 0 ? 1 : 3) != 0) ||
        v[1] & ~0x0fffffe0 != 0 ||
        v[1] < 0x08000000 ||
        [2, 3, 4, 10, 11, 12].any((i) => v[i] > 1) ||
        v[6] & 31 != 0 ||
        v[7] > 8192 ||
        v[7] & 31 != 0 ||
        (v[8] != 0 && (v[8] < 128 || v[8] > 8192 || v[8] & 31 != 0)) ||
        (v[8] != 0 && v[7] > v[8]) ||
        (v[4] == 0 && (v[11] != 0 || v[12] != 0))) {
      throw const StateMismatch('Sort-DMA transfer state');
    }
    _table = v[0];
    _base = v[1];
    _width = v[2];
    _shift = v[3];
    _busy = v[4] != 0;
    _divisions = v[5];
    _current = v[6];
    _sent = v[7];
    _length = v[8];
    _next = v[9];
    _tablePhase = v[10] != 0;
    _pending = v[11] != 0;
    _stop = v[12] != 0;
  }

  void reset() {
    _dma?.cancelDdt(this);
    _busy = _pending = _stop = false;
    _tablePhase = true;
    _divisions = _current = _sent = _length = _next = 0;
    _restoredBinding = null;
  }

  int read(int offset) => switch (offset) {
        0x10 => _table,
        0x14 => _base,
        0x18 => _width,
        0x1c => _shift,
        0x20 => _busy ? 1 : 0,
        0x60 => _divisions,
        _ => throw const DcUnsupported('Sort-DMA register read'),
      };

  void write(int offset, int value) {
    if (offset == 0x20) {
      if (value & 1 == 0) {
        if (_busy) _stop = true;
      } else if (!_busy) {
        if (_table & (_width == 0 ? 1 : 3) != 0) {
          throw const DcUnsupported('Sort-DMA unaligned start link table');
        }
        _busy = true;
        _tablePhase = true;
        _pending = _stop = false;
        _divisions = _sent = _length = _next = 0;
      }
      return;
    }
    if (_busy) throw const DcUnsupported('Sort-DMA setup changed while active');
    switch (offset) {
      case 0x10:
        _table = 0x08000000 | (value & 0x07ffffe0);
      case 0x14:
        _base = 0x08000000 | (value & 0x07ffffe0);
      case 0x18:
        _width = value & 1;
      case 0x1c:
        _shift = value & 1;
      default:
        throw const DcUnsupported('Sort-DMA register write');
    }
  }

  void _finish({bool normal = false, bool error = false}) {
    _dma?.cancelDdt(this);
    _busy = _pending = _stop = false;
    if (normal) onNormal(1 << 20);
    // The interrupt table places this in ISTERR; section 2.6.5 has an ISTNRM typo.
    if (error) onError(1 << 28);
  }

  int _linkOffset(int link) {
    if (link == 1 || link == 2) return 0;
    final offset = link * (_shift == 0 ? 1 : 32);
    if (offset > 0x07ffffe0 ||
        offset & 31 != 0 ||
        (offset != 0 && offset < 128)) {
      throw const DcUnsupported('Sort-DMA prohibited link value');
    }
    return offset;
  }

  void _follow(int link) {
    if (link == 1) {
      _tablePhase = true;
      return;
    }
    if (link == 2) {
      _finish(normal: true);
      return;
    }
    final offset = _linkOffset(link);
    _current = _base + offset;
    _sent = _length = _next = 0;
    _tablePhase = false;
  }

  void prepare() {
    final dma = _dma;
    if (!_busy || dma == null) return;
    if (_stop) {
      _finish();
      return;
    }
    if (_pending && !dma.ownsDdtRequest(this)) _pending = false;
    if (!_pending) {
      _pending = dma.requestDdt32(this, _requestAddress,
          write: false, transfer: _burst);
    }
  }

  bool _burst(int address, bool write) {
    if (!_busy || write || address != _requestAddress) return false;
    final bytes = _read!(address);
    if (bytes.length != 32) throw StateError('Sort-DMA requires 32-byte input');
    final data = ByteData.sublistView(bytes);
    if (_tablePhase) {
      final offset = _table & 31;
      final link = _width == 0
          ? data.getUint16(offset, Endian.little)
          : data.getUint32(offset, Endian.little);
      // Validate the link before consuming the table entry on a development stop.
      _linkOffset(link);
      _table += _width == 0 ? 2 : 4;
      _divisions = (_divisions + 1) & 0xffffffff;
      _pending = false;
      _follow(link);
    } else {
      if (_length == 0) {
        final type = data.getUint32(0, Endian.little) >> 29;
        if (type == 4 || type == 5) {
          final count = data.getUint32(24, Endian.little);
          if (count > 255 || (count > 0 && count < 4)) {
            throw const DcUnsupported('Sort-DMA prohibited current data size');
          }
          final next = data.getUint32(28, Endian.little);
          _linkOffset(next);
          _length = (count == 0 ? 256 : count) * 32;
          _next = next;
        }
      }
      _write!(bytes);
      _pending = false;
      _sent += 32;
      _current += 32;
      if (_length == 0 && _sent >= 128) {
        _finish(error: true);
      } else if (_length != 0 && _sent == _length) {
        _follow(_next);
      }
    }
    return true;
  }

  String? identifyDdtOwner(Object owner) =>
      identical(owner, this) ? 'sort' : null;
  DcDdtStateBinding? resolveDdtOwner(String id, int address, bool write) {
    if (id != 'sort') return null;
    _restoredBinding = (address, write);
    return (owner: this, transfer: _burst);
  }

  void validateDdtBinding() {
    if (_pending != (_dma?.ownsDdtRequest(this) ?? false) ||
        (_pending && _restoredBinding != (_requestAddress, false))) {
      throw const StateMismatch('Sort-DMA DDT binding');
    }
    _restoredBinding = null;
  }
}

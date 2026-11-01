import 'dart:typed_data';

import '../../state.dart';
import '../../util/int.dart';
import 'fault.dart';
import 'gpu_dma.dart';
import 'sort_dma.dart';

/// HOLLY interrupt status, masks and DMA trigger selection.
/// Dev.Box System Architecture §§2.7 and 8.4.1.1.
class DcSystemBus {
  DcSystemBus({bool holly2 = true})
      : normalMask = holly2 ? 0x3fffff : 0x1fffff {
    reset();
  }
  final int normalMask;
  static const errorMask = 0x9fffffff;
  int _normal = 0, _external = 0, _error = 0;
  final _masks = Uint32List(9), _triggers = Uint32List(4);
  final _setup = Uint32List(41);
  late final gpuDma = DcGpuDma(onNormal: raiseNormal, onError: raiseError);
  late final sortDma = DcSortDma(onNormal: raiseNormal, onError: raiseError);
  void Function()? onG2Trigger;
  bool dmaTriggersEnabled = true;

  void saveState(StateWriter writer) {
    writer.section('dc.holly.interrupt');
    writer.ints([normalMask, _normal, _external, _error]);
    writer.ints(_masks);
    writer.ints(_triggers);
    writer.ints([..._setup, ...sortDma.saveRegisters()]);
    writer.ints(gpuDma.saveRegisters());
  }

  void loadState(StateReader reader) {
    reader.section('dc.holly.interrupt');
    final status = reader.ints(),
        masks = reader.ints(),
        triggers = reader.ints();
    final setup = reader.ints();
    final gpuDma = reader.ints();
    if (status.length != 4 ||
        masks.length != 9 ||
        triggers.length != 4 ||
        status[0] != normalMask ||
        (setup.length != 41 && setup.length != 54) ||
        setup.any((value) => value < 0 || value > 0xffffffff) ||
        (gpuDma.length != 8 && gpuDma.length != 13) ||
        gpuDma.any((value) => value < 0 || value > 0xffffffff)) {
      throw const StateMismatch('HOLLY interrupt layout or board variant');
    }
    for (var i = 1; i < 4; i++) {
      if (status[i] < 0 || status[i] & ~_sourceMask(i - 1) != 0) {
        throw const StateMismatch('HOLLY interrupt status');
      }
    }
    for (var i = 0; i < masks.length; i++) {
      if (masks[i] < 0 || masks[i] & ~_sourceMask(i % 3) != 0) {
        throw const StateMismatch('HOLLY interrupt mask');
      }
    }
    for (var i = 0; i < triggers.length; i++) {
      if (triggers[i] < 0 || triggers[i] & ~_sourceMask(i & 1) != 0) {
        throw const StateMismatch('HOLLY DMA trigger');
      }
    }
    _normal = status[1];
    _external = status[2];
    _error = status[3];
    _masks.setAll(0, masks);
    _triggers.setAll(0, triggers);
    _setup.setAll(0, setup.take(41));
    sortDma.loadRegisters(setup.length == 54
        ? setup.sublist(41)
        : [
            setup[4],
            setup[5],
            setup[6],
            setup[7],
            setup[8],
            0,
            0,
            0,
            0,
            0,
            1,
            0,
            0
          ]);
    this.gpuDma.loadRegisters(gpuDma);
  }

  int get normalStatus => (_normal |
          (_external != 0 ? 0x40000000 : 0) |
          (_error != 0 ? 0x80000000 : 0))
      .mask32;
  int get externalStatus => _external;
  int get errorStatus => _error;

  void raiseNormal(int sources) {
    _normal |= sources & normalMask;
    if (dmaTriggersEnabled && sources & _triggers[0] & normalMask != 0)
      gpuDma.trigger();
    if (sources & _triggers[2] & normalMask != 0) onG2Trigger?.call();
  }

  void raiseError(int sources) => _error |= sources & errorMask;
  void setExternal(int sources) {
    final rising = sources & ~_external & 15;
    _external = sources & 15;
    if (dmaTriggersEnabled && rising & _triggers[1] != 0) gpuDma.trigger();
    if (rising & _triggers[3] != 0) onG2Trigger?.call();
  }

  /// Status/masks reset independently of the levels driven by external devices.
  void reset({bool clearExternal = false}) {
    _normal = _error = 0;
    if (clearExternal) _external = 0;
    _masks.fillRange(0, 9, 0);
    _triggers.fillRange(0, 4, 0);
    _setup.fillRange(0, _setup.length, 0);
    _setup[0] = 0x10000000;
    _setup[4] = _setup[5] = 0x08000000;
    _setup[0x4c ~/ 4] = 1;
    gpuDma.reset();
    sortDma.reset();
  }

  int get interruptLevel {
    for (var tier = 2; tier >= 0; tier--) {
      final offset = tier * 3;
      if ((_normal & _masks[offset]) != 0 ||
          (_external & _masks[offset + 1]) != 0 ||
          (_error & _masks[offset + 2]) != 0) {
        return (tier + 1) * 2;
      }
    }
    return 0;
  }

  /// HOLLY drives IRL1/IRL2; IRL0/IRL3 remain high.
  int get irlPins => 15 - interruptLevel;
  bool get gpuDmaRequest =>
      (_normal & _triggers[0]) != 0 || (_external & _triggers[1]) != 0;
  bool get g2DmaRequest =>
      (_normal & _triggers[2]) != 0 || (_external & _triggers[3]) != 0;
  int get g2NormalMask => _triggers[2];
  int get gpuNormalMask => _triggers[0];
  bool get c2DmaActive => _setup[2] & 1 != 0;
  int get c2Destination => _setup[0];

  void completeC2Burst() {
    if (!c2DmaActive) return;
    if (_setup[0] & 0x01000000 != 0) _setup[0] += 32;
    _setup[1] = (_setup[1] - 32) & 0xffffff;
    if (_setup[1] == 0) {
      _setup[2] = 0;
      raiseNormal(1 << 19);
    }
  }

  int? _maskIndex(int offset) {
    if (offset < 0x10 || offset > 0x38 || offset & 15 > 8 || offset & 3 != 0) {
      return null;
    }
    return ((offset >> 4) - 1) * 3 + ((offset & 15) >> 2);
  }

  int? _triggerIndex(int offset) =>
      switch (offset) { 0x40 => 0, 0x44 => 1, 0x50 => 2, 0x54 => 3, _ => null };
  int _sourceMask(int kind) =>
      switch (kind) { 0 => normalMask, 1 => 15, _ => errorMask };

  int read(int offset, int size) {
    if (size != 4) {
      throw DcUnsupported('HOLLY interrupt registers require longword access');
    }
    if (((offset >= 0x1300 && offset <= 0x1318) ||
            (offset >= 0x13f0 && offset <= 0x13f8)) &&
        offset & 3 == 0) {
      return gpuDma.read(offset - 0x1300);
    }
    if (offset < 0) {
      final register = offset + 0x100;
      if (const [0x10, 0x14, 0x18, 0x1c, 0x20, 0x60].contains(register)) {
        return sortDma.read(register);
      }
      if (register == 0xa4 || register == 0xac) {
        return 0; // Undocumented BIOS zero-initialized register.
      }
      if (register == 0x9c) return normalMask == 0x3fffff ? 0x0b : 2;
      if (register == 0x8c) return 0; // Functional empty transfer FIFOs.
      if (const [0, 4, 8, 0x40, 0x44, 0x48, 0x4c, 0xa0].contains(register)) {
        return _setup[register ~/ 4];
      }
      throw DcUnsupported('unimplemented HOLLY setup read: $register');
    }
    if (offset == 0) return normalStatus;
    if (offset == 4) return _external;
    if (offset == 8) return _error;
    final mask = _maskIndex(offset);
    if (mask != null) return _masks[mask];
    final trigger = _triggerIndex(offset);
    if (trigger != null) return _triggers[trigger];
    throw DcUnsupported('unimplemented system-bus register: $offset');
  }

  void write(int offset, int size, int value) {
    if (size != 4) {
      throw DcUnsupported('HOLLY interrupt registers require longword access');
    }
    if ((offset >= 0x1300 && offset <= 0x1318 && offset & 3 == 0) ||
        offset == 0x1380) {
      gpuDma.write(offset - 0x1300, value);
      return;
    }
    if (offset < 0) {
      final register = offset + 0x100;
      if (const [0x10, 0x14, 0x18, 0x1c, 0x20].contains(register)) {
        sortDma.write(register, value);
        return;
      }
      if ((register == 0xa4 || register == 0xac) && value == 0) return;
      if (register == 0x90) {
        if (value & 0xffff == 0x7611) {
          throw const DcUnsupported('HOLLY full-system software reset');
        }
        return;
      }
      final mask = switch (register) {
        0 => 0x03ffffe0,
        4 => 0x00ffffe0,
        8 || 0x40 => 1,
        0x44 => 31,
        0x48 => 15,
        0x4c => 3,
        0xa0 => 0x80000000,
        _ => throw DcUnsupported('unimplemented HOLLY setup write: $register'),
      };
      final fixed = register == 0 ? 0x10000000 : 0;
      _setup[register ~/ 4] = (value & mask) | fixed;
      return;
    }
    if (offset == 0) {
      _normal &= ~value;
      return;
    }
    if (offset == 4) {
      return; // External status is driven by its source, not software.
    }
    if (offset == 8) {
      _error &= ~value;
      return;
    }
    final mask = _maskIndex(offset);
    if (mask != null) {
      _masks[mask] = value & _sourceMask(mask % 3);
      return;
    }
    final trigger = _triggerIndex(offset);
    if (trigger != null) {
      final previous = _triggers[trigger];
      _triggers[trigger] = value & _sourceMask(trigger & 1);
      if ((trigger == 0 && _normal & _triggers[trigger] & ~previous != 0) ||
          (trigger == 1 && _external & _triggers[trigger] & ~previous != 0)) {
        gpuDma.trigger();
      }
      if ((trigger == 2 && _normal & _triggers[trigger] & ~previous != 0) ||
          (trigger == 3 && _external & _triggers[trigger] & ~previous != 0)) {
        onG2Trigger?.call();
      }
      return;
    }
    throw DcUnsupported('unimplemented system-bus register: $offset');
  }
}

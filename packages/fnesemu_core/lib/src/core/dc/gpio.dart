import '../../state.dart';

import 'fault.dart';

/// SH7750 general-purpose ports (hardware manual section 18).
class DcGpio {
  final _control = [0, 0];
  final _latch = [0, 0];
  final _outputMasks = [0, 0];
  final _pullupMasks = [0xffff, 15];
  final _sample = [0xffff, 15];
  int _interruptMask = 0;

  /// External drivers: a clear mask bit leaves the pin floating.
  int drivenMask = 0;
  int drivenValues = 0;
  bool enabled = false;

  static int? offset(int address) {
    if (address >= 0xc0000000 && address < 0xe0000000) return null;
    final physical = address & 0x1fffffff;
    return physical >= 0x1f80002c && physical <= 0x1f800048
        ? physical - 0x1f800000
        : null;
  }

  void reset({bool powerOn = true}) {
    if (!powerOn) return;
    _control.fillRange(0, 2, 0);
    _decodeControl(0);
    _decodeControl(1);
    _interruptMask = 0;
    enabled = false;
    // Data latches retain their contents even across power-on reset.
    _sample[0] = 0xffff;
    _sample[1] = 15;
  }

  void saveState(StateWriter writer) {
    writer.section('dc.sh4.gpio');
    writer.ints([
      ..._control,
      ..._latch,
      ..._sample,
      _interruptMask,
      drivenMask,
      drivenValues
    ]);
    writer.boolean(enabled);
  }

  /// Keep the sampled pins separate from current external drivers until BCLK.
  void loadState(StateReader reader) {
    reader.section('dc.sh4.gpio');
    final values = reader.ints();
    final gate = reader.boolean();
    const masks = [0xffffffff, 0xff, 0xffff, 15, 0xffff, 15, 0xffff];
    if (values.length != 9) throw const StateMismatch('SH4 GPIO layout');
    for (var i = 0; i < masks.length; i++) {
      if (values[i] < 0 || values[i] & ~masks[i] != 0) {
        throw const StateMismatch('SH4 GPIO register');
      }
    }
    _control.setAll(0, values.take(2));
    _latch.setAll(0, values.skip(2).take(2));
    _sample.setAll(0, values.skip(4).take(2));
    _interruptMask = values[6];
    drivenMask = values[7];
    drivenValues = values[8];
    enabled = gate;
    _decodeControl(0);
    _decodeControl(1);
  }

  // Decode configuration on writes; BCLK sampling only combines pin masks.
  void _decodeControl(int port) {
    var outputs = 0, pullups = 0;
    final control = _control[port];
    for (var bit = 0; bit < (port == 0 ? 16 : 4); bit++) {
      if (control & (1 << (bit * 2)) != 0) outputs |= 1 << bit;
      if (control & (2 << (bit * 2)) == 0) pullups |= 1 << bit;
    }
    _outputMasks[port] = outputs;
    _pullupMasks[port] = pullups;
  }

  bool get interruptPending =>
      enabled && (_interruptMask & ~_outputMasks[0] & ~_sample[0]) != 0;

  void tickBusClocks(int clocks) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    if (clocks == 0) return;
    // Floating inputs without pull-up resolve low as a deterministic policy.
    _sample[0] =
        ((drivenValues & drivenMask) | (_pullupMasks[0] & ~drivenMask)) &
            0xffff;
    _sample[1] = (((drivenValues & drivenMask) >> 16) |
            (_pullupMasks[1] & ~(drivenMask >> 16))) &
        15;
  }

  void _validate(int offset, int size) {
    final expected = switch (offset) {
      0x2c || 0x40 => 4,
      0x30 || 0x44 || 0x48 => 2,
      _ => 0,
    };
    if (expected == 0 || size != expected) {
      throw const DcUnsupported('GPIO register access width or address');
    }
  }

  int read(int offset, int size) {
    _validate(offset, size);
    if (offset == 0x48) return _interruptMask;
    final port = offset >= 0x40 ? 1 : 0;
    if (offset == 0x2c || offset == 0x40) return _control[port];
    final outputs = _outputMasks[port];
    return (_latch[port] & outputs) | (_sample[port] & ~outputs);
  }

  void write(int offset, int size, int value) {
    _validate(offset, size);
    if (offset == 0x48) {
      _interruptMask = value & 0xffff;
      return;
    }
    final port = offset >= 0x40 ? 1 : 0;
    if (offset == 0x2c || offset == 0x40) {
      _control[port] = value & (port == 0 ? 0xffffffff : 0xff);
      _decodeControl(port);
    } else {
      _latch[port] = value & (port == 0 ? 0xffff : 15);
    }
  }
}

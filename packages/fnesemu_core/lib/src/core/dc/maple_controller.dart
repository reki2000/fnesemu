import 'dart:typed_data';

import '../../pad_button.dart';
import '../../pad_source.dart';
import '../../state.dart';
import 'fault.dart';
import 'maple_device.dart';
import 'memory_card.dart';

// device information text, as character codes
const dcControllerProductName = '\x44\x72\x65\x61\x6d\x63\x61\x73\x74\x20\x43'
    '\x6f\x6e\x74\x72\x6f\x6c\x6c\x65\x72';

/// Standard controller packets in Maple wire byte order.
/// Controller Peripheral Hardware Specifications, Rev. 1.00.
class DcMapleController implements DcMapleDevice {
  final expansions = List<DcMapleDevice?>.filled(2, null);

  /// where the held buttons and axes are read from, set by the bus when
  /// the controller exchanges with the host; the condition is sampled
  /// from it on every Get Condition, so held input is not device state
  PadSource source = const NoPadSource();
  static const a = PadButton('A');
  static const b = PadButton('B');
  static const x = PadButton('X');
  static const y = PadButton('Y');
  static const start = PadButton('Start');
  static const leftTrigger = PadButton('L');
  static const rightTrigger = PadButton('R');
  static const buttons = [
    PadButton.up,
    PadButton.down,
    PadButton.left,
    PadButton.right,
    a,
    b,
    x,
    y,
    start,
    leftTrigger,
    rightTrigger,
  ];
  static const _digital = [
    (PadButton.right, 0x80),
    (PadButton.left, 0x40),
    (PadButton.down, 0x20),
    (PadButton.up, 0x10),
    (start, 8),
    (a, 4),
    (b, 2),
    (x, 0x400),
    (y, 0x200),
  ];
  bool _identified = false, _killed = false;

  void validateStateTarget() {
    for (final child in expansions) {
      if (child != null && child is! DcMemoryCard) {
        throw const StateMismatch('unregistered Maple expansion state');
      }
      if (child is DcMemoryCard) child.validateStateTarget();
    }
  }

  void saveState(StateWriter writer) {
    validateStateTarget();
    writer.section('dc.maple.controller');
    writer.boolean(_identified);
    writer.boolean(_killed);
    for (final child in expansions) {
      writer.string(child == null ? 'none' : 'memory_card');
      if (child is DcMemoryCard) child.saveState(writer);
    }
  }

  void loadState(StateReader reader) {
    validateStateTarget();
    reader.section('dc.maple.controller');
    final identified = reader.boolean(), killed = reader.boolean();
    final restored = <DcMemoryCard?>[];
    for (final child in expansions) {
      final kind = reader.string();
      if (child == null && kind == 'none') {
        restored.add(null);
      } else if (child is DcMemoryCard && kind == 'memory_card') {
        child.validateStateTarget();
        restored.add(DcMemoryCard(unit: child.unit)..loadState(reader));
      } else {
        throw const StateMismatch('Maple expansion configuration mismatch');
      }
    }
    // All child sections and destination bindings were checked before commit.
    for (var slot = 0; slot < restored.length; slot++) {
      final state = restored[slot];
      if (state == null) continue;
      final writer = StateWriter('dc.maple.expansion.transfer', 1, 0);
      state.saveState(writer);
      final childReader =
          StateReader(writer.take(), 'dc.maple.expansion.transfer', 1, 0);
      (expansions[slot] as DcMemoryCard).loadState(childReader);
      childReader.end();
    }
    _identified = identified;
    _killed = killed;
  }

  /// Electrical reset restores protocol discovery without releasing held keys.
  @override
  void resetDevice() {
    _identified = _killed = false;
    for (final child in expansions) {
      child?.resetDevice();
    }
  }

  @override
  void tickMasterClocks(int clocks) {
    for (final child in expansions) {
      child?.tickMasterClocks(clocks);
    }
  }

  static Uint8List _info() {
    final data = Uint8List(112);
    data.setAll(0, [0, 0, 0, 1, 0, 0x0f, 6, 0xfe]);
    data[16] = 0xff;
    data.fillRange(18, 108, 0x20);
    data.setAll(18, dcControllerProductName.codeUnits);
    data.setAll(48, dcPeripheralLicense.codeUnits);
    // Power fields are little endian within the otherwise mixed-order structure.
    ByteData.sublistView(data).setUint16(108, 430, Endian.little);
    ByteData.sublistView(data).setUint16(110, 500, Endian.little);
    return data;
  }

  /// Returns null for no electrical response. Device reset preserves held input.
  @override
  Uint8List? exchange(Uint8List request, int port) {
    final host = port << 6;
    if (_killed ||
        request.length < 4 ||
        request[2] != host ||
        request.length != (request[3] + 1) * 4) {
      return null;
    }
    if (request[1] != host | 0x20) {
      for (var slot = 0; slot < expansions.length; slot++) {
        if (request[1] == host | (1 << slot)) {
          return _identified ? expansions[slot]?.exchange(request, port) : null;
        }
      }
      return null;
    }
    var attached = 0;
    for (var slot = 0; slot < expansions.length; slot++) {
      if (expansions[slot] != null) attached |= 1 << slot;
    }
    Uint8List reply(int code, [List<int> data = const []]) =>
        Uint8List.fromList(
            [code, host, host | 0x20 | attached, data.length ~/ 4, ...data]);
    switch (request[0]) {
      case 1:
        if (request[3] != 0) return null;
        _identified = true;
        return reply(5, _info());
      case 2:
        throw const DcUnsupported('Maple extended controller information');
      case 3:
        if (request[3] != 0) return null;
        _identified = false;
        return reply(7);
      case 4:
        if (request[3] != 0) return null;
        _killed = true;
        return reply(7);
      case 9:
        if (!_identified) return null;
        if (request.length != 8) return null;
        if (ByteData.sublistView(request).getUint32(4) != 1) return reply(0xfe);
        // The condition is sampled where the hardware samples it: the
        // buttons are active low, the triggers report their digital
        // endpoints, and the host's left stick drives the analog stick.
        var keys = 0xffff;
        for (final (button, bit) in _digital) {
          if (source.isPressed(port, button)) keys &= ~bit;
        }
        final x = source.axis(port, PadAxis.leftX);
        final y = source.axis(port, PadAxis.leftY);
        int stick(double axis) => (128 + axis * 127).round().clamp(0, 255);
        return reply(8, [
          0,
          0,
          0,
          1,
          keys & 255,
          keys >> 8,
          source.isPressed(port, rightTrigger) ? 255 : 0,
          source.isPressed(port, leftTrigger) ? 255 : 0,
          stick(x),
          stick(y),
          128,
          128
        ]);
      case 14:
        return null; // System Architecture §5.2: writes receive no response.
      default:
        return reply(0xfd);
    }
  }
}

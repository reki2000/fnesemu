import '../../../pad_button.dart';
import '../../../pad_source.dart';

/// A DualShock 2 on port 1.
///
/// A command is `01 cmd 00` followed by its parameters. The reply is 0xff,
/// the mode byte, 0x5a and the data, one byte for every byte sent. The mode
/// byte is 0x41 in the digital mode, 0x73 in the analog mode, 0x79 when the
/// poll carries the pressure bytes, and 0xf3 in the configuration mode. Only
/// 0x42 (poll) and 0x43 (configuration mode) work outside the
/// configuration mode.
///
/// The replies follow the ps2tek pages on the controller commands. The
/// replies of 0x40, 0x41 and 0x4f, and the response mask that 0x4f sets,
/// are not described there and are unverified.
class Ps2Pad {
  // (button, bit in the 16-bit status word, index of its pressure byte)
  static const _buttons = [
    (PadButton.up, 4, 2),
    (PadButton.down, 6, 3),
    (PadButton.left, 7, 1),
    (PadButton.right, 5, 0),
    (PadButton("Select"), 0, -1),
    (PadButton("^"), 12, 4),
    (PadButton("#"), 15, 7),
    (PadButton("x"), 14, 6),
    (PadButton("o"), 13, 5),
    (PadButton("L1"), 10, 8),
    (PadButton("Start"), 3, -1),
    (PadButton("R1"), 11, 9),
    (PadButton("L2"), 8, 10),
    (PadButton("R2"), 9, 11),
    (PadButton("L3"), 1, -1),
    (PadButton("R3"), 2, -1),
  ];

  static const axes = [
    PadAxis.leftX,
    PadAxis.leftY,
    PadAxis.rightX,
    PadAxis.rightY,
  ];

  /// where the held buttons are read from, set by the core
  PadSource source = const NoPadSource();

  bool analogMode = false, configMode = false;

  /// the poll data bytes selected by command 0x4f, one bit per byte after
  /// the header; the buttons and the sticks by default
  int responseMask = 0x3f;
  final _rumble = List<int>.filled(6, 0xff);

  List<PadButton> get buttons => _buttons.map((b) => b.$1).toList();

  void reset() {
    analogMode = configMode = false;
    responseMask = 0x3f;
    _rumble.fillRange(0, 6, 0xff);
  }

  bool get _pressure => analogMode && responseMask & 0x3ffc0 != 0;

  /// the buttons as the 16-bit status word, 0 = pressed
  int get value {
    var value = 0xffff;
    for (final (button, bit, _) in _buttons) {
      if (source.isPressed(0, button)) value &= ~(1 << bit);
    }
    return value;
  }

  int get _mode => configMode
      ? 0xf3
      : analogMode
          ? (_pressure ? 0x79 : 0x73)
          : 0x41;

  // a stick byte: 0x80 is neutral, 0 is the left / top and 0xff the right /
  // bottom
  int _stick(PadAxis axis) {
    final v = source.axis(0, axis);
    final c = v < -1.0 ? -1.0 : (v > 1.0 ? 1.0 : v);
    return (0x80 + c * 127).round();
  }

  /// the data of a poll: the buttons, then the sticks (right X, right Y,
  /// left X, left Y) in the analog mode, then the pressure bytes
  List<int> _poll({bool pressure = true}) {
    final buttons = value;
    final data = [buttons & 0xff, buttons >> 8];
    if (!analogMode && !configMode) return data;
    data.addAll([
      _stick(PadAxis.rightX),
      _stick(PadAxis.rightY),
      _stick(PadAxis.leftX),
      _stick(PadAxis.leftY),
    ]);
    if (pressure && _pressure) {
      final levels = List<int>.filled(12, 0);
      for (final (button, _, index) in _buttons) {
        if (index >= 0 && source.isPressed(0, button)) levels[index] = 0xff;
      }
      data.addAll(levels);
    }
    return data;
  }

  /// The reply to the bytes [sent], [length] bytes long. Bytes past the
  /// data read as 0x00, and a command that is not accepted reads as 0xff.
  List<int> transfer(List<int> sent, int length) {
    int at(int i) => i < sent.length ? sent[i] : 0;
    final command = at(1);
    final mode = _mode;
    List<int>? data;
    if (command == 0x42) {
      data = _poll();
    } else if (command == 0x43) {
      data = configMode ? List<int>.filled(6, 0) : _poll(pressure: false);
      configMode = at(3) == 1;
    } else if (configMode) {
      switch (command) {
        case 0x40:
          data = [0, 0, 2, 0, 0, 0x5a];
        case 0x41:
          data = analogMode
              ? [
                  responseMask & 0xff,
                  (responseMask >> 8) & 0xff,
                  (responseMask >> 16) & 0xff,
                  0,
                  0,
                  0x5a,
                ]
              : List<int>.filled(6, 0);
        case 0x44:
          analogMode = at(3) == 1;
          data = List<int>.filled(6, 0);
        case 0x45:
          data = [3, 2, analogMode ? 1 : 0, 2, 1, 0];
        case 0x46:
          data = at(3) == 0 ? [0, 0, 1, 2, 0, 0x0a] : [0, 0, 1, 1, 1, 0x14];
        case 0x47:
          data = [0, 0, 2, 0, 1, 0];
        case 0x4c:
          data = [0, 0, 0, at(3) == 0 ? 4 : 7, 0, 0];
        case 0x4d:
          data = List<int>.of(_rumble);
          for (var i = 0; i < 6; i++) {
            _rumble[i] = at(3 + i);
          }
        case 0x4f:
          responseMask = at(3) | at(4) << 8 | (at(5) & 3) << 16;
          data = [0, 0, 0, 0, 0, 0x5a];
      }
    }
    if (data == null) return List<int>.filled(length, 0xff);
    return [
      for (var i = 0; i < length; i++)
        switch (i) {
          0 => 0xff,
          1 => mode,
          2 => 0x5a,
          _ => i - 3 < data.length ? data[i - 3] : 0,
        },
    ];
  }
}

// import '../../util/debug.dart';
import 'dart:typed_data';

import '../../pad_button.dart';
import '../../pad_source.dart';
import '../../util/int.dart';
import 'serial.dart' show SioResponse, SioDevice;
import 'state.dart';

// final _log = DebugLog('ps.pad');

class Pad extends SioDevice {
  static const int waitIgnore = -1;
  static const int waitAddr = 0; //
  static const int waitCommand = 1; //
  static const int waitPadNo = 2; //
  static const int waitData = 3; // payload bytes after the 0x5a response

  static const controllerNum = 1;

  /// where the held buttons and axes are read from, set by the core
  PadSource source = const NoPadSource();

  /// the buttons as the 16 bit status word, 0 = pressed
  int get buttonValue {
    var value = 0xffff;
    for (final (button, bit) in _buttons) {
      if (source.isPressed(0, button)) value &= ~(1 << bit);
    }
    return value;
  }

  // (pad button, bit number for status value)
  static const _buttons = [
    (PadButton.up, 4),
    (PadButton.down, 6),
    (PadButton.left, 7),
    (PadButton.right, 5),
    (PadButton("Select"), 0),
    (PadButton("L3"), 1),
    (PadButton("R3"), 2),
    (PadButton("Start"), 3),
    (PadButton("L2"), 8),
    (PadButton("R2"), 9),
    (PadButton("L1"), 10),
    (PadButton("R1"), 11),
    (PadButton("^"), 12),
    (PadButton("o"), 13),
    (PadButton("x"), 14),
    (PadButton("#"), 15),
  ];

  // set by the game: command 0x44 selects the analog mode (ID 0x73), command
  // 0x43 enters and leaves the configuration mode (ID 0xf3)
  bool analogMode = false;
  bool configMode = false;

  int padStep = waitAddr;
  int _command = 0;
  Uint8List _reply = _emptyReply;
  int _replyPos = 0;
  static final _emptyReply = Uint8List(0);

  /// The buttons in the unified key order: S is ^, Z is #, X is x, C is
  /// o, Q is L1, E is R1, the digit keys 1 2 3 4 are L2 L3 R2 R3, Enter
  /// is Start and Shift is Select. L3 and R3 exist only on the analog
  /// controller; on a digital one they are never reported.
  List<PadButton> get buttons => const [
        PadButton.up,
        PadButton.down,
        PadButton.left,
        PadButton.right,
        PadButton("^"),
        PadButton("#"),
        PadButton("x"),
        PadButton("o"),
        PadButton.none,
        PadButton.none,
        PadButton.none,
        PadButton("L1"),
        PadButton("R1"),
        PadButton("L2"),
        PadButton("L3"),
        PadButton("R2"),
        PadButton("R3"),
        PadButton.none,
        PadButton("Start"),
        PadButton("Select"),
      ];

  static const axes = [
    PadAxis.leftX,
    PadAxis.leftY,
    PadAxis.rightX,
    PadAxis.rightY,
  ];

  // a stick byte: 0x80 is neutral, 0 is the left / top and 0xff the right /
  // bottom
  int _stick(PadAxis axis) =>
      (0x80 + source.axis(0, axis).clamp(-1.0, 1.0) * 127).round();

  @override
  void reset() {
    analogMode = false;
    configMode = false;
    padStep = waitAddr;
  }

  @override
  void resetStep() {
    padStep = waitAddr;
  }

  SioResponse ack(int data, {int delay = 500}) {
    return SioResponse(data, ack: padStep != waitAddr, delay: delay);
  }

  @override
  SioResponse notify(int txData) {
    // if (padStep == waitMotor2) {
    //   _log.debugc(() => "notify txData:${txData.x2} dump:${dump()}");
    // }

    switch (padStep) {
      case waitAddr:
        if (txData == 0x01) {
          // _log.debugc(() => "0x01 -> -- <- ${dump()}");
          padStep = waitCommand;
          return ack(0xff);
        }

      case waitCommand:
        final reply = _replyFor(txData);
        if (reply == null) break;
        _command = txData;
        _reply = reply;
        _replyPos = 0;
        padStep = waitPadNo;
        return ack(configMode
            ? 0xf3
            : analogMode
                ? 0x73
                : 0x41);

      case waitPadNo:
        padStep = waitData;
        return ack(0x5a);

      case waitData:
        _receive(_replyPos, txData);
        final value = _reply[_replyPos++];
        if (_replyPos == _reply.length) padStep = waitAddr;
        return ack(value);
    }

    padStep = waitIgnore;
    return SioResponse(0xff, ignored: true, ack: false);
  }

  // payload of a command, null if the command is not supported. the length of
  // a poll depends on the mode: 2 bytes of buttons, plus 4 stick bytes (right
  // X, right Y, left X, left Y) in the analog and configuration modes.
  Uint8List? _replyFor(int command) {
    Uint8List bytes(List<int> v) => Uint8List.fromList(v);
    final buttons = buttonValue;
    final poll = analogMode || configMode
        ? bytes([
            buttons.mask8,
            buttons.shr8.mask8,
            _stick(PadAxis.rightX),
            _stick(PadAxis.rightY),
            _stick(PadAxis.leftX),
            _stick(PadAxis.leftY),
          ])
        : bytes([buttons.mask8, buttons.shr8.mask8]);
    switch (command) {
      case 0x42: // poll
        return poll;
      case 0x43: // enter / leave the configuration mode
        return configMode ? Uint8List(6) : poll;
      case 0x44: // select the digital / analog mode
      case 0x4d: // vibration motor mapping
        if (!configMode) return null;
        return command == 0x44
            ? Uint8List(6)
            : bytes([0x00, 0x01, 0xff, 0xff, 0xff, 0xff]);
      case 0x45: // controller model and LED
        return configMode
            ? bytes([0x01, 0x02, analogMode ? 1 : 0, 0x02, 0x01, 0x00])
            : null;
      case 0x46: // constants, selected by the first parameter
      case 0x47:
      case 0x4c:
        return configMode ? _constants(command, 0) : null;
    }
    return null;
  }

  // payload of the constant commands for the parameter [select]. games poll
  // them and stay in the configuration mode until the values match.
  Uint8List _constants(int command, int select) {
    final List<int> v;
    switch (command) {
      case 0x46:
        v = select == 0
            ? [0x00, 0x00, 0x01, 0x02, 0x00, 0x0a]
            : [0x00, 0x00, 0x01, 0x01, 0x01, 0x14];
      case 0x47:
        v = [0x00, 0x00, 0x02, 0x00, 0x01, 0x00];
      default: // 0x4c
        v = [0x00, 0x00, 0x00, select == 0 ? 0x04 : 0x06, 0x00, 0x00];
    }
    return Uint8List.fromList(v);
  }

  // handles a parameter byte sent by the console at payload position [pos]
  void _receive(int pos, int txData) {
    if (pos != 0) return;
    if (_command == 0x46 || _command == 0x47 || _command == 0x4c) {
      _reply = _constants(_command, txData);
    } else if (_command == 0x43) {
      configMode = txData == 1;
    } else if (_command == 0x44 && configMode) {
      analogMode = txData == 1;
    }
  }

  @override
  void saveState(StateWriter w) {
    w.section('ps-pad');
    w.ints([padStep, _command, _replyPos]);
    w.boolean(analogMode);
    w.boolean(configMode);
    w.bytes(_reply);
  }

  @override
  void loadState(StateReader s) {
    s.section('ps-pad');
    final v = s.fields(3, 'ps pad');
    padStep = v[0];
    _command = v[1];
    _replyPos = v[2];
    analogMode = s.boolean();
    configMode = s.boolean();
    _reply = Uint8List.fromList(s.bytes());
  }

  @override
  String dump() => "step:$padStep button:${buttonValue.x4}";
}

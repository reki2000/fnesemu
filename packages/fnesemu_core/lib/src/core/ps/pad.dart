// import '../../util/debug.dart';
import 'dart:typed_data';

import '../../pad_button.dart';
import '../../pad_source.dart';
import '../../util/int.dart';
import 'serial.dart' show SioResponse, SioDevice;

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
    (PadButton("Select"), 0), // 4
    (PadButton("^"), 12), // 6
    (PadButton("#"), 15), // 9
    (PadButton("x"), 14), // 8
    (PadButton("o"), 13), // 7
    (PadButton("L1"), 10), // 10
    (PadButton("Start"), 3), // 5
    (PadButton("R1"), 11), // 11
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

  List<PadButton> get buttons => _buttons.map((b) => b.$1).toList();

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
        return configMode ? Uint8List(6) : null;
    }
    return null;
  }

  // handles a parameter byte sent by the console at payload position [pos]
  void _receive(int pos, int txData) {
    if (pos != 0) return;
    if (_command == 0x43) {
      configMode = txData == 1;
    } else if (_command == 0x44 && configMode) {
      analogMode = txData == 1;
    }
  }

  @override
  String dump() => "step:$padStep button:${buttonValue.x4}";
}

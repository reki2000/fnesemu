// Dart imports:
import 'dart:async';

// Project imports:
import 'package:flutter/foundation.dart';

import '../core_pce/pce.dart';
import 'debug/debugger.dart';

typedef NesPadButton = PadButton;

/// A Controller of the emulator core.
/// The external GUI should kick `exec` continuously. then subscribe `controller.*stream`
class CoreController {
  late Pce _core;
  late Debugger debugger;

  CoreController() {
    _core = Pce();
    debugger = Debugger(_core);
  }

  Timer? _timer;
  double _fps = 0.0;

  /// runs emulation with 16ms timer
  void run() {
    final startAt = DateTime.now();
    var frames = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 10), (timer) {
      if (_fps < 60.0) {
        runFrame();
        frames++;
      }
      _fps = frames /
          (DateTime.now().difference(startAt).inMilliseconds.toDouble() /
              1000.0);
    });
  }

  /// stops emulation
  void stop() {
    _timer?.cancel();
  }

  /// executes emulation with 1 cpu instruction
  void runStep() {
    _core.exec();
    debugger.addLog(_core.state);
    _renderAll();
  }

  /// executes emulation during 1 scanline
  bool runScanLine({skipRender = false}) {
    while (true) {
      if (debugger.debugOption.breakPoint == _core.pc) {
        stop();
        return false;
      }

      // exec 1 cpu instruction
      final result = _core.exec();

      // need this check for performance
      if (debugger.debugOption.log) {
        debugger.addLog(_core.state);
      }

      if (!result.stopped) {
        stop();
        return false;
      }

      if (result.scanlineRendered) {
        break;
      }
    }
    if (!skipRender) {
      _renderAll();
    }
    return true;
  }

  /// executes emulation during 1 frame
  void runFrame() {
    for (int i = 0; i < Pce.scanlinesInFrame; i++) {
      if (!runScanLine(skipRender: true)) {
        _renderAll();
        return;
      }
    }
    _renderAll();
  }

  void _renderAll() {
    _imageStream.add(_core.ppuBuffer());
    _audioStream.add(_core.apuBuffer());
    debugger.pushStream();
    _fpsStream.add(_fps);
  }

  void reset() {
    _core.reset();
    debugger.debugOption.breakPoint = 0;
    debugger.pushStream();
    _renderAll();
  }

  void setRom(Uint8List body) {
    _core.setRom(body);
    debugger.pushStream();
  }

  bool isRunning() {
    return _timer?.isActive ?? false;
  }

  // screen/audio/fps

  final _imageStream = StreamController<Uint8List>();
  final _audioStream = StreamController<Float32List>();
  final _fpsStream = StreamController<double>();

  Stream<Uint8List> get imageStream => _imageStream.stream;
  Stream<Float32List> get audioStream => _audioStream.stream;
  Stream<double> get fpsStream => _fpsStream.stream;

  final audioSampleRate = 21477270 ~/ 6;

  // pad

  final _padUpStream = StreamController<NesPadButton>.broadcast();
  final _padDownStream = StreamController<NesPadButton>.broadcast();

  Stream<NesPadButton> get padUpStream => _padUpStream.stream;
  Stream<NesPadButton> get padDownStream => _padDownStream.stream;

  void padDown(NesPadButton k) {
    _padDownStream.add(k);
    _core.padDown(k);
  }

  void padUp(NesPadButton k) {
    _padUpStream.add(k);
    _core.padUp(k);
  }

  runUntilRts() {
    while (true) {
      _core.exec();
      if (_core.dump().contains("60        RTS")) {
        break;
      }
    }
    _renderAll();
  }
}

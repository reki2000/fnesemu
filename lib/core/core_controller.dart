// Dart imports:
import 'dart:async';
import 'dart:typed_data';

import 'debugger.dart';
import 'frame_counter.dart';
// Project imports:

import 'pce/pce.dart';
import 'types.dart';

typedef NesPadButton = PadButton;

/// A Controller of the emulator core.
/// The external GUI should kick `exec` continuously. then subscribe `controller.*stream`
class CoreController {
  late Pce _core;
  late Debugger debugger;

  CoreController() {
    _core = Pce();
    debugger = Debugger(_core);
    _core.audioStream = _audioStream.sink;
  }

  // used in main loop to periodically execute the emulator. if null, the emulator is stopped.
  bool _running = false;

  // used to calculate the next frame timing
  int _nextFrameClock = 0;

  // calculated fps
  double _fps = 0.0;

  final fpsLimit = 59.97;

  /// runs emulation continuously
  void run() async {
    final fpsCounter =
        FrameCounter(duration: const Duration(seconds: 5)); // shortlife counter
    final runSpeedCounter = FrameCounter(); // wholelife counter

    _running = true;
    while (_running) {
      // wait the event loop to be done
      await Future.delayed(const Duration());

      // run emulation until the next frame timing
      if (_core.cpu.clocks < _nextFrameClock) {
        runFrame();
        fpsCounter.count();
        runSpeedCounter.count();
        continue;
      }

      final now = DateTime.now();

      // proceed the emulation when fps is lower than the limit
      if (runSpeedCounter.fps(now) < fpsLimit) {
        _nextFrameClock = Pce.systemClockHz *
            runSpeedCounter.elapsedMilliseconds(now) ~/
            1000;
      }

      _fps = fpsCounter.fps(now);
    }
  }

  /// stops emulation
  void stop() {
    _running = false;
  }

  void reset() {
    _running = false;
    _nextFrameClock = 0;
    _fps = 0.0;

    _core.reset();
    debugger.debugOption.breakPoint = 0;
    debugger.pushStream();

    _renderAll();
  }

  /// executes emulation with 1 cpu instruction
  void runStep() {
    _core.exec();
    debugger.addLog(_core.tracingState);
    _renderAll();
  }

  /// executes emulation during 1 scanline
  bool runScanLine({skipRender = false}) {
    while (true) {
      if (debugger.debugOption.breakPoint == _core.programCounter) {
        stop();
        return false;
      }

      // exec 1 cpu instruction
      final result = _core.exec();

      // need this check for performance
      if (debugger.debugOption.log) {
        debugger.addLog(_core.tracingState);
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
    _imageStream.add(_core.imageBuffer());
    debugger.pushStream();
    _fpsStream.add(_fps);
  }

  void setRom(Uint8List body) {
    _core.setRom(body);
    debugger.pushStream();
  }

  bool isRunning() {
    return _running;
  }

  // screen/audio/fps

  final _imageStream = StreamController<ImageBuffer>();
  final _audioStream = StreamController<Float32List>();
  final _fpsStream = StreamController<double>();

  Stream<ImageBuffer> get imageStream => _imageStream.stream;
  Stream<Float32List> get audioStream => _audioStream.stream;
  Stream<double> get fpsStream => _fpsStream.stream;

  final audioSampleRate = Pce.audioSampleRate;

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
}

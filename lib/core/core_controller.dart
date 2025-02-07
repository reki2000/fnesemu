// Dart imports:
import 'dart:async';
import 'dart:typed_data';

import 'core.dart';
import 'core_factory.dart';
import 'debugger.dart';
import 'frame_counter.dart';
// Project imports:

import 'pad_button.dart';
import 'types.dart';

/// A Controller of the emulator core.
/// The external GUI should kick `exec` continuously. then subscribe `controller.*stream`
class CoreController {
  CoreController() {
    setCore("gen");
  }

  late Core _core;
  late Debugger debugger;

  void setCore(String core) {
    stop();

    switch (core) {
      case 'pce':
        _core = CoreFactory.ofPce();
        break;
      case 'nes':
        _core = CoreFactory.ofNes();
        break;
      case 'gen':
      case 'md':
        _core = CoreFactory.ofMd();
        break;
      default:
        throw Exception('unsupported core: $core');
    }

    _initCore();
  }

  _initCore() {
    debugger = Debugger(_core);
    _core.onAudio(onAudio);
    debugger.pushStream();
    reset();
  }

  // used in main loop to periodically execute the emulator. if null, the emulator is stopped.
  bool _running = false;
  int _runningCount = 0;
  int _currentCpuClocks = 0;

  // calculated fps
  double _fps = 0.0;

  /// runs emulation continuously
  Future<void> run() async {
    await stop();

    _running = true;
    _runningCount++;

    final fpsCounter = FrameCounter(
        duration: const Duration(milliseconds: 500)); // shortlife counter
    final initialCpuClocks = _currentCpuClocks;
    final runStartedAt = DateTime.now();
    int nextFrameClocks = 0;
    // int awaitCount = 0;

    while (_running) {
      // // // wait the event loop to be done
      // if (awaitCount == 30) {
      //   await Future.delayed(const Duration());
      //   awaitCount = 0;
      // }
      // awaitCount++;

      final now = DateTime.now();
      _fps = fpsCounter.fps(now);

      // run emulation until the next frame timing
      if (_currentCpuClocks - initialCpuClocks < nextFrameClocks) {
        runFrame();
        fpsCounter.count();
        await Future.delayed(const Duration());
        continue;
      }

      // proceed the emulation
      nextFrameClocks = _core.systemClockHz *
          (now.difference(runStartedAt).inMilliseconds) ~/
          1000;
    }

    _runningCount--;
  }

  /// stops emulation
  Future<void> stop() async {
    _running = false;

    while (_runningCount > 0) {
      await Future.delayed(const Duration());
    }

    return;
  }

  void reset() {
    _running = false;
    _fps = 0.0;
    _currentCpuClocks = 0;

    _core.reset();

    debugger.log.clear();
    debugger.opt.breakPoint = [-1];
    debugger.pushStream();

    _renderAll();
  }

  /// executes emulation with 1 cpu instruction
  void runStep() {
    final opt = debugger.opt;
    if (opt.log) {
      debugger.addLog(_core.tracingState(opt.targetCpuNo));
    }

    while (true) {
      final result = _core.exec();
      _currentCpuClocks = result.elapsedClocks;

      if (result.executed[opt.targetCpuNo]) {
        break;
      }
    }

    _renderAll();
  }

  /// executes emulation during 1 scanline
  bool runScanLine({skipRender = false}) {
    final opt = debugger.opt;
    bool traceNext = true;

    while (true) {
      if (opt.breakPoint[0] == _core.programCounter(opt.targetCpuNo)) {
        stop();
        return false;
      }

      // need this check for performance
      if (opt.log && traceNext) {
        debugger.addLog(_core.tracingState(opt.targetCpuNo));
        traceNext = false;
      }

      // exec 1 cpu instruction
      final result = _core.exec();
      _currentCpuClocks = result.elapsedClocks;

      if (result.executed[opt.targetCpuNo]) {
        traceNext = true;
      }

      if (result.stopped) {
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
    for (int i = 0; i < _core.scanlinesInFrame; i++) {
      if (!runScanLine(skipRender: true)) {
        break;
      }
    }

    _renderAll();
  }

  void _renderAll() {
    onImage(_core.imageBuffer());
    debugger.pushStream();
    _fpsStream.add(_fps);
  }

  void setRom(Uint8List body) {
    stop();
    _core.setRom(body);
    reset();
    debugger.pushStream();
  }

  bool isRunning() {
    return _running;
  }

  // screen/audio/fps
  final _fpsStream = StreamController<double>();

  Stream<double> get fpsStream => _fpsStream.stream;

  void Function(AudioBuffer) onAudio = (_) {};
  void Function(ImageBuffer) onImage = (_) {};

  void padDown(int controlerId, PadButton k) {
    _core.padDown(controlerId, k);
  }

  void padUp(int controlerId, PadButton k) {
    _core.padUp(controlerId, k);
  }

  List<PadButton> get buttons => _core.buttons;
}

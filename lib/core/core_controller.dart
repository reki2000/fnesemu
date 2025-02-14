// Dart imports:
import 'dart:async';
import 'dart:core';
import 'dart:typed_data';

import 'core.dart';
import 'core_factory.dart';
import 'debugger.dart';
import 'frame_counter.dart';
// Project imports:

import 'pad_button.dart';
import 'types.dart';

/// A Controller of the emulator core.
/// The external GUI should kick `run`. then subscribe `controller.*stream`
class CoreController {
  final void Function() _onStop;
  final void Function(AudioBuffer) _onAudio;
  final void Function(ImageBuffer) _onImage;

  CoreController(this._onStop, this._onAudio, this._onImage);

  Core _core = EmptyCore();
  Debugger debugger = Debugger(EmptyCore());

  void init(String coreName, Uint8List body) {
    switch (coreName) {
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
        throw Exception('unsupported core: $coreName');
    }

    _core.onAudio(_onAudio);
    _core.setRom(body);

    debugger = Debugger(_core);
    debugger.pushStream();

    reset();
  }

  // used in main loop to periodically execute the emulator. if null, the emulator is stopped.
  bool _running = false;
  int _runningCount = 0;
  int _currentCpuClocks = 0;

  int _runMode = 0;
  static const runModeNone = 0;
  static const runModeStep = 1;
  static const runModeStepOut = 2;
  static const runModeLine = 3;
  static const runModeFrame = 4;

  int _scanline = 0;
  int _frames = 0;

  bool isRunning() => _running;

  /// runs emulation continuously
  Future<void> run({int mode = 0}) async {
    await stop();

    _runMode = mode;

    _running = true;
    _runningCount++;

    final fpsCounter = FrameCounter(
        duration: const Duration(milliseconds: 500)); // shortlife counter
    final initialCpuClocks = _currentCpuClocks;
    final runStartedAt = DateTime.now();
    int nextFrameClocks = 0;
    // int awaitCount = 0;

    while (_running) {
      final now = DateTime.now();
      _fps = fpsCounter.fps(now);

      // run emulation until the next frame timing
      if (_currentCpuClocks - initialCpuClocks < nextFrameClocks) {
        _runFrame();
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

  /// stop emulation
  Future<void> stop() async {
    _running = false;

    while (_runningCount > 0) {
      await Future.delayed(const Duration());
    }

    _onStop();

    return;
  }

  /// reset emulation. keep run/stop state
  void reset() {
    _running = false;
    _fps = 0.0;
    _currentCpuClocks = 0;

    _core.reset();

    debugger.log.clear();
    debugger.opt.breakPoint = -1;
    debugger.pushStream();

    _renderAll();
  }

  /// executes emulation during 1 frame
  void _runFrame() {
    while (_scanline++ < _core.scanlinesInFrame) {
      if (!_runScanLine()) {
        return;
      }
    }

    _scanline = 0;
    _frames++;

    if (_runMode == runModeFrame) {
      stop();
    }

    _renderAll();
  }

  /// for debugger: executes emulation during 1 scanline
  /// returns false if the emulation is stopped
  bool _runScanLine() {
    final opt = debugger.opt;
    bool cpuExecuted = true;

    while (true) {
      if (cpuExecuted && opt.log) {
        debugger.addLog(_core.tracingState(opt.targetCpuNo));
        cpuExecuted = false;
      }

      // exec 1 cpu instruction
      final result = _core.exec(_runMode == runModeStep);
      _currentCpuClocks = result.elapsedClocks;

      if (result.stopped) {
        stop();
        return false;
      }

      cpuExecuted = result.executed(opt.targetCpuNo);

      if (cpuExecuted &&
          opt.showDebugView &&
          (opt.breakPoint == _core.programCounter(opt.targetCpuNo) ||
              _runMode == runModeStep ||
              _runMode == runModeStepOut &&
                  _core.stackPointer(opt.targetCpuNo) > opt.stackPointer)) {
        _renderAll();
        stop();
        return false;
      }

      if (result.scanlineRendered) {
        if (_runMode == runModeLine) {
          _renderAll();
          stop();
          return false;
        }

        return true;
      }
    }
  }

  void _renderAll() {
    _onImage(_core.imageBuffer());
    debugger.pushStream();
    _fpsStream.add(_fps);
  }

  // calculated fps
  double _fps = 0.0;

  // screen/audio/fps
  final _fpsStream = StreamController<double>();

  // provides fps value
  Stream<double> get fpsStream => _fpsStream.stream;

  // UI invokes this when a button of the pad is down
  void padDown(int controlerId, PadButton k) {
    _core.padDown(controlerId, k);
  }

  // UI invokes this when a button of the pad is up
  void padUp(int controlerId, PadButton k) {
    _core.padUp(controlerId, k);
  }

  // returns a list of core's buttons
  List<PadButton> get buttons => _core.buttons;
}

// Dart imports:
import 'dart:async';
import 'dart:core';
import 'dart:typed_data';

import 'package:fnesemu/core/sram.dart';
import 'package:fnesemu/util/debug.dart';

import 'core.dart';
import 'core_empty.dart';
import 'core_factory.dart';
import 'debugger.dart';
import 'disc.dart';
import 'frame_counter.dart';
// Project imports:

import 'pad_button.dart';
import 'types.dart';

class CoreControllerState {
  bool _running = false;
  bool get running => _running;
  set running(bool running) {
    _running = running;
    _notifier(this);
  }

  final void Function(CoreControllerState) _notifier;
  CoreControllerState(void Function(CoreControllerState) notifier)
      : _notifier = notifier;
}

/// A Controller of the emulator core.
/// The external GUI should kick `run`. then subscribe `controller.*stream`
class CoreController {
  final void Function(AudioBuffer) _onAudio;
  final void Function(ImageBuffer) _onImage;

  final CoreControllerState _state;
  final Sram _sram;

  CoreController(onStateChange, this._onAudio, this._onImage, this._sram)
      : _state = CoreControllerState(onStateChange);

  Core _core = EmptyCore();
  Debugger debugger = Debugger(EmptyCore());

  void init(String coreName, Uint8List body, {Uint8List? extRom}) {
    _core = CoreFactory.of(coreName)
      ..setSram(_sram)
      ..onAudio(_onAudio)
      ..setRom(body);

    if (extRom != null) {
      _core.setRom(extRom);
    }

    debugger.setCore(_core);

    reset();
  }

  int _currentCpuClocks = 0;

  int _runMode = 0;
  static const runModeNone = 0;
  static const runModeStep = 1;
  static const runModeStepOut = 2;
  static const runModeLine = 3;
  static const runModeFrame = 4;

  int _scanline = 0;
  int _frames = 0;

  bool _stopRequested = false;

  /// runs emulation continuously
  run({int mode = runModeNone}) async {
    if (_state.running) {
      return;
    }

    _state.running = true;
    _stopRequested = false;

    _runMode = mode;

    final fpsCounter = FrameCounter(
        duration: const Duration(milliseconds: 500)); // shortlife counter
    final initialCpuClocks = _currentCpuClocks;
    final runStartedAt = DateTime.now();
    int nextFrameClocks = 0;

    while (!_stopRequested) {
      final now = DateTime.now();
      _fps = fpsCounter.fps(now);

      // run emulation until the next frame timing
      if (_currentCpuClocks - initialCpuClocks < nextFrameClocks) {
        _runFrame();
        fpsCounter.count();
        await Future.delayed(const Duration(milliseconds: 4));
        continue;
      }

      // proceed the emulation
      nextFrameClocks = _core.systemClockHz *
          (now.difference(runStartedAt).inMilliseconds) ~/
          1000;
      // nextFrameClocks ~/= 2; // slow down for performance issue
    }

    _stopRequested = false;
    _state.running = false;
  }

  /// stop emulation
  stop() async {
    _stopRequested = true;

    while (_state.running) {
      await Future.delayed(const Duration());
    }

    return;
  }

  /// reset emulation. keep run/stop state
  reset() async {
    _fps = 0.0;
    _currentCpuClocks = 0;

    _core.reset();

    debugger.reset();

    _renderAll();

    if (_state.running) {
      await stop();
      run();
    }
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
    final step = _runMode != runModeNone || opt.breakPoint >= 0 || opt.log;
    bool cpuExecuted = true;

    while (true) {
      if (cpuExecuted && opt.log) {
        debugger.addLog(_core.trace(opt.targetCpuNo));
        cpuExecuted = false;
      }

      // exec 1 cpu instruction
      final result = _core.exec(step);
      _currentCpuClocks = result.elapsedClocks;

      if (result.stopped) {
        stop();
        return false;
      }

      cpuExecuted = result.executed(opt.targetCpuNo);

      final needBreak = cpuExecuted &&
          opt.showDebugView &&
          ((opt.breakClock <= debugStatus.clock && opt.breackClockEnabled) ||
              opt.breakPoint == _core.programCounter(opt.targetCpuNo) ||
              _runMode == runModeStep ||
              _runMode == runModeStepOut &&
                  _core.stackPointer(opt.targetCpuNo) > opt.stackPointer);

      if (needBreak) {
        opt.breackClockEnabled = opt.breakClock > debugStatus.clock;
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

  void setDisc(Disc disc) {
    _core.setDisc(disc);
  }

  // returns a list of core's buttons
  List<PadButton> get buttons => _core.buttons;
}

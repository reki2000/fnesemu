// Dart imports:
import 'dart:async';
import 'dart:core';
import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu/core/sram.dart';
import 'package:fnesemu/util/debug.dart';

import 'cdrom_drive.dart';
import 'core.dart';
import 'core_empty.dart';
import 'core_factory.dart';
import 'debugger.dart';
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

  /// id of the running system (CoreSystem.id), empty if none
  String get system => _system;
  String _system = "";

  /// replaces the core with a new one of [system] (CoreSystem.id), loaded
  /// with [bios] and [rom]. without [rom], the core boots its BIOS.
  /// the emulation is stopped during the replacement, and stays stopped.
  /// if loading fails, the previous core and its sram are kept.
  Future<void> init(String system,
      {Uint8List? rom,
      List<Uint8List> bios = const [],
      CdromDrive? drive}) async {
    final wasRunning = _state.running;
    await stop();

    // setRom() switches the shared sram to the new rom
    final sramId = _sram.id;
    final sramData = Uint8List.fromList(_sram.data);

    final Core core;
    try {
      core = CoreFactory.of(system)
        ..setSram(_sram)
        ..onAudio(_onAudio)
        ..setBiosFiles(bios);

      if (rom != null) {
        core.setRom(rom);
      }
    } catch (_) {
      _restoreSram(sramId, sramData);
      if (wasRunning) {
        run();
      }
      rethrow;
    }

    if (drive != null) {
      core.setCdromDrive(drive);
    }

    _core = core;
    _system = system;
    debugger.setCore(_core);

    await reset();
  }

  void _restoreSram(String id, Uint8List data) {
    if (_sram.id == id) {
      return;
    }

    if (id.isEmpty) {
      _sram.reset();
    } else {
      _sram.init(id, data);
    }
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

  // minimum time given to the UI after each frame
  static const minYieldUs = 4000;

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

    // the emulation proceeds by the real time elapsed. when the core is slower
    // than the real time, the clocks behind are dropped instead of being
    // caught up later: the emulation slows down and the UI keeps running.
    final clocksInFrame = _core.clocksInScanline * _core.scanlinesInFrame;
    final clocksPerUs = _core.systemClockHz / 1000000;
    final watch = Stopwatch()..start();
    int lastUs = 0;
    double targetClocks = _currentCpuClocks.toDouble();

    while (!_stopRequested) {
      final nowUs = watch.elapsedMicroseconds;
      targetClocks += (nowUs - lastUs) * clocksPerUs;
      lastUs = nowUs;

      if (_currentCpuClocks >= targetClocks) {
        // ahead of the real time
        await Future.delayed(const Duration(milliseconds: 1));
        continue;
      }

      _fps = fpsCounter.fps(DateTime.now());
      _runFrame();
      fpsCounter.count();

      // gives the UI a quarter of the time at least
      final frameUs = watch.elapsedMicroseconds - nowUs;
      await Future.delayed(
          Duration(microseconds: max(minYieldUs, frameUs ~/ 3)));

      // keeps up to 1 frame behind
      final behind = targetClocks - _currentCpuClocks;
      if (behind > clocksInFrame) {
        targetClocks = (_currentCpuClocks + clocksInFrame).toDouble();
      }
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
    final core = _core;
    if (core case final FrameRunner runner
        when !debugger.opt.showDebugView && _runMode == runModeNone) {
      // the core runs the rest of the frame by itself
      final result = runner.runFrame(core.scanlinesInFrame - _scanline);
      _currentCpuClocks = result.elapsedClocks;
      if (result.stopped) {
        _scanline = 0;
        stop();
        return;
      }
    } else {
      while (_scanline++ < core.scanlinesInFrame) {
        if (!_runScanLine()) {
          return;
        }
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

    if (!opt.showDebugView) {
      while (true) {
        // exec 1 cpu instruction
        final result = _core.exec(false);
        _currentCpuClocks = result.elapsedClocks;

        if (result.stopped) {
          stop();
          return false;
        }

        if (result.scanlineRendered) {
          break;
        }
      }
    } else {
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
          break;
        }
      }
    }

    if (_runMode == runModeLine) {
      _renderAll();
      stop();
      return false;
    }

    return true;
  }

  void _renderAll() {
    _onImage(_core.imageBuffer());
    debugger.pushStream();
    _fpsStream.add(_fps);
  }

  // calculated fps
  double _fps = 0.0;

  // screen/audio/fps
  final _fpsStream = StreamController<double>.broadcast();

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

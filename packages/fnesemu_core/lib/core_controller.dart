import 'dart:async';
import 'dart:core';
import 'dart:math';
import 'dart:typed_data';

import 'core_factory.dart';
import 'debugger.dart';
import 'src/cdrom_drive.dart';
import 'src/core.dart';
import 'src/internal/frame_counter.dart';
import 'src/pad_button.dart';
import 'src/sram.dart';
import 'src/types.dart';
import 'src/util/debug.dart';

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

  Core _core = Core();
  late final Debugger debugger =
      Debugger(_core, onRun: _runExecution, onStop: _stopExecution);

  /// id of the running system (CoreSystem.id), empty if none
  String get system => _system;
  String _system = "";

  bool acceptsDisc(CoreSystem media) {
    final loaded = CoreFactory.systemOrNull(_system);
    return loaded != null && loaded.disc == media.id;
  }

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
    final metadata = CoreFactory.system(system);
    debugger.setCore(_core,
        paletteCount: metadata.debugPaletteCount,
        vramBits: metadata.debugVramBits);

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

  int _scanline = 0;

  bool _stopRequested = false;

  // minimum time given to the UI after each frame
  static const minYieldUs = 4000;

  /// runs emulation continuously
  Future<void> run() {
    debugger.cancelExecution();
    return _runExecution();
  }

  Future<void> _runExecution() async {
    if (_system.isEmpty || _state.running) {
      return;
    }

    final fpsCounter =
        FrameCounter(duration: const Duration(milliseconds: 500));

    // the emulation proceeds by the real time elapsed. when the core is slower
    // than the real time, the clocks behind are dropped instead of being
    // caught up later: the emulation slows down and the UI keeps running.
    final clocksInFrame = _core.clocksInScanline * _core.scanlinesInFrame;
    final clocksPerUs = _core.systemClockHz / 1000000;
    final watch = Stopwatch()..start();
    int lastUs = 0;
    double targetClocks = _currentCpuClocks.toDouble();

    _state.running = true;
    debugger.executionStarted();
    _stopRequested = false;
    try {
      while (!_stopRequested) {
        final nowUs = watch.elapsedMicroseconds;
        targetClocks += (nowUs - lastUs) * clocksPerUs;
        lastUs = nowUs;

        if (_currentCpuClocks >= targetClocks) {
          // ahead of the real time
          await Future.delayed(const Duration(milliseconds: 1));
          continue;
        }

        _runFrame();
        fpsCounter.count();
        final fps = fpsCounter.fps(DateTime.now());
        if (fps != null) {
          _fps = fps;
          _fpsStream.add(fps);
        }

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
    } finally {
      _stopRequested = false;
      _state.running = false;
      debugger.executionStopped();
    }
  }

  /// stop emulation
  Future<void> stop() {
    debugger.cancelExecution();
    return _stopExecution();
  }

  Future<void> _stopExecution() async {
    _stopRequested = true;

    while (_state.running) {
      await Future.delayed(const Duration());
    }

    return;
  }

  /// reset emulation. keep run/stop state
  Future<void> reset() async {
    final wasRunning = _state.running;
    await stop();
    _fps = 0.0;
    _fpsStream.add(_fps);
    _currentCpuClocks = _scanline = 0;
    _core.reset();
    debugger.reset();
    _renderAll();
    if (wasRunning) run();
  }

  /// executes emulation during 1 frame
  void _runFrame() {
    final core = _core;
    if (!debugger.needsInstructionLoop) {
      // the core runs the rest of the frame by itself
      final result = core.runFrame(core.scanlinesInFrame - _scanline);
      _currentCpuClocks = result.elapsedClocks;
      if (result.stopped) {
        _scanline = 0;
        _stopRequested = true;
        return;
      }
    } else {
      while (_scanline < core.scanlinesInFrame) {
        if (!_runScanLine()) {
          return;
        }
      }
    }

    _scanline = 0;

    if (debugger.stopAfterFrame) {
      _stopRequested = true;
    }

    _renderAll();
  }

  /// for debugger: executes emulation during 1 scanline
  /// returns false if the emulation is stopped
  bool _runScanLine() {
    bool cpuExecuted = true;
    while (true) {
      if (cpuExecuted && debugger.logEnabled) {
        debugger.recordTrace();
        cpuExecuted = false;
      }

      final result = _core.exec(debugger.stepInstructions);
      debugger.completeTrace(result);
      _currentCpuClocks = result.elapsedClocks;
      if (result.stopped) {
        _stopRequested = true;
        return false;
      }
      cpuExecuted = result.executed(debugger.executionCpuNo);
      if (result.scanlineRendered) _scanline++;
      if (debugger.shouldPause(result, debugStatus.clock)) {
        if (_scanline >= _core.scanlinesInFrame) _scanline = 0;
        _renderAll();
        _stopRequested = true;
        return false;
      }
      if (result.scanlineRendered) break;
    }

    if (debugger.stopAfterLine) {
      if (_scanline >= _core.scanlinesInFrame) _scanline = 0;
      _renderAll();
      _stopRequested = true;
      return false;
    }
    return true;
  }

  void _renderAll() {
    _onImage(_core.imageBuffer());
    debugger.pushStream(frameRendered: true);
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

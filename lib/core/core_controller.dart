// Dart imports:
import 'dart:async';
import 'dart:typed_data';

import 'core.dart';
import 'core_factory.dart';
import 'debugger.dart';
import 'frame_counter.dart';
// Project imports:

import 'pce/pce.dart';
import 'types.dart';

/// A Controller of the emulator core.
/// The external GUI should kick `exec` continuously. then subscribe `controller.*stream`
class CoreController {
  CoreController() {
    setCore("pce");
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

    while (_running) {
      // wait the event loop to be done
      await Future.delayed(const Duration());

      final now = DateTime.now();
      _fps = fpsCounter.fps(now);

      // run emulation until the next frame timing
      if (_currentCpuClocks - initialCpuClocks < nextFrameClocks) {
        runFrame();
        fpsCounter.count();
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
    debugger.debugOption.breakPoint = 0;
    debugger.pushStream();

    _renderAll();
  }

  /// executes emulation with 1 cpu instruction
  void runStep() {
    final result = _core.exec();
    _currentCpuClocks = result.elapsedClocks;

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
      _currentCpuClocks = result.elapsedClocks;

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
    for (int i = 0; i < _core.scanlinesInFrame; i++) {
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
    stop();
    _core.setRom(body);
    reset();
    debugger.pushStream();
  }

  bool isRunning() {
    return _running;
  }

  // screen/audio/fps
  final _imageStream = StreamController<ImageBuffer>();
  final _audioStream = StreamController<AudioBuffer>();
  final _fpsStream = StreamController<double>();

  Stream<ImageBuffer> get imageStream => _imageStream.stream;
  Stream<AudioBuffer> get audioStream => _audioStream.stream;
  Stream<double> get fpsStream => _fpsStream.stream;

  void Function(AudioBuffer) onAudio = (_) {};

  // pad
  final _padUpStream = StreamController<PadButton>.broadcast();
  final _padDownStream = StreamController<PadButton>.broadcast();

  Stream<PadButton> get padUpStream => _padUpStream.stream;
  Stream<PadButton> get padDownStream => _padDownStream.stream;

  void padDown(PadButton k) {
    _padDownStream.add(k);
    _core.padDown(0, k);
  }

  void padUp(PadButton k) {
    _padUpStream.add(k);
    _core.padUp(0, k);
  }

  List<PadButton> get buttons => _core.buttons;
}

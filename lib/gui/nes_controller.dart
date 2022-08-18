// Dart imports:
import 'dart:async';
import 'dart:typed_data';

// Project imports:
import '../core/nes.dart';
import '../util.dart';
import 'debug/trace.dart';

typedef NesPadButton = PadButton;

/// Parameters for debugging features
class DebugOption {
  final bool showDebugView;
  final int breakPoint;
  final bool log;

  DebugOption(
      {this.breakPoint = 0, this.showDebugView = false, this.log = false});

  copyWith({int? breakPoint, bool? showDebugView, bool? log}) => DebugOption(
      breakPoint: breakPoint ?? this.breakPoint,
      showDebugView: showDebugView ?? this.showDebugView,
      log: log ?? this.log);
}

/// A Controller of NES emulator core.
/// The external GUI should kick `exec` continuously. then subscribe `controller.*stream`
class NesController {
  final _emulator = Nes();

  bool _isRunning = true;
  double _fps = 0.0;

  int get apuClock => Nes.apuClock;

  /// runs emulation with 16ms timer
  void run() async {
    var startAt = DateTime.now();
    var nextStartAt = startAt;
    var frames = 0;
    var nextFrames = 0;

    while (_isRunning) {
      await Future.delayed(const Duration(milliseconds: 1));

      // calculate fps
      final now = DateTime.now();
      _fps =
          frames * 1000.0 / now.difference(startAt).inMilliseconds.toDouble();

      if (_fps < 60.1) {
        runFrame();
        frames++;
        nextFrames++;
      }

      // refresh the time range as recent 2 seconds for the next fps calculation
      if (now.difference(nextStartAt).inMilliseconds > 2000) {
        startAt = nextStartAt;
        frames = nextFrames;
        nextStartAt = now;
        nextFrames = 0;
      }
    }
  }

  /// stops emulation
  void stop() {
    _isRunning = false;
  }

  /// executes emulation with 1 cpu instruction
  void runStep() {
    _emulator.exec();
    _renderAll();
  }

  /// executes emulation during 1 scanline
  bool runScanLine({skipRender = false}) {
    int? startCycle;

    while (true) {
      if (debugOption.breakPoint == _emulator.pc) {
        stop();
        return false;
      }

      // exec 1 cpu instruction
      final result = _emulator.exec();

      _tracer?.addLog(_emulator.state);

      if (!result.i1) {
        stop();
        return false;
      }

      final currentCycle = result.i0;

      startCycle ??= currentCycle;

      if (currentCycle - startCycle >= Nes.cpuCyclesInScanline) {
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
    for (int i = 0; i < 261; i++) {
      if (!runScanLine(skipRender: true)) {
        return;
      }
    }
    _renderAll();
  }

  void _renderAll() {
    _imageStream.add(_emulator.ppuBuffer());
    _audioStream.add(_emulator.apuBuffer());
    if (_debugOption.showDebugView) {
      _pushDebug();
    }
    _fpsStream.add(_fps);
  }

  void reset() => _emulator.reset();

  void setRom(Uint8List body) => _emulator.setRom(body);

  // screen/audio/fps

  final _imageStream = StreamController<Uint8List>();
  final _audioStream = StreamController<Float32List>();
  final _fpsStream = StreamController<double>();

  Stream<Uint8List> get imageStream => _imageStream.stream;
  Stream<Float32List> get audioStream => _audioStream.stream;
  Stream<double> get fpsStream => _fpsStream.stream;

  // pad

  final _padUpStream = StreamController<NesPadButton>.broadcast();
  final _padDownStream = StreamController<NesPadButton>.broadcast();

  Stream<NesPadButton> get padUpStream => _padUpStream.stream;
  Stream<NesPadButton> get padDownStream => _padDownStream.stream;

  void padDown(NesPadButton k) {
    _padDownStream.add(k);
    _emulator.padDown(k);
  }

  void padUp(NesPadButton k) {
    _padUpStream.add(k);
    _emulator.padUp(k);
  }

  // interafaces for debugging features

  final _debugStream = StreamController<String>();
  Stream<String> get debugStream => _debugStream.stream;

  DebugOption _debugOption = DebugOption();

  DebugOption get debugOption => _debugOption;

  Trace? _tracer;

  set debugOption(DebugOption opt) {
    _debugOption = opt;
    if (opt.showDebugView) {
      _pushDebug();
    } else {
      _debugStream.add("");
    }

    if (opt.log) {
      _tracer = Trace(_traceStream);
    } else {
      _tracer = null;
    }
  }

  void _pushDebug() {
    _debugStream.add(
        _emulator.dump(showZeroPage: true, showStack: true, showApu: true));
  }

  Uint8List renderChrRom() => _emulator.renderChrRom();
  Pair<String, int> disasm(int addr) => _emulator.disasm(addr);

  final _traceStream = StreamController<String>.broadcast();
  Stream<String> get traceStream => _traceStream.stream;
}

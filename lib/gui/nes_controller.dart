// Dart imports:
import 'dart:async';
import 'dart:typed_data';

// Project imports:
import '../core_pce/pce.dart';
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
  final _emulator = Pce();

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
    _emulator.exec();
    _tracer?.addLog(_emulator.state);
    _renderAll();
  }

  /// executes emulation during 1 scanline
  bool runScanLine({skipRender = false}) {
    while (true) {
      if (debugOption.breakPoint == _emulator.pc) {
        stop();
        return false;
      }

      // exec 1 cpu instruction
      final result = _emulator.exec();

      _tracer?.addLog(_emulator.state);

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
    _imageStream.add(_emulator.ppuBuffer());
    _audioStream.add(_emulator.apuBuffer());
    if (_debugOption.showDebugView) {
      _pushDebug();
    }
    _fpsStream.add(_fps);
  }

  void reset() {
    _emulator.reset();
    _renderAll();
  }

  void setRom(Uint8List body) {
    if (_debugOption.showDebugView) {
      _pushDebug();
    }
    _emulator.setRom(body);
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

    if (opt.log && _tracer == null) {
      _tracer = Trace(_traceStream);
      _traceSubscription = _traceStream.stream.listen((log) {
        print(log.replaceAll("\n", ""));
      }, onDone: () => _traceSubscription?.cancel());
    } else {
      _traceSubscription?.cancel();
      _tracer = null;
    }
  }

  void _pushDebug() {
    _debugStream.add(
        _emulator.dump(showZeroPage: true, showStack: true, showApu: true));
  }

  Pair<String, int> disasm(int addr) => _emulator.disasm(addr);

  final _traceStream = StreamController<String>.broadcast();
  StreamSubscription<String>? _traceSubscription;

  List<int> dumpVram() => _emulator.dumpVram();
  int read(int addr) => _emulator.read(addr);
  List<int> dumpColorTable() => _emulator.dumpColorTable();

  runUntilRts() {
    while (true) {
      _emulator.exec();
      if (_emulator.dump().contains("60        RTS")) {
        break;
      }
    }
    _renderAll();
  }
}

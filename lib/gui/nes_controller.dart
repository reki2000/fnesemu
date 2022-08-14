// Dart imports:
import 'dart:async';
import 'dart:typed_data';

// Project imports:
import '../core/nes.dart';
import '../util.dart';

typedef NesPadButton = PadButton;

/// Parameters for debugging features
class DebugOption {
  final bool showDebugView;
  final int breakPoint;

  DebugOption({this.breakPoint = 0, this.showDebugView = false});

  copyWith({int? breakPoint, bool? showDebugView}) => DebugOption(
      breakPoint: breakPoint ?? this.breakPoint,
      showDebugView: showDebugView ?? this.showDebugView);
}

/// A Controller of NES emulator core.
/// The external GUI should kick `exec` continuously. then subscribe `controller.*stream`
class NesController {
  final _emulator = Nes();

  void dispose() {}

  Timer? _timer;
  double _fps = 0.0;

  DebugOption _debugOption = DebugOption();

  DebugOption get debugOption => _debugOption;

  set debugOption(DebugOption opt) {
    _debugOption = opt;
    if (opt.showDebugView) {
      _pushDebug();
    } else {
      _debugStream.add("");
    }
  }

  void _pushDebug() {
    _debugStream.add(
        _emulator.dump(showZeroPage: true, showStack: true, showApu: true));
  }

  int get apuClock => Nes.apuClock;

  void run() {
    final startAt = DateTime.now();
    var frames = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (_fps <= 60.0) {
        runFrame();
        frames++;
      }
      _fps = frames /
          (DateTime.now().difference(startAt).inMilliseconds.toDouble() /
              1000.0);
    });
  }

  void stop() async {
    _timer?.cancel();
  }

  void runStep() {
    _emulator.exec();
    _renderAll();
  }

  bool runScanLine({skipRender = false}) {
    final result = _emulator.exec();
    if (!result.i1) {
      stop();
      return false;
    }

    final cycleUntil = result.i0 + 114;

    while (true) {
      final result = _emulator.exec();
      if (!result.i1) {
        stop();
        return false;
      }

      final currentCycle = result.i0;
      if (currentCycle >= cycleUntil) {
        break;
      }
    }
    _renderAll();
    return true;
  }

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

  void padDown(NesPadButton k) {
    _padDownStream.add(k);
    _emulator.padDown(k);
  }

  void padUp(NesPadButton k) {
    _padUpStream.add(k);
    _emulator.padUp(k);
  }

  final _imageStream = StreamController<Uint8List>();
  final _audioStream = StreamController<Float32List>();
  final _fpsStream = StreamController<double>();
  final _debugStream = StreamController<String>();

  final _padUpStream = StreamController<NesPadButton>.broadcast();
  final _padDownStream = StreamController<NesPadButton>.broadcast();

  Stream<Uint8List> get imageStream => _imageStream.stream;
  Stream<Float32List> get audioStream => _audioStream.stream;
  Stream<String> get debugStream => _debugStream.stream;
  Stream<double> get fpsStream => _fpsStream.stream;

  Stream<NesPadButton> get padUpStream => _padUpStream.stream;
  Stream<NesPadButton> get padDownStream => _padDownStream.stream;

  Uint8List renderChrRom() => _emulator.renderChrRom();
  Pair<String, int> disasm(int addr) => _emulator.disasm(addr);
}

import 'dart:async';
import 'dart:typed_data';

import '../cpu/nes.dart';
import '../cpu/pad_button.dart';

class NesController {
  final _emulator = Nes();

  Timer? _timer;
  double _fps = 0.0;

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
  }

  void runScanLine() {
    final cycleUntil = _emulator.exec() + 114;
    while (_emulator.exec() < cycleUntil) {}
  }

  void runFrame() {
    for (int i = 0; i < 261; i++) {
      runScanLine();
    }
    _imageStream.add(_emulator.ppuBuffer());
    _audioStream.add(_emulator.apuBuffer());
    _debugStream.add(_emulator.dump(
      showZeroPage: true,
      showStack: true,
      showApu: true,
    ));
    _fpsStream.add(_fps);
  }

  void reset() => _emulator.reset();

  void setRom(Uint8List body) => _emulator.setRom(body);

  void padDown(PadButton k) => _emulator.padDown(k);
  void padUp(PadButton k) => _emulator.padUp(k);

  final _imageStream = StreamController<Uint8List>();
  final _audioStream = StreamController<Float32List>();
  final _fpsStream = StreamController<double>();
  final _debugStream = StreamController<String>();

  Stream<Uint8List> get imageStream => _imageStream.stream;
  Stream<Float32List> get audioStream => _audioStream.stream;
  Stream<String> get debugStream => _debugStream.stream;
  Stream<double> get fpsStream => _fpsStream.stream;
}

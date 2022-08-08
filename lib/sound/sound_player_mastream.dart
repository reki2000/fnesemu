// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import 'ma_stream.dart';
import 'sound_player.dart';

class SoundPlayerImpl extends SoundPlayer {
  static const _outputSampleRate = 44100;
  static const _bufferLength = 1024;

  final _buf = Float32List(_bufferLength);
  int _bufIndex = 0;

  SoundPlayerImpl() {
    MAStream.init();
    log("SoundPlayerMAStream initialized");
  }

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {}

  @override
  void push(Float32List input, int inputSampleRate) {
    final skip = inputSampleRate / _outputSampleRate;
    double index = 0.0;

    while (index < input.length) {
      _buf[_bufIndex++] = input[index.toInt()];
      if (_bufIndex == _buf.length) {
        _bufIndex = 0;
        MAStream.push(_buf);
      }
      index += skip;
    }
  }
}

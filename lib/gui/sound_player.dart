// Dart imports:
import 'dart:typed_data';

// Package imports:
import 'package:mp_audio_stream/mp_audio_stream.dart';

class SoundPlayer {
  static const _outputSampleRate = 44100;
  final _audioStream = getAudioStream()..init(sampleRate: _outputSampleRate);

  static const _bufferLength = 1024;
  final _buf = Float32List(_bufferLength);
  int _bufIndex = 0;

  Future<void> resume() async => _audioStream.resume();

  void dispose() => _audioStream.uninit();

  // resample input buffer (Float32 0.0-1.0 890kHz) to 44.1kHz
  void push(Float32List input, int inputSampleRate) {
    final skip = inputSampleRate / _outputSampleRate;
    double index = 0.0;

    while (index < input.length) {
      _buf[_bufIndex++] = input[index.toInt()];
      if (_bufIndex == _buf.length) {
        _bufIndex = 0;
        _audioStream.push(_buf);
      }
      index += skip;
    }
  }
}

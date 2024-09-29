// Dart imports:
import 'dart:typed_data';

// Package imports:
import 'package:mp_audio_stream/mp_audio_stream.dart';

class SoundPlayer {
  static const _outputSampleRate = 44100;
  static const _channels = 2;
  static const _bufferMilliSec = 200;

  final _audioStream = getAudioStream()
    ..init(
        bufferMilliSec: _bufferMilliSec,
        sampleRate: _outputSampleRate,
        channels: _channels);

  static const _bufferLength = 1024 * _channels;
  final _buf = Float32List(_bufferLength);
  int _bufIndex = 0;

  Future<void> resume() async => _audioStream.resume();

  void dispose() => _audioStream.uninit();

  // resample input buffer (Float32 0.0-1.0 890kHz, 1 or 2 channels) to 44.1kHz
  void push(Float32List input, int inputSampleRate, int inputChannels) {
    double index = 0.0;
    final skip = inputSampleRate / _outputSampleRate;

    if (inputChannels == 1 && _channels == 2) {
      while (index < input.length) {
        final i = index.toInt();

        _buf[_bufIndex++] = input[i];
        _buf[_bufIndex++] = input[i];

        if (_bufIndex == _buf.length) {
          _bufIndex = 0;
          _audioStream.push(_buf);
        }
        index += skip;
      }
    } else if (inputChannels == 2 && _channels == 2) {
      while (index < input.length / _channels) {
        final i = index.toInt() * 2;

        _buf[_bufIndex++] = input[i];
        _buf[_bufIndex++] = input[i + 1];

        if (_bufIndex == _buf.length) {
          _bufIndex = 0;
          _audioStream.push(_buf);
        }
        index += skip;
      }
    }
  }
}

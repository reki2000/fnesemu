import 'dart:typed_data';

import 'package:mp_audio_stream/mp_audio_stream.dart';

class SoundPlayer {
  static const _outputSampleRate = 44100;
  static const _channels = 2;
  static const _bufferMilliSec = 200;

  final AudioStream _audioStream;
  bool _initialized = false;

  SoundPlayer({AudioStream? audioStream})
      : _audioStream = audioStream ?? getAudioStream();

  static const _bufferLength = 1024 * _channels;
  final _buf = Float32List(_bufferLength);
  int _bufIndex = 0;

  Future<void> resume() async {
    if (!_initialized) {
      final result = _audioStream.init(
          bufferMilliSec: _bufferMilliSec,
          sampleRate: _outputSampleRate,
          channels: _channels);
      if (result != 0) throw StateError('Audio initialization failed: $result');
      _initialized = true;
    }
    _audioStream.resume();
  }

  // The stream API has no suspend/flush operation. Closing it stops buffered
  // sound immediately; resume opens a fresh stream at the same sample rate.
  void pause() {
    if (_initialized) _audioStream.uninit();
    _initialized = false;
    _bufIndex = 0;
  }

  void dispose() => pause();

  // resample input buffer (Float32 1 or 2 channels) to 44.1kHz
  void push(Float32List input, int inputSampleRate, int inputChannels) {
    if (!_initialized || input.isEmpty) {
      return;
    }

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

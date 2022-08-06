@JS()
library audio;

// Dart imports:
import 'dart:developer';
import 'dart:js_util';
import 'dart:typed_data';

// Package imports:
import 'package:js/js.dart';

// Project imports:
import 'sound_player.dart';

@JS('resumeAudioContext')
external Object resumeAudioContext();

@JS('pushWaveData')
external Object pushWaveData(Float32List buf);

class SoundPlayerImpl extends SoundPlayer {
  static const _outputSampleRate = 44100;
  static const _bufferLength = 1024;

  final _buf = Float32List(_bufferLength);
  int _bufIndex = 0;

  SoundPlayerImpl() {
    log("SoundPlayerWeb initialized");
  }

  @override
  Future<void> resume() async {
    await promiseToFuture(resumeAudioContext());
  }

  @override
  Future<void> stop() async {}

  // resample input buffer (Float32 0.0-1.0 890kHz) to 44.1kHz
  @override
  void push(Float32List input, int inputSampleRate) {
    final skip = inputSampleRate / _outputSampleRate;
    double index = 0.0;

    while (index < input.length) {
      _buf[_bufIndex++] = input[index.toInt()];
      if (_bufIndex == _buf.length) {
        _bufIndex = 0;
        pushWaveData(_buf);
      }
      index += skip;
    }
  }
}

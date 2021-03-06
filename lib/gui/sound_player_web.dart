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

const sampleRate = 44100;
const bufferLength = 1024;

const clockHz = 1789773;

class SoundPlayerImpl extends SoundPlayer {
  final _buf = Float32List(bufferLength);
  var _bufIndex = 0;

  SoundPlayerImpl() {
    log("SoundPlayerWeb initialized");
  }

  @override
  Future<void> resume() async {
    await promiseToFuture(resumeAudioContext());
  }

  @override
  Future<void> stop() async {}

  // resample input buffer (int8 for every apu cycle = 890kHz) for sampleRate(44100Hz)
  @override
  void push(Float32List buf) {
    const skip = clockHz / 2 / sampleRate;
    var index = 0.0;

    while (index < buf.length) {
      _buf[_bufIndex++] = buf[index.toInt()];
      if (_bufIndex == _buf.length) {
        _bufIndex = 0;
        pushWaveData(_buf);
      }
      index += skip;
    }
  }
}

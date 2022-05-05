import 'dart:typed_data';

import 'sound_player_null.dart' if (dart.library.html) 'sound_player_web.dart';

SoundPlayer getSoundPlayerInstance() => SoundPlayerImpl();

abstract class SoundPlayer {
  Future<void> resume();

  Future<void> stop();

  // resample input buffer (int8 for every apu cycle = 890kHz) for sampleRate(44100Hz)
  void push(Float32List buf);
}

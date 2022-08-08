// Dart imports:
import 'dart:typed_data';

// Project imports:
import 'sound_player_mastream.dart'
    if (dart.library.html) 'sound_player_web.dart';

SoundPlayer getSoundPlayerInstance() => SoundPlayerImpl();

abstract class SoundPlayer {
  Future<void> resume();

  Future<void> stop();

  // -1.0 to 1.0 float32
  void push(Float32List input, int inputSampleRate);
}

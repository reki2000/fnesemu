// Dart imports:
import 'dart:typed_data';

// Project imports:
import 'sound_player_null.dart' if (dart.library.html) 'sound_player_web.dart';

SoundPlayer getSoundPlayerInstance() => SoundPlayerImpl();

abstract class SoundPlayer {
  Future<void> resume();

  Future<void> stop();

  // 0.0-1.0 float32
  void push(Float32List input, int inputSampleRate);
}

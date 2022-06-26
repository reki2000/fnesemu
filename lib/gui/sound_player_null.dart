// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import 'sound_player.dart';

class SoundPlayerImpl extends SoundPlayer {
  SoundPlayerImpl() {
    log("SoundPlayerNull initialized");
  }

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {}

  @override
  void push(Float32List buf) {}
}

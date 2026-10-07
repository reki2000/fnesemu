import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/sound_player.dart';
import 'package:mp_audio_stream/mp_audio_stream.dart';

class FakeAudioStream implements AudioStream {
  int starts = 0, closes = 0, resumes = 0;
  final samples = <Float32List>[];
  @override
  int init(
      {int bufferMilliSec = 3000,
      int waitingBufferMilliSec = 100,
      int channels = 1,
      int sampleRate = 44100,
      bool fadeOnExhaust = false}) {
    starts++;
    return 0;
  }

  @override
  void uninit() => closes++;
  @override
  void resume() => resumes++;
  @override
  int push(Float32List buffer) {
    samples.add(Float32List.fromList(buffer));
    return 0;
  }

  @override
  AudioStreamStat stat() => AudioStreamStat.empty();
  @override
  void resetStat() {}
}

void main() {
  test(
      'pause stops the stream, drops pending audio, and resume restarts cleanly',
      () async {
    final stream = FakeAudioStream();
    final player = SoundPlayer(audioStream: stream);
    player.push(Float32List(2048), 44100, 2);
    expect(stream.samples, isEmpty);
    await player.resume();
    player.push(Float32List(1024)..fillRange(0, 1024, 0.5), 44100, 2);
    player.pause();
    player.push(Float32List(2048), 44100, 2);
    expect(stream.closes, 1);
    expect(stream.samples, isEmpty);
    await player.resume();
    player.push(Float32List(2048)..fillRange(0, 2048, 0.25), 44100, 2);
    expect(stream.starts, 2);
    expect(stream.samples.single.every((v) => v == 0.25), isTrue);
    player.dispose();
    expect(stream.closes, 2);
  });
}

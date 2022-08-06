// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import 'package:just_audio/just_audio.dart';

SoundPlayer getSoundPlayerInstance() => SoundPlayer();

class _Source extends StreamAudioSource {
  List<int> bytes = List<int>.empty(growable: true);

  void push(List<int> buf) {
    bytes.addAll(buf);
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    log("start:$start end:$end");
    start ??= 0;
    end ??= bytes.length;
    final content = bytes.sublist(start, end);
    bytes = bytes.sublist(end, bytes.length);

    return StreamAudioResponse(
      sourceLength: null,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(content),
      contentType: 'audio/raw',
    );
  }
}

class SoundPlayer {
  static const _outputSampleRate = 44100;
  static const _bufferLength = 1024 * 10;

  final _player = AudioPlayer();
  late final _Source _source;

  final _buf = List.filled(_bufferLength, 0);
  int _bufIndex = 0;

  SoundPlayer() {
    _source = _Source();
    _player.setAudioSource(_source);
  }

  Future<void> resume() async {
    await _player.play();
  }

  Future<void> stop() async {
    await _player.stop();
  }

  // 0.0-1.0 float32
  void push(Float32List input, int inputSampleRate) {
    final skip = inputSampleRate / _outputSampleRate;
    double index = 0.0;

    while (index < input.length) {
      _buf[_bufIndex++] = (input[index.toInt()] * 255).toInt();
      if (_bufIndex == _buf.length) {
        _bufIndex = 0;
        _source.push(_buf);
      }
      index += skip;
    }
  }
}

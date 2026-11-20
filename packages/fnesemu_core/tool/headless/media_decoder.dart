// The MediaDecoder of the headless tools: the decoders of mp_media_decoder.
import 'dart:typed_data';

import 'package:fnesemu_core/src/media_decoder.dart';
import 'package:mp_media_decoder/mp_media_decoder.dart' as mmd;

/// The decoders of this machine; codecs without one stay unsupported.
MediaDecoder openMediaDecoder() => _MediaDecoder(mmd.MediaDecoders.open());

class _MediaDecoder implements MediaDecoder {
  _MediaDecoder(this._decoders);

  final mmd.MediaDecoders _decoders;
  final _video = <int, mmd.VideoDecoder>{};
  final _audio = <int, mmd.AudioDecoder>{};

  @override
  String get name => _decoders.name;

  @override
  bool supports(MediaCodec codec) => switch (codec) {
        MediaCodec.h264 => _decoders.supportsH264,
        MediaCodec.atrac3plus => _decoders.supportsAtrac3plus,
      };

  @override
  bool open(int id, MediaCodec codec,
      {int sampleRate = 44100, int channels = 2, int blockAlign = 0}) {
    close(id);
    switch (codec) {
      case MediaCodec.h264:
        final decoder = _decoders.openH264();
        if (decoder == null) return false;
        _video[id] = decoder;
      case MediaCodec.atrac3plus:
        final decoder = _decoders.openAtrac3plus(
            sampleRate: sampleRate, channels: channels, blockAlign: blockAlign);
        if (decoder == null) return false;
        _audio[id] = decoder;
    }
    return true;
  }

  @override
  MediaPicture? decodeVideo(int id, Uint8List unit) {
    final picture = _video[id]?.decode(unit);
    return picture == null
        ? null
        : MediaPicture(picture.width, picture.height, picture.pixels);
  }

  @override
  Int16List? decodeAudio(int id, Uint8List frame) =>
      _audio[id]?.decode(frame);

  @override
  void flush(int id) {
    _video[id]?.flush();
    _audio[id]?.flush();
  }

  @override
  void close(int id) {
    _video.remove(id)?.close();
    _audio.remove(id)?.close();
  }
}

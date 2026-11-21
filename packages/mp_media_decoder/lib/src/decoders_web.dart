import 'types.dart';

/// The decoders of the Web: none yet, so every codec is unsupported.
class MediaDecoders {
  MediaDecoders._();

  static MediaDecoders open() => MediaDecoders._();

  String get name => 'none';

  bool get supportsH264 => false;

  bool get supportsAtrac3plus => false;

  VideoDecoder? openH264() => null;

  AudioDecoder? openAtrac3plus(
          {int sampleRate = 44100, int channels = 2, required int blockAlign}) =>
      null;
}

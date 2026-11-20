import 'dart:io';

import 'libavcodec.dart';
import 'types.dart';

/// The decoders of this platform: ATRAC3plus through a shared libavcodec,
/// and H.264 through the decoder of the operating system. Linux has no
/// decoder of its own, so it decodes H.264 with libavcodec as well.
class MediaDecoders {
  MediaDecoders._(this._avcodec);

  final LibAvcodec? _avcodec;

  /// Finds the decoders of this platform. Each codec that has none stays
  /// unsupported.
  static MediaDecoders open() => MediaDecoders._(LibAvcodec.load());

  /// the decoders in use, for the GUI
  String get name {
    final parts = [
      if (_h264Backend != null) 'H.264: $_h264Backend',
      if (supportsAtrac3plus) 'ATRAC3plus: ${_avcodec!.name}',
    ];
    return parts.isEmpty ? 'none' : parts.join(', ');
  }

  String? get _h264Backend {
    if (Platform.isLinux && _avcodec != null && _avcodec.has('h264')) {
      return _avcodec.name;
    }
    // TODO: MediaCodec (Android), VideoToolbox (macOS, iOS) and Media
    // Foundation (Windows)
    return null;
  }

  bool get supportsH264 => _h264Backend != null;

  bool get supportsAtrac3plus => _avcodec?.has('atrac3plus') ?? false;

  /// An H.264 decoder; null when the platform has none.
  VideoDecoder? openH264() =>
      Platform.isLinux ? _avcodec?.openH264() : null;

  /// An ATRAC3plus decoder for frames of [blockAlign] bytes; null when
  /// there is no libavcodec with it.
  AudioDecoder? openAtrac3plus(
          {int sampleRate = 44100, int channels = 2, required int blockAlign}) =>
      _avcodec?.openAtrac3plus(
          sampleRate: sampleRate, channels: channels, blockAlign: blockAlign);
}

import 'dart:io';

import 'gstreamer.dart';
import 'libavcodec.dart';
import 'types.dart';

/// The decoders of this platform: H.264 through the decoder of the
/// operating system (GStreamer on Linux), and ATRAC3plus through a shared
/// libavcodec under the LGPL.
class MediaDecoders {
  MediaDecoders._(this._avcodec, this._gstreamer);

  final LibAvcodec? _avcodec;
  final GStreamer? _gstreamer;

  /// Finds the decoders of this platform. Each codec that has none stays
  /// unsupported.
  static MediaDecoders open() => MediaDecoders._(
      LibAvcodec.load(), Platform.isLinux ? GStreamer.load() : null);

  /// the decoders in use, for the GUI
  String get name {
    final parts = [
      if (supportsH264) 'H.264: GStreamer',
      if (supportsAtrac3plus) 'ATRAC3plus: ${_avcodec!.name}',
    ];
    return parts.isEmpty ? 'none' : parts.join(', ');
  }

  // TODO: MediaCodec (Android), VideoToolbox (macOS, iOS) and Media
  // Foundation (Windows)
  bool get supportsH264 => _gstreamer?.hasH264 ?? false;

  bool get supportsAtrac3plus => _avcodec?.has('atrac3plus') ?? false;

  /// An H.264 decoder; null when the platform has none.
  VideoDecoder? openH264() => _gstreamer?.openH264();

  /// An ATRAC3plus decoder for frames of [blockAlign] bytes; null when
  /// there is no libavcodec with it.
  AudioDecoder? openAtrac3plus(
          {int sampleRate = 44100, int channels = 2, required int blockAlign}) =>
      _avcodec?.openAtrac3plus(
          sampleRate: sampleRate, channels: channels, blockAlign: blockAlign);
}

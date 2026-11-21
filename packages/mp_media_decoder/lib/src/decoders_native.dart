import 'dart:io';

import 'gstreamer.dart';
import 'libavcodec.dart';
import 'media_foundation.dart';
import 'types.dart';

/// The decoders of this platform: H.264 through the decoder of the
/// operating system (GStreamer on Linux, Media Foundation on Windows), and
/// ATRAC3plus through a shared libavcodec under the LGPL.
class MediaDecoders {
  MediaDecoders._(this._avcodec, this._h264, this._h264Name);

  final LibAvcodec? _avcodec;
  final VideoDecoder? Function()? _h264;
  final String _h264Name;

  /// Finds the decoders of this platform. Each codec that has none stays
  /// unsupported.
  static MediaDecoders open() {
    final avcodec = LibAvcodec.load();
    if (Platform.isLinux) {
      final gst = GStreamer.load();
      return MediaDecoders._(avcodec,
          gst != null && gst.hasH264 ? gst.openH264 : null, 'GStreamer');
    }
    if (Platform.isWindows) {
      return MediaDecoders._(
          avcodec, MediaFoundation.load()?.openH264, 'Media Foundation');
    }
    return MediaDecoders._(avcodec, null, '');
  }

  /// the decoders in use, for the GUI
  String get name {
    final parts = [
      if (supportsH264) 'H.264: $_h264Name',
      if (supportsAtrac3plus) 'ATRAC3plus: ${_avcodec!.name}',
    ];
    return parts.isEmpty ? 'none' : parts.join(', ');
  }

  bool get supportsH264 => _h264 != null;

  bool get supportsAtrac3plus => _avcodec?.has('atrac3plus') ?? false;

  /// An H.264 decoder; null when the platform has none.
  VideoDecoder? openH264() => _h264?.call();

  /// An ATRAC3plus decoder for frames of [blockAlign] bytes; null when
  /// there is no libavcodec with it.
  AudioDecoder? openAtrac3plus(
          {int sampleRate = 44100, int channels = 2, required int blockAlign}) =>
      _avcodec?.openAtrac3plus(
          sampleRate: sampleRate, channels: channels, blockAlign: blockAlign);
}

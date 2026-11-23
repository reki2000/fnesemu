import 'dart:io';
import 'dart:typed_data';

import 'gstreamer.dart';
import 'libavcodec.dart';
import 'media_codec.dart';
import 'media_foundation.dart';
import 'types.dart';
import 'videotoolbox.dart';

/// The decoders of this platform: H.264 through the decoder of the
/// operating system (GStreamer on Linux, Media Foundation on Windows,
/// MediaCodec on Android, VideoToolbox on macOS and iOS), and ATRAC3 and
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
    if (Platform.isAndroid) {
      return MediaDecoders._(
          avcodec, MediaCodecLibrary.load()?.openH264, 'MediaCodec');
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return MediaDecoders._(avcodec, VideoToolbox.openH264, 'VideoToolbox');
    }
    return MediaDecoders._(avcodec, null, '');
  }

  /// the decoders in use, for the GUI
  String get name {
    final parts = [
      if (supportsH264) 'H.264: $_h264Name',
      if (supportsAtrac3plus) 'ATRAC3plus: ${_avcodec!.name}',
      if (supportsAtrac3) 'ATRAC3: ${_avcodec!.name}',
    ];
    return parts.isEmpty ? 'none' : parts.join(', ');
  }

  bool get supportsH264 => _h264 != null;

  bool get supportsAtrac3plus => _avcodec?.has('atrac3plus') ?? false;

  /// ATRAC3 needs mmd_libav, which passes the codec data to the decoder.
  bool get supportsAtrac3 =>
      (_avcodec?.takesCodecData ?? false) && _avcodec!.has('atrac3');

  /// An H.264 decoder; null when the platform has none.
  VideoDecoder? openH264() => _h264?.call();

  /// An ATRAC3plus decoder for frames of [blockAlign] bytes; null when
  /// there is no libavcodec with it.
  AudioDecoder? openAtrac3plus(
          {int sampleRate = 44100, int channels = 2, required int blockAlign}) =>
      _avcodec?.openAtrac3plus(
          sampleRate: sampleRate, channels: channels, blockAlign: blockAlign);

  /// An ATRAC3 decoder for frames of [blockAlign] bytes with the codec data
  /// of the stream (the 14-byte format extension of a WAVE file); null when
  /// there is no mmd_libav with it.
  AudioDecoder? openAtrac3(
          {int sampleRate = 44100,
          int channels = 2,
          required int blockAlign,
          required Uint8List codecData}) =>
      _avcodec?.openAtrac3(
          sampleRate: sampleRate,
          channels: channels,
          blockAlign: blockAlign,
          codecData: codecData);
}

import 'dart:typed_data';

/// The codecs that a [MediaDecoder] may decode.
enum MediaCodec {
  /// H.264 video. Each call passes one access unit as an Annex B byte
  /// stream (start codes before the NAL units).
  h264,

  /// ATRAC3plus audio. Each call passes one frame of the block size given
  /// when the stream opens.
  atrac3plus,
}

/// A decoded picture: [width] by [height] pixels, one RGBA pixel per
/// element as in an `ImageBuffer`, rows [width] elements apart.
class MediaPicture {
  const MediaPicture(this.width, this.height, this.pixels);

  final int width;
  final int height;
  final Uint32List pixels;
}

/// Decodes the compressed video and audio that a guest plays, such as the
/// movies and the music of a disc. A core opens a stream under an id of its
/// own choice, the media id, and passes the stream's units in order. The
/// app sets the decoder as `Core.mediaDecoder`; a core without one, or
/// with a decoder that does not support a codec, plays such media without
/// a picture or sound.
abstract interface class MediaDecoder {
  /// the decoders, for the GUI
  String get name;

  /// Whether [open] can open a stream of [codec].
  bool supports(MediaCodec codec);

  /// Opens the stream [id] of [codec], closing a stream already open under
  /// [id]. An audio stream has [sampleRate], [channels] and [blockAlign],
  /// the bytes of a frame. Returns false if the stream cannot be opened.
  bool open(int id, MediaCodec codec,
      {int sampleRate = 44100, int channels = 2, int blockAlign = 0});

  /// Passes one access unit of the video stream [id] and returns the
  /// latest picture that the decoder has finished, which may belong to an
  /// earlier unit; null while it has none.
  MediaPicture? decodeVideo(int id, Uint8List unit);

  /// Decodes one frame of the audio stream [id] into interleaved 16-bit
  /// samples; null when the frame gives none.
  Int16List? decodeAudio(int id, Uint8List frame);

  /// Drops the units of stream [id] in flight, as at a seek.
  void flush(int id);

  /// Closes stream [id].
  void close(int id);
}

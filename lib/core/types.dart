import 'dart:typed_data';

class ImageBuffer {
  final int width;
  final int height;
  final Uint8List buffer;

  const ImageBuffer(this.width, this.height, this.buffer);

  factory ImageBuffer.empty() => ImageBuffer(0, 0, Uint8List(0));
}

class AudioBuffer {
  final int sampleRate;
  final int channels;
  final Float32List buffer; // channel interleaved

  const AudioBuffer(this.sampleRate, this.channels, this.buffer);
}

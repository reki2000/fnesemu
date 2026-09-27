import 'dart:typed_data';

class ImageBuffer {
  final int width;
  final int height;
  final Uint8List buffer;
  final int displayWidth;

  const ImageBuffer(this.width, this.height, this.buffer, {int? displayWidth_})
      : displayWidth = displayWidth_ ?? width;

  factory ImageBuffer.empty() => ImageBuffer(0, 0, Uint8List(0));
}

class AudioBuffer {
  final int sampleRate;
  final int channels;
  final Float32List buffer; // channel interleaved

  const AudioBuffer(this.sampleRate, this.channels, this.buffer);
}

class ExecResult {
  int elapsedClocks;
  bool stopped;
  bool scanlineRendered;

  bool executed0 = true;
  bool executed1 = false;
  bool executed2 = false;
  Map<int, bool>? _additionalExecuted;

  void setExecuted(int cpuNo, bool value) {
    switch (cpuNo) {
      case 0:
        executed0 = value;
      case 1:
        executed1 = value;
      case 2:
        executed2 = value;
      default:
        (_additionalExecuted ??= <int, bool>{})[cpuNo] = value;
    }
  }

  ExecResult(
    this.elapsedClocks,
    this.stopped,
    this.scanlineRendered,
  );

  bool executed(int i) => switch (i) {
        0 => executed0,
        1 => executed1,
        2 => executed2,
        _ => _additionalExecuted?[i] ?? false,
      };
}

class CpuInfo {
  final int no;
  final String name;
  final int pcBitWidth;

  final int traceDiffs;

  const CpuInfo(this.no, this.name, this.pcBitWidth, {this.traceDiffs = 0});

  CpuInfo.ofM68(int no, String name) : this(no, name, 24, traceDiffs: 4);
  CpuInfo.ofZ80(int no, String name) : this(no, name, 16, traceDiffs: 2);
  CpuInfo.of6502(int no, String name) : this(no, name, 16, traceDiffs: 2);
  CpuInfo.ofR3000(int no, String name) : this(no, name, 32, traceDiffs: 4);
}

class TraceLog {
  final int pc, cycle, frame, scanline;
  final String disasm, regs;
  final List<int> state;

  const TraceLog(this.pc, this.cycle, this.disasm, this.regs, this.state,
      {this.frame = 0, this.scanline = 0});
}

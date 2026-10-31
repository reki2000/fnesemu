import 'dart:typed_data';

import '../../state.dart';
import 'fault.dart';
import 'vram_pages.dart';

/// Functional YUV420/422 macroblock input, System Architecture §§3.8.1 and 8.4.3.
/// Half-block commits are synchronous; FIFO occupancy and physical latency are pending.
class DcGpuYuv {
  DcGpuYuv(this.memory, {required this.onNormal});
  final Uint8List memory;
  late final _pages = DcVramPages.of(memory);
  final void Function(int) onNormal;
  final _input = Uint8List(512);
  int _base = 0, _control = 0, _count = 0, _position = 0;
  bool _frameComplete = false;
  int get inputBytes => _position;
  int get completedBlocks => _count;
  int get _columns => (_control & 63) + 1;
  int get _rows => ((_control >> 8) & 63) + 1;
  bool get _separate => _control & 0x10000 != 0;
  bool get _form422 => _control & 0x1000000 != 0;

  void saveState(StateWriter writer) {
    writer.section('dc.gpu.yuv');
    writer.ints([memory.length, _base, _control, _count, _position]);
    writer.boolean(_frameComplete);
    writer.bytes(_input);
  }

  void loadState(StateReader reader) {
    reader.section('dc.gpu.yuv');
    final v = reader.ints();
    final complete = reader.boolean(), input = reader.bytes();
    if (v.length != 5 ||
        v.any((value) => value < 0) ||
        v[0] != memory.length ||
        v[1] & ~0xfffff8 != 0 ||
        v[2] & ~0x1013f3f != 0 ||
        v[3] > 4096 ||
        v[4] & 31 != 0 ||
        v[4] >= (v[2] & 0x1000000 != 0 ? 512 : 384) ||
        input.length != 512) {
      throw const StateMismatch('GPU YUV input state');
    }
    final columns = (v[2] & 63) + 1, rows = ((v[2] >> 8) & 63) + 1;
    if ((complete && (v[3] == 0 || v[4] != 0)) ||
        (!complete && v[3] >= columns * rows)) {
      throw const StateMismatch('GPU YUV frame state');
    }
    _base = v[1];
    _control = v[2];
    _count = v[3];
    _position = v[4];
    _frameComplete = complete;
    _input.setAll(0, input);
  }

  void reset() {
    _base = _control = _count = _position = 0;
    _frameComplete = false;
    _input.fillRange(0, _input.length, 0);
  }

  int read(int offset) => switch (offset) {
        0x148 => _base,
        0x14c => _control,
        0x150 => _count,
        _ => throw const DcUnsupported('unimplemented YUV converter register'),
      };

  void write(int offset, int value) {
    switch (offset) {
      case 0x148:
        _base = value & 0xfffff8;
        _count = _position = 0;
        _frameComplete = false;
      case 0x14c:
        if (_position != 0 || (_count != 0 && !_frameComplete)) {
          throw const DcUnsupported('YUV control changed during a frame');
        }
        final control = value & 0x1013f3f;
        // The game requests a 320x240 conversion window (20x15 blocks).
        // The register table lists power-of-two texture heights, but section
        // 3.8.1 describes conversion by the programmed macroblock counts.
        // Provisionally permit partial texture windows with that linear layout.
        _control = control;
      case 0x150:
        return;
      default:
        throw const DcUnsupported('unimplemented YUV converter register');
    }
  }

  void accept(Uint8List bytes) {
    if (bytes.length != 32) {
      throw const DcUnsupported('YUV input requires a 32-byte burst');
    }
    if (_frameComplete) {
      _count = 0;
      _frameComplete = false;
    }
    final previous = _position, length = _form422 ? 512 : 384;
    _input.setRange(_position, _position + 32, bytes);
    _position += 32;
    try {
      if (_position == 256) _commitHalf(0);
      if (_position == length) _commitHalf(8);
    } on DcUnsupported {
      _position = previous;
      rethrow;
    }
    if (_position != length) return;
    _position = 0;
    _count++;
    if (_count == _columns * _rows) {
      // Keep the completed count visible until the next frame's first burst.
      // The manual specifies address restart but not the counter's reset phase.
      _frameComplete = true;
      onNormal(1 << 6);
    }
  }

  void _commitHalf(int firstRow) {
    final writes = <(int, int)>[];
    final pitch = _separate ? 32 : _columns * 32;
    final blockBase = _base +
        (_separate
            ? _count * 512
            : (_count ~/ _columns) * 16 * pitch + (_count % _columns) * 32);
    for (var y = firstRow; y < firstRow + 8; y++) {
      for (var x = 0; x < 16; x++) {
        final uvBase = _form422 ? (y ~/ 8) * 256 : 0;
        final uvRow = _form422 ? y & 7 : y ~/ 2;
        final uv = uvBase + uvRow * 8 + (x ~/ 2) + (x.isOdd ? 64 : 0);
        final luma = _form422
            ? uvBase + 128 + (x ~/ 8) * 64 + (y & 7) * 8 + (x & 7)
            : 128 + ((y ~/ 8) * 2 + (x ~/ 8)) * 64 + (y & 7) * 8 + (x & 7);
        final address = blockBase + y * pitch + x * 2;
        for (final (delta, value) in [(0, _input[uv]), (1, _input[luma])]) {
          final target = address + delta;
          if (target < 0 || target >= memory.length) {
            throw const DcUnsupported('YUV output exceeds retail VRAM');
          }
          final offset =
              (target & 3) | ((target >> 1) & 0x3ffffc) | ((target & 4) << 20);
          writes.add((offset, value));
        }
      }
    }
    // Validate the complete half before committing any of its VRAM bytes.
    for (final (address, value) in writes) {
      _pages.mark(address);
      memory[address] = value;
    }
  }
}

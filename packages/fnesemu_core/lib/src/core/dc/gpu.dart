import 'dart:typed_data';

import '../../state.dart';
import '../../types.dart';
import '../../util/int.dart';
import 'fault.dart';
import 'gpu_palette.dart';
import 'gpu_render.dart';
import 'gpu_yuv.dart';
import 'spg.dart';
import 'ta.dart';

/// GPU texture memory addressing and functional framebuffer readout.
/// SPG supplies field timing; TA and CORE share the physical VRAM display lists.
class DcGpu {
  DcGpu() {
    spg.onFieldEnd = _finishField;
    spg.onScanPosition = _scanLine;
  }
  final spg = DcSpg();
  void Function(int)? onNormal, onError;
  late final ta = DcTa(vram,
      onNormal: (sources) => onNormal?.call(sources),
      onError: (sources) => onError?.call(sources));
  late final yuv =
      DcGpuYuv(vram, onNormal: (sources) => onNormal?.call(sources));
  final palette = DcGpuPalette();
  final _memoryTiming = Uint32List.fromList([0x20, 0, 0x15f28997, 0x90639]);
  late final render =
      DcGpuRender(vram, palette, onNormal: (sources) => onNormal?.call(sources))
        ..reset()
        ..displayReadControl = () => _readControl;

  void _saveComponents(StateWriter writer) {
    spg.saveState(writer);
    palette.saveState(writer);
    yuv.saveState(writer);
    ta.saveState(writer);
    render.saveState(writer);
  }

  void _loadComponents(StateReader reader) {
    spg.loadState(reader);
    palette.loadState(reader);
    yuv.loadState(reader);
    ta.loadState(reader);
    render.loadState(reader);
  }

  void _saveImage(StateWriter writer, ImageBuffer image) {
    writer.ints([
      image.width,
      image.height,
      image.displayWidth,
      image.displayHeight ?? -1
    ]);
    writer.ints(image.buffer);
  }

  ImageBuffer _loadImage(StateReader reader) {
    final dimensions = reader.ints(), pixels = reader.ints();
    if (dimensions.length != 4 ||
        dimensions[0] < 0 ||
        dimensions[0] > 2048 ||
        dimensions[1] < 0 ||
        dimensions[1] > 4096 ||
        dimensions[2] < 0 ||
        dimensions[2] > 4096 ||
        dimensions[3] < -1 ||
        dimensions[3] > 4096 ||
        dimensions[0] * dimensions[1] != pixels.length ||
        pixels.any((pixel) => pixel < 0 || pixel > 0xffffffff)) {
      throw const StateMismatch('GPU scanout image state');
    }
    return ImageBuffer(
        dimensions[0], dimensions[1], Uint32List.fromList(pixels),
        displayWidth_: dimensions[2],
        displayHeight: dimensions[3] < 0 ? null : dimensions[3]);
  }

  void saveState(StateWriter writer) {
    writer.section('dc.gpu');
    writer.bytes(vram);
    writer.bytes(_linearModes);
    writer.ints([
      _reset,
      _border,
      _readControl,
      _sof1,
      _sof2,
      _size,
      _videoControl,
      _scanStartY,
      _startY,
      _activeSof1,
      _activeSof2,
      ..._memoryTiming
    ]);
    _saveImage(writer, _presented);
    writer.boolean(_scanning != null);
    if (_scanning != null) _saveImage(writer, _scanning!);
    _saveComponents(writer);
  }

  void _readState(StateReader reader) {
    reader.section('dc.gpu');
    final memory = reader.bytes(), modes = reader.bytes(), v = reader.ints();
    final presented = _loadImage(reader);
    final scanning = reader.boolean() ? _loadImage(reader) : null;
    if (memory.length != vramSize ||
        modes.length != 2 ||
        modes.any((value) => value > 1) ||
        v.length != 15 ||
        v.any((value) => value < 0) ||
        v[0] > 7 ||
        v[1] & ~0x1ffffff != 0 ||
        v[2] & ~0xffff7f != 0 ||
        (v[2] & 0x400000 != 0 &&
            (v[2] & 0x3f0000 == 0 || v[2] & 0x10000 != 0)) ||
        v[3] & ~0xfffffc != 0 ||
        v[4] & ~0xfffffc != 0 ||
        v[5] & ~0x3fffffff != 0 ||
        v[6] & ~0x3f01ff != 0 ||
        v[6] & 0xf0 > 0x30 ||
        v[7] > 1023 ||
        v[8] & ~0x03ff03ff != 0 ||
        v[9] & ~0xfffffc != 0 ||
        v[10] & ~0xfffffc != 0 ||
        v[11] & ~255 != 0 ||
        v[12] & ~0x3fffff != 0 ||
        v[13] & ~0x1fffffff != 0 ||
        v[14] & ~0xf7f3f != 0) {
      throw const StateMismatch('GPU memory or scanout controls');
    }
    _loadComponents(reader);
    vram.setAll(0, memory);
    _linearModes.setAll(0, modes);
    _reset = v[0];
    _border = v[1];
    _readControl = v[2];
    _sof1 = v[3];
    _sof2 = v[4];
    _size = v[5];
    _videoControl = v[6];
    _scanStartY = v[7];
    _startY = v[8];
    _activeSof1 = v[9];
    _activeSof2 = v[10];
    _memoryTiming.setAll(0, v.sublist(11));
    _presented = presented;
    _scanning = scanning;
  }

  void loadState(StateReader reader) {
    // Validate the complete graph without advancing any destination device.
    final staged = DcGpu().._readState(reader);
    final writer = StateWriter('dc.gpu.transfer', 1, 0);
    staged._saveComponents(writer);
    final components = StateReader(writer.take(), 'dc.gpu.transfer', 1, 0);
    _loadComponents(components);
    components.end();
    vram.setAll(0, staged.vram);
    _linearModes.setAll(0, staged._linearModes);
    _memoryTiming.setAll(0, staged._memoryTiming);
    _reset = staged._reset;
    _border = staged._border;
    _readControl = staged._readControl;
    _sof1 = staged._sof1;
    _sof2 = staged._sof2;
    _size = staged._size;
    _videoControl = staged._videoControl;
    _scanStartY = staged._scanStartY;
    _startY = staged._startY;
    _activeSof1 = staged._activeSof1;
    _activeSof2 = staged._activeSof2;
    _presented = staged._presented;
    _scanning = staged._scanning;
  }

  static bool polygonFifo(int address) {
    address &= 0xffffffff;
    if (address >= 0xc0000000) return false;
    final physical = address & 0x1dffffff;
    return physical >= 0x10000000 && physical < 0x10800000;
  }

  static bool yuvFifo(int address) {
    address &= 0xffffffff;
    if (address >= 0xc0000000) return false;
    final physical = address & 0x1dffffff;
    return physical >= 0x10800000 && physical < 0x11000000;
  }

  void writeYuv(Uint8List bytes) {
    if (_reset & 5 != 0) {
      throw const DcUnsupported('TA or SDRAM interface is held in reset');
    }
    yuv.accept(bytes);
  }

  final _linearModes = Uint8List(2);

  static bool textureFifo(int address) {
    address &= 0xffffffff;
    if (address >= 0xc0000000) return false;
    final physical = address & 0x1fffffff;
    return (physical >= 0x11000000 && physical < 0x12000000) ||
        (physical >= 0x13000000 && physical < 0x14000000);
  }

  int readFifoRegister(int offset, int size) {
    if (size != 4 || offset & 3 != 0) {
      throw const DcUnsupported(
          'TA interface registers require aligned longwords');
    }
    return offset == 0x80 ? 8 : _linearModes[(offset - 0x84) ~/ 4];
  }

  void writeFifoRegister(int offset, int size, int value) {
    if (size != 4 || offset & 3 != 0) {
      throw const DcUnsupported(
          'TA interface registers require aligned longwords');
    }
    if (offset != 0x80) _linearModes[(offset - 0x84) ~/ 4] = value & 1;
  }

  void writeTexture(int address, Uint8List bytes) {
    if (!textureFifo(address) || bytes.length != 32 || address & 31 != 0) {
      throw const DcUnsupported(
          'Direct Texture Path requires an aligned 32-byte burst');
    }
    if (_reset & 5 != 0) {
      throw const DcUnsupported('TA or SDRAM interface is held in reset');
    }
    final select = (address >> 25) & 1;
    final aperture = _linearModes[select] != 0 ? 0x05000000 : 0x04000000;
    writeMemory(aperture | (address & 0x7fffff), bytes);
  }

  void writePolygon(Uint8List bytes) {
    if (_reset & 5 != 0) {
      throw const DcUnsupported('TA or SDRAM interface is held in reset');
    }
    ta.accept(bytes);
  }

  ImageBuffer _presented = ImageBuffer.empty();
  ImageBuffer? _scanning;
  int _scanStartY = 0;
  int _startY = 0x00150015;
  int _activeSof1 = 0, _activeSof2 = 0;
  ImageBuffer get presentedImage => _presented;

  void _finishField(bool field2) {
    final field = _scanning ?? ImageBuffer.empty();
    _scanning = null;
    if (!spg.interlaced || field.buffer.isEmpty) {
      _presented = field;
    } else {
      final pixels = Uint32List(field.width * field.height * 2)
        ..fillRange(0, field.width * field.height * 2, 0xff000000);
      if (_presented.width == field.width &&
          _presented.height == field.height * 2) {
        pixels.setAll(0, _presented.buffer);
      }
      for (var y = 0; y < field.height; y++) {
        final target = (y * 2 + (field2 ? 1 : 0)) * field.width;
        pixels.setRange(
            target, target + field.width, field.buffer, y * field.width);
      }
      _presented = ImageBuffer(field.width, field.height * 2, pixels,
          displayWidth_: field.displayWidth,
          displayHeight: (field.displayHeight ?? field.height) * 2);
    }
    _activeSof1 = _sof1;
    _activeSof2 = _sof2;
  }

  static const vramSize = 0x800000;
  final vram = Uint8List(vramSize);
  int _reset = 7, _border = 0, _readControl = 0;
  int _sof1 = 0, _sof2 = 0, _size = 0, _videoControl = 0x108;

  /// Storage uses the 32-bit aperture's two contiguous 4 MiB banks.
  static int? vramOffset(int address) {
    address = address.mask32;
    if (address >= 0xc0000000) return null;
    final physical = address & 0x1dffffff;
    if (physical >= 0x05000000 && physical < 0x06000000) {
      return physical & 0x7fffff;
    }
    if (physical >= 0x04000000 && physical < 0x05000000) {
      final offset = physical & 0x7fffff;
      return (offset & 3) | ((offset >> 1) & 0x3ffffc) | ((offset & 4) << 20);
    }
    return null;
  }

  void validateTransfer(int size) {
    // Eight-byte SH4 transfers are two consecutive longword bus accesses.
    if (![2, 4, 8, 32].contains(size)) {
      throw DcUnsupported('GPU VRAM bus requires word/longword/burst access');
    }
  }

  Uint8List readMemory(int address, int size, {bool peek = false}) {
    if (!peek) validateTransfer(size);
    return Uint8List.fromList(
        [for (var i = 0; i < size; i++) vram[vramOffset(address + i)!]]);
  }

  void writeMemory(int address, Uint8List values) {
    validateTransfer(values.length);
    for (var i = 0; i < values.length; i++) {
      vram[vramOffset(address + i)!] = values[i];
    }
  }

  void reset({bool clearMemory = false}) {
    spg.reset();
    _linearModes.fillRange(0, 2, 0);
    palette.reset(clearMemory: clearMemory);
    ta.reset();
    yuv.reset();
    render.reset();
    _presented = ImageBuffer.empty();
    _scanning = null;
    _scanStartY = 0;
    _startY = 0x00150015;
    _activeSof1 = _activeSof2 = 0;
    _reset = 7;
    _border = _readControl = _sof1 = _sof2 = _size = 0;
    _videoControl = 0x108;
    _memoryTiming.setAll(0, [0x20, 0, 0x15f28997, 0x90639]);
    if (clearMemory) vram.fillRange(0, vramSize, 0);
  }

  int read(int offset, int size) {
    if (size != 4) {
      throw DcUnsupported('GPU registers require longword access');
    }
    if ([0xc4, 0xc8, 0xcc, 0xd0, 0xd4, 0xd8, 0xdc, 0xe0, 0x10c]
        .contains(offset)) {
      return spg.read(offset);
    }
    if (offset >= 0x1000 && offset < 0x2000) {
      return palette.read(offset - 0x1000, size);
    }
    if (offset == 0x108) return palette.control;
    if (offset == 0x110) return _memoryTiming[3];
    if (const [0xa0, 0xa4, 0xa8].contains(offset)) {
      return _memoryTiming[(offset - 0xa0) ~/ 4];
    }
    if (const [0x148, 0x14c, 0x150].contains(offset)) return yuv.read(offset);
    if (_taRegister(offset)) return ta.read(offset);
    if (DcGpuRender.handles(offset)) return render.read(offset);
    return switch (offset) {
      0 => 0x17fd11db,
      4 => 0x11,
      8 => _reset,
      0x40 => _border,
      0x44 => _readControl,
      0x50 => _sof1,
      0x54 => _sof2,
      0x5c => _size,
      0xe8 => _videoControl,
      0xec => spg.displayX,
      0xf0 => _startY,
      0x114 => _selectSecond(spg.field2) ? _activeSof2 : _activeSof1,
      _ => throw DcUnsupported('unimplemented GPU register: $offset'),
    };
  }

  void write(int offset, int size, int value) {
    if (size == 4 && offset == 0x110) {
      _memoryTiming[3] = value & 0xf7f3f;
      return;
    }
    if (size != 4) {
      throw DcUnsupported('GPU registers require longword access');
    }
    if (const [0xa0, 0xa4, 0xa8].contains(offset)) {
      final index = (offset - 0xa0) ~/ 4;
      _memoryTiming[index] = value & const [0xff, 0x3fffff, 0x1fffffff][index];
      return;
    }
    if ([0xc4, 0xc8, 0xcc, 0xd0, 0xd4, 0xd8, 0xdc, 0xe0, 0x10c]
        .contains(offset)) {
      return spg.write(offset, value);
    }
    if (offset >= 0x1000 && offset < 0x2000) {
      return palette.write(offset - 0x1000, size, value);
    }
    if (offset == 0x108) {
      palette.control = value;
      return;
    }
    if (const [0x148, 0x14c, 0x150].contains(offset)) {
      return yuv.write(offset, value);
    }
    if (_taRegister(offset)) return ta.write(offset, value);
    if (DcGpuRender.handles(offset)) {
      if (offset == 0x14 && _reset & 6 != 0) {
        throw const DcUnsupported('CORE or SDRAM interface is held in reset');
      }
      return render.write(offset, value);
    }
    switch (offset) {
      case 0:
      case 4:
      case 0x114:
        return;
      case 8:
        _reset = value & 7;
        if (value & 1 != 0) {
          ta.reset(registers: false);
          yuv.reset();
        }
        if (value & 2 != 0) render.reset();
      case 0x40:
        _border = value & 0x1ffffff;
      case 0x44:
        if ((render.busy || render.stripWatching) &&
            (value ^ _readControl) & 0x7f0000 != 0) {
          throw const DcUnsupported(
              'GPU strip configuration changed during rendering');
        }
        if (value & 0x400000 != 0 &&
            (value & 0x3f0000 == 0 || value & 0x10000 != 0)) {
          throw const DcUnsupported('GPU invalid strip-buffer size');
        }
        _readControl = value & 0xffff7f;
        spg.setFastClock(value & 0x800000 != 0);
      case 0x50:
        _sof1 = value & 0xfffffc;
      case 0x54:
        _sof2 = value & 0xfffffc;
      case 0x5c:
        _size = value & 0x3fffffff;
      case 0xe8:
        if (value & 0xf0 > 0x30) {
          throw DcUnsupported('GPU external field modes are unimplemented');
        }
        _videoControl = value & 0x3f01ff;
      case 0xec:
        spg.displayX = value & 1023;
      case 0xf0:
        _startY = value & 0x03ff03ff;
      default:
        throw DcUnsupported('unimplemented GPU register: $offset');
    }
  }

  bool _taRegister(int offset) => const [
        0x124,
        0x128,
        0x12c,
        0x130,
        0x134,
        0x138,
        0x13c,
        0x140,
        0x144,
        0x160,
        0x164
      ].contains(offset);

  bool _selectSecond(bool field2) => switch ((_videoControl >> 4) & 15) {
        1 => !field2,
        2 => false,
        3 => true,
        _ => field2
      };

  void _scanLine(int line, bool field2) {
    if (_readControl & 1 == 0 && _scanning == null) return;
    final second = _selectSecond(field2);
    final firstLine = (second ? _startY >> 16 : _startY) & 1023;
    final delta = line - firstLine;
    if (delta < 0 && _scanning == null) return;
    final targetDelta = line - (_scanning == null ? firstLine : _scanStartY);
    if (targetDelta < 0 || (spg.interlaced && targetDelta.isOdd)) return;
    final row = targetDelta ~/ (spg.interlaced ? 2 : 1);
    final sourceLine = delta ~/ (spg.interlaced ? 2 : 1);
    final lineRepeat = _readControl & 2 != 0 ? 2 : 1;
    final sourceRow = sourceLine ~/ lineRepeat;
    final sourceHeight = ((_size >> 10) & 1023) + 1;
    if (sourceRow >= sourceHeight && _scanning == null) return;
    final depth = (_readControl >> 2) & 3;
    final bytesPerPixel = [2, 2, 3, 4][depth];
    final words = (_size & 1023) + 1;
    final sourceWidth = words * 4 ~/ bytesPerPixel;
    final stride = (words - 1 + ((_size >> 20) & 1023)) * 4;
    final border = _borderColor;
    final pixelRepeat = _videoControl & 0x100 != 0 ? 2 : 1;
    if (_scanning == null) _scanStartY = firstLine;
    _scanning ??= ImageBuffer(
        sourceWidth,
        sourceHeight * lineRepeat,
        Uint32List(sourceWidth * sourceHeight * lineRepeat)
          ..fillRange(0, sourceWidth * sourceHeight * lineRepeat, border),
        displayWidth_: sourceWidth * pixelRepeat,
        displayHeight: sourceHeight * lineRepeat);
    final frame = _scanning!;
    if (row >= frame.height) return;
    final stripLines = _stripLines;
    final start = stripLines == 0
        ? (second ? _activeSof2 : _activeSof1) + sourceRow * stride
        : render.read((sourceRow ~/ stripLines).isOdd ? 0x64 : 0x60) +
            (sourceRow % stripLines) * stride;
    final concat = (_readControl >> 4) & 7;
    final blank = _readControl & 1 == 0 ||
        _videoControl & 8 != 0 ||
        spg.verticalBlank ||
        delta < 0 ||
        sourceRow >= sourceHeight;
    final blankStart = spg.hblank & 1023, blankEnd = (spg.hblank >> 16) & 1023;
    if (!blank && stripLines != 0 && !render.stripReady(sourceRow)) {
      render.stripHazard();
      onError?.call(1 << 1);
    }
    for (var x = 0; x < frame.width; x++) {
      final clock = spg.displayX + x * pixelRepeat;
      var horizontalBlank = spg.horizontalBlank, latestEdge = -1;
      if (blankStart >= spg.displayX && blankStart <= clock) {
        horizontalBlank = true;
        latestEdge = blankStart;
      }
      if (blankEnd >= spg.displayX &&
          blankEnd <= clock &&
          blankEnd >= latestEdge) {
        horizontalBlank = false;
      }
      frame.buffer[row * frame.width + x] = blank ||
              horizontalBlank ||
              x >= sourceWidth ||
              clock >= spg.pixelsPerLine
          ? border
          : _pixel(start + x * bytesPerPixel, depth, concat);
    }
    if (!blank &&
        stripLines != 0 &&
        sourceLine % lineRepeat == lineRepeat - 1) {
      render.consumeStripRow(sourceRow, last: sourceRow == sourceHeight - 1);
    }
  }

  int get _stripLines =>
      _readControl & 0x400000 == 0 ? 0 : ((_readControl >> 17) & 31) * 32;

  int? get clocksToStripScan =>
      _stripLines == 0 ? null : spg.clocksToScanPosition;

  int get _borderColor =>
      _color((_border >> 16) & 255, (_border >> 8) & 255, _border & 255);

  int _pixel(int address, int depth, int concat) {
    if (depth >= 2) {
      return _color(_byte(address + 2), _byte(address + 1), _byte(address));
    }
    final value = _byte(address) | (_byte(address + 1) << 8);
    final red = (((value >> (depth == 0 ? 10 : 11)) & 31) << 3) | concat;
    final green = depth == 0
        ? (((value >> 5) & 31) << 3) | concat
        : (((value >> 5) & 63) << 2) | (concat & 3);
    final blue = ((value & 31) << 3) | concat;
    return _color(red, green, blue);
  }

  int _byte(int address) {
    if (_stripLines != 0 && address & 0x1000000 != 0) {
      address =
          (address & 3) | ((address >> 1) & 0x3ffffc) | ((address & 4) << 20);
    }
    return vram[address & (vramSize - 1)];
  }

  int _color(int red, int green, int blue) =>
      (0xff000000 | (blue << 16) | (green << 8) | red).mask32;

  /// Captures framebuffer data, not a raster-timed or border-positioned CRT image.
  ImageBuffer image({bool field2 = false}) => _image(field2: field2);

  ImageBuffer _image({bool field2 = false}) {
    if (_readControl & 1 == 0) return ImageBuffer.empty();
    final depth = (_readControl >> 2) & 3;
    final bytesPerPixel = [2, 2, 3, 4][depth];
    final words = (_size & 1023) + 1;
    final width = words * 4 ~/ bytesPerPixel;
    final height = ((_size >> 10) & 1023) + 1;
    final stride = (words - 1 + ((_size >> 20) & 1023)) * 4;
    final second = _selectSecond(field2);
    final start = second ? _sof2 : _sof1;
    final concat = (_readControl >> 4) & 7;
    final pixels = Uint32List(width * height);
    final blank = _videoControl & 8 != 0;
    final border =
        _color((_border >> 16) & 255, (_border >> 8) & 255, _border & 255);
    for (var y = 0; y < height; y++) {
      final stripLines = _stripLines;
      final rowStart = stripLines == 0
          ? start + y * stride
          : render.read((y ~/ stripLines).isOdd ? 0x64 : 0x60) +
              (y % stripLines) * stride;
      for (var x = 0; x < width; x++) {
        final address = rowStart + x * bytesPerPixel;
        pixels[y * width + x] = blank ? border : _pixel(address, depth, concat);
      }
    }
    return ImageBuffer(width, height, pixels,
        displayWidth_: width * (_videoControl & 0x100 != 0 ? 2 : 1),
        displayHeight: height * (_readControl & 2 != 0 ? 2 : 1));
  }
}

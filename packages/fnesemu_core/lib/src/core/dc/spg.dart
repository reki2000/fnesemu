import '../../state.dart';
import 'fault.dart';

/// Functional GPU sync generator on a fixed nominal 200 MHz timebase.
/// Interlaced presets use half-line counts; pin-level equalizing pulses are pending.
class DcSpg {
  int hblankInterrupt = 0x031d0000, vblankInterrupt = 0x01500104;
  int control = 0x40, hblank = 0x007e0345, load = 0x01060359;
  int vblank = 0x01500104, width = 0x07f1933f;
  int triggerPosition = 0, displayX = 0x9d;
  bool _lineSampled = false;
  int _h = 0, _v = 0, _phase = 0;
  bool _field2 = false, _hBlank = false, _vBlank = false;
  bool fastClock = false;
  int completedLines = 0, completedFields = 0;
  void Function(int sources)? onInterrupt;
  void Function()? onVerticalBlankIn, onVerticalBlankOut;
  void Function(bool field2)? onFieldEnd;
  void Function(int line, bool field2)? onScanPosition;

  void saveState(StateWriter writer) {
    writer.section('dc.spg');
    writer.ints([
      hblankInterrupt,
      vblankInterrupt,
      control,
      hblank,
      load,
      vblank,
      width,
      triggerPosition,
      displayX,
      _h,
      _v,
      _phase,
      completedLines,
      completedFields
    ]);
    for (final flag in [_lineSampled, _field2, _hBlank, _vBlank, fastClock]) {
      writer.boolean(flag);
    }
  }

  void loadState(StateReader reader) {
    reader.section('dc.spg');
    final v = reader.ints();
    final f = [for (var i = 0; i < 5; i++) reader.boolean()];
    if (v.length != 14 ||
        v.any((value) => value < 0) ||
        v[0] & ~0x03ff33ff != 0 ||
        (v[0] >> 12) & 3 == 3 ||
        ((v[0] >> 12) & 3 == 1 && v[0] & 1023 == 0) ||
        v[1] & ~0x03ff03ff != 0 ||
        v[2] & ~0x3f7 != 0 ||
        v[3] & ~0x03ff03ff != 0 ||
        v[4] & ~0x03ff03ff != 0 ||
        v[5] & ~0x03ff03ff != 0 ||
        v[6] & ~0xffffff7f != 0 ||
        v[7] & ~0x03ff03ff != 0 ||
        v[8] > 1023 ||
        v[9] >= (v[4] & 1023) + 1 ||
        v[10] >= ((v[4] >> 16) & 1023) + 1 ||
        v[11] >= 400) {
      throw const StateMismatch('SPG timing or register state');
    }
    hblankInterrupt = v[0];
    vblankInterrupt = v[1];
    control = v[2];
    hblank = v[3];
    load = v[4];
    vblank = v[5];
    width = v[6];
    triggerPosition = v[7];
    displayX = v[8];
    _h = v[9];
    _v = v[10];
    _phase = v[11];
    completedLines = v[12];
    completedFields = v[13];
    _lineSampled = f[0];
    _field2 = f[1];
    _hBlank = f[2];
    _vBlank = f[3];
    fastClock = f[4];
  }

  bool get running => control & 0x100 != 0;
  bool get interlaced => control & 0x10 != 0;
  int get pixelsPerLine => (load & 1023) + 1;
  int get linesPerField => ((load >> 16) & 1023) + 1;
  int get _denominator => fastClock || interlaced ? 200 : 400;
  int get nominalLineClocks => (pixelsPerLine * _denominator + 26) ~/ 27;

  /// Next raster read boundary used to arbitrate strip-buffer reuse.
  int? get clocksToScanPosition {
    if (!running) return null;
    var pixels = displayX - _h;
    if (pixels < 0 || (pixels == 0 && _lineSampled)) pixels += pixelsPerLine;
    return (((pixels * _denominator - _phase + 26) ~/ 27)).clamp(1, 0x7fffffff);
  }

  /// Clocks until the current line completes.
  int? get clocksToNextLine {
    if (!running) return null;
    final clocks = ((pixelsPerLine - _h) * _denominator - _phase + 26) ~/ 27;
    return clocks < 1 ? 1 : clocks;
  }

  /// Physical blank edges are independent of the programmable IRQ comparisons.
  int? get clocksToVerticalBlankOut => _clocksToLine((vblank >> 16) & 1023);
  int? get clocksToVerticalBlankIn => _clocksToLine(vblank & 1023);

  /// Next programmable IRQ used by event-driven external DMA initiation.
  int? clocksToInterrupt(int mask) {
    if (!running) return null;
    int? result;
    void include(int? clocks) {
      if (clocks != null && (result == null || clocks < result!)) {
        result = clocks;
      }
    }

    if (mask & 8 != 0) include(_clocksToLine(vblankInterrupt & 1023));
    if (mask & 16 != 0) include(_clocksToLine((vblankInterrupt >> 16) & 1023));
    final compare = (hblankInterrupt >> 16) & 1023;
    if (mask & 32 != 0 && compare < pixelsPerLine) {
      final mode = (hblankInterrupt >> 12) & 3, line = hblankInterrupt & 1023;
      int? offset;
      if (mode == 2) {
        offset = compare > _h ? 0 : 1;
      } else if (mode == 0 && line < linesPerField) {
        offset = (line - _v + linesPerField) % linesPerField;
        if (offset == 0 && compare <= _h) offset = linesPerField;
      } else if (mode == 1 && line != 0) {
        if (_v % line == 0 && compare > _h) {
          offset = 0;
        } else {
          final next = (_v ~/ line + 1) * line;
          offset = next < linesPerField ? next - _v : linesPerField - _v;
        }
      }
      if (offset != null) {
        final distance = offset * pixelsPerLine + compare - _h;
        include((distance * _denominator - _phase + 26) ~/ 27);
      }
    }
    return result;
  }

  int? _clocksToLine(int line) {
    if (!running || line >= linesPerField) return null;
    var lines = line - _v;
    if (lines <= 0) lines += linesPerField;
    return ((lines * pixelsPerLine - _h) * _denominator - _phase + 26) ~/ 27;
  }

  int get scanline => _v;
  bool get field2 => _field2;
  bool get horizontalBlank => _hBlank;
  bool get verticalBlank => _vBlank;

  int get status => !running
      ? 0
      : _v |
          (_field2 ? 0x400 : 0) |
          (_hBlank || _vBlank ? 0x800 : 0) |
          (_h <= (width & 127) ? 0x1000 : 0) |
          (_v < ((width >> 8) & 15) ? 0x2000 : 0);

  void reset() {
    hblankInterrupt = 0x031d0000;
    vblankInterrupt = 0x01500104;
    control = 0x40;
    hblank = 0x007e0345;
    load = 0x01060359;
    vblank = 0x01500104;
    width = 0x07f1933f;
    triggerPosition = _h = _v = _phase = completedLines = completedFields = 0;
    _field2 = _hBlank = _vBlank = fastClock = _lineSampled = false;
    displayX = 0x9d;
  }

  int read(int offset) => switch (offset) {
        0xc4 => triggerPosition,
        0xc8 => hblankInterrupt,
        0xcc => vblankInterrupt,
        0xd0 => control,
        0xd4 => hblank,
        0xd8 => load,
        0xdc => vblank,
        0xe0 => width,
        0x10c => status,
        _ => throw DcUnsupported('unsupported SPG register: $offset'),
      };

  void write(int offset, int value) {
    switch (offset) {
      case 0xc4:
      case 0x10c:
        return;
      case 0xc8:
        if ((value >> 12) & 3 == 3 ||
            ((value >> 12) & 3 == 1 && value & 1023 == 0)) {
          throw DcUnsupported('prohibited/undefined SPG HBlank interrupt mode');
        }
        hblankInterrupt = value & 0x03ff33ff;
      case 0xcc:
        vblankInterrupt = value & 0x03ff03ff;
      case 0xd0:
        if (value & 8 != 0) {
          throw DcUnsupported('SPG external sync lock is unimplemented');
        }
        control = value & 0x3ff;
        if (control & 0x20 != 0) {
          _field2 = true;
        } else if (!interlaced) {
          _field2 = false;
        }
        _phase %= _denominator;
      case 0xd4:
        hblank = value & 0x03ff03ff;
      case 0xd8:
        load = value & 0x03ff03ff;
        _h %= pixelsPerLine;
        _v %= linesPerField;
      case 0xdc:
        vblank = value & 0x03ff03ff;
      case 0xe0:
        width = value & 0xffffff7f;
      default:
        throw DcUnsupported('unsupported SPG write: $offset');
    }
  }

  void setFastClock(bool value) {
    fastClock = value;
    _phase %= _denominator;
  }

  void latchExternalTrigger() => triggerPosition = (_v << 16) | _h;

  void _sampleLine() {
    if (!_lineSampled && _h == displayX) {
      _lineSampled = true;
      onScanPosition?.call(_v, _field2);
    }
  }

  int _nearerEdge(int edge, int advance) =>
      edge > _h && edge < pixelsPerLine && edge - _h < advance
          ? edge - _h
          : advance;

  void tickMasterClocks(int clocks) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    if (!running || clocks == 0) return;
    final total = _phase + clocks * 27;
    var pixels = total ~/ _denominator;
    _phase = total % _denominator;
    _sampleLine();
    while (pixels > 0) {
      final compare = (hblankInterrupt >> 16) & 1023;
      var advance = pixelsPerLine - _h;
      if (compare > _h && compare < pixelsPerLine && compare - _h < advance) {
        advance = compare - _h;
      }
      // Blank transitions are observable even when no IRQ is scheduled there.
      advance = _nearerEdge(hblank & 1023, advance);
      advance = _nearerEdge((hblank >> 16) & 1023, advance);
      advance = _nearerEdge(displayX, advance);
      if (pixels < advance) {
        _h += pixels;
        return;
      }
      pixels -= advance;
      _h += advance;
      var sources = 0;
      if (_h == pixelsPerLine) {
        _h = 0;
        _lineSampled = false;
        _v++;
        completedLines++;
        if (_v == linesPerField) {
          // Capture the completed field before changing its number or latches.
          onFieldEnd?.call(_field2);
          _v = 0;
          completedFields++;
          _field2 = control & 0x20 != 0 || (interlaced && !_field2);
        }
        if (_v == (vblank & 1023)) {
          _vBlank = true;
          onVerticalBlankIn?.call();
        }
        if (_v == ((vblank >> 16) & 1023)) {
          _vBlank = false;
          onVerticalBlankOut?.call();
        }
        if (_v == (vblankInterrupt & 1023)) sources |= 8;
        if (_v == ((vblankInterrupt >> 16) & 1023)) sources |= 16;
      }
      if (_h == (hblank & 1023)) _hBlank = true;
      if (_h == ((hblank >> 16) & 1023)) _hBlank = false;
      if (_h == compare) {
        final mode = (hblankInterrupt >> 12) & 3;
        final line = hblankInterrupt & 1023;
        if (mode == 2 ||
            (mode == 0 && _v == line) ||
            (mode == 1 && _v % line == 0)) {
          sources |= 32;
        }
      }
      _sampleLine();
      if (sources != 0) onInterrupt?.call(sources);
    }
  }
}

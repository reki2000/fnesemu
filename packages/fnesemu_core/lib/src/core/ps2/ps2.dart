import 'dart:typed_data';

import '../../core.dart';
import '../../types.dart';
import '../../util/debug.dart';
import 'bus.dart';
import 'ee_io.dart';
import 'elf.dart';
import 'intc.dart';
import 'r5900/r5900.dart';

final _log = DebugLog('ps2');

class Ps2 extends Core {
  static const _systemClockHz = 294912000; // EE clock, 294.912MHz

  // Placeholder video timing until the GS exists: 60 frames of 262 lines
  static const _scanlines = 262;

  static const _deviceQuantum = 32;
  static const _vblankLine = 240;

  final bus = Ps2Bus();
  late final R5900 cpu = R5900(bus);
  late EeIo io = _newIo();

  /// entry point of the loaded ELF, or null while no executable is loaded
  int? entry;

  int _nextScanlineClock = 0;
  int _lastDeviceClock = 0;
  int _nextDeviceClock = _deviceQuantum;
  int _busRemainder = 0;
  int _line = 0;
  final _result = ExecResult(0, false, false);

  EeIo _newIo() {
    final io = EeIo(bus);
    bus.io = io;
    return io;
  }

  @override
  int get systemClockHz => _systemClockHz;

  @override
  int get scanlinesInFrame => _scanlines;

  @override
  int get clocksInScanline => _systemClockHz ~/ 60 ~/ _scanlines;

  @override
  int get cpuClocks => cpu.clocks;

  /// loads an ELF executable into main memory and points the CPU at it
  @override
  void setRom(Uint8List body) {
    final elf = Elf.parse(body);
    final ram = bus.ram;
    ram.fillRange(0, ram.length, 0);
    for (final segment in elf.segments) {
      final start = segment.address & (ram.length - 1);
      if (segment.address >= ram.length ||
          start + segment.memorySize > ram.length) {
        throw RangeError('ELF segment at 0x${segment.address.toRadixString(16)}'
            ' is outside main memory');
      }
      ram.setAll(start, segment.data);
    }
    entry = elf.entry;
    reset();
    _log.info('loaded ELF, entry 0x${elf.entry.toRadixString(16)}');
  }

  @override
  ImageBuffer imageBuffer() => io.gs.image();

  @override
  void reset() {
    cpu.reset();
    io = _newIo();
    final start = entry;
    if (start != null) cpu.jumpTo(start);
    _nextScanlineClock = clocksInScanline;
    _lastDeviceClock = 0;
    _nextDeviceClock = _deviceQuantum;
    _busRemainder = 0;
    _line = 0;
  }

  /// advances the timers by the CPU clocks since the last call; the bus runs
  /// at half the CPU clock
  void _advanceDevices() {
    final elapsed = cpu.clocks - _lastDeviceClock + _busRemainder;
    _busRemainder = elapsed & 1;
    io.timers.advance(elapsed >> 1);
    _lastDeviceClock = cpu.clocks;
    _nextDeviceClock = cpu.clocks + _deviceQuantum;
  }

  void _endOfScanline() {
    io.timers.hblank();
    _line++;
    if (_line == _vblankLine) {
      io.intc.raise(Intc.vblankStart);
      io.gs.vblank();
    } else if (_line == _scanlines) {
      _line = 0;
      io.intc.raise(Intc.vblankEnd);
    }
  }

  @override
  ExecResult exec(bool step) {
    final before = cpu.clocks;
    final ok = cpu.step();
    _result.stopped = !ok;
    _result.elapsedClocks = cpu.clocks - before;
    _result.scanlineRendered = false;
    if (ok && cpu.clocks >= _nextScanlineClock) {
      _nextScanlineClock += clocksInScanline;
      _result.scanlineRendered = true;
      _endOfScanline();
    }
    if (cpu.clocks >= _nextDeviceClock) _advanceDevices();
    if (io.intc.dirty || io.dmac.dirty) {
      io.intc.dirty = io.dmac.dirty = false;
      cpu.setInterruptLine(R5900.ipIntc, io.intc.asserted);
      cpu.setInterruptLine(R5900.ipDmac, io.dmac.asserted);
    }
    return _result;
  }
}

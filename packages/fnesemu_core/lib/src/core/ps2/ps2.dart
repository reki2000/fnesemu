import 'dart:typed_data';

import '../../core.dart';
import '../../types.dart';
import '../../util/debug.dart';
import 'bus.dart';
import 'elf.dart';
import 'r5900/r5900.dart';

final _log = DebugLog('ps2');

class Ps2 extends Core {
  static const _systemClockHz = 294912000; // EE clock, 294.912MHz

  // Placeholder video timing until the GS exists: 60 frames of 262 lines
  static const _scanlines = 262;

  final bus = Ps2Bus();
  late final R5900 cpu = R5900(bus);

  /// entry point of the loaded ELF, or null while no executable is loaded
  int? entry;

  int _nextScanlineClock = 0;
  final _result = ExecResult(0, false, false);

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
    cpu.reset();
    cpu.jumpTo(elf.entry);
    _nextScanlineClock = clocksInScanline;
    _log.info('loaded ELF, entry 0x${elf.entry.toRadixString(16)}');
  }

  @override
  void reset() {
    cpu.reset();
    final start = entry;
    if (start != null) cpu.jumpTo(start);
    _nextScanlineClock = clocksInScanline;
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
    }
    return _result;
  }
}

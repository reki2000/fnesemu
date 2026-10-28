import 'dart:typed_data';

import '../../cdrom_drive.dart';
import '../../core.dart';
import '../../pad_button.dart';
import '../../types.dart';
import '../../util/debug.dart';
import 'bus.dart';
import 'ee_io.dart';
import 'elf.dart';
import 'intc.dart';
import 'iop/iop.dart';
import 'iop/iop_io.dart';
import 'iop/iop_memory.dart';
import 'iop/pad.dart';
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

  late final IopMemory iopMemory = IopMemory(bus.bios);
  late final Iop iop = Iop(iopMemory);
  late IopIo iopIo = _newIopIo();

  IopIo _newIopIo() => IopIo(iopMemory, io.sif)
    ..sio2.pad = _pad
    ..cdvd.drive = _drive;

  /// the IOP only runs when a BIOS provides its program
  bool biosLoaded = false;

  /// entry point of the loaded ELF, or null while no executable is loaded
  int? entry;

  int _nextScanlineClock = 0;
  int _lastDeviceClock = 0;
  int _nextDeviceClock = _deviceQuantum;
  int _busRemainder = 0;
  int _iopFraction = 0;
  int _line = 0;
  final _result = ExecResult(0, false, false);

  @override
  void setBiosFiles(List<Uint8List> files) {
    if (files.isEmpty) return;
    final bios = files.first;
    bus.bios.fillRange(0, bus.bios.length, 0);
    bus.bios.setAll(
        0,
        bios.length > bus.bios.length
            ? bios.sublist(0, bus.bios.length)
            : bios);
    biosLoaded = true;
    reset();
  }

  EeIo _newIo() {
    final io = EeIo(bus);
    bus.io = io;
    cpu.vu0 = io.vu0;
    io.iopRam = iopMemory.ram;
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

  late final _pad = Ps2Pad();

  @override
  List<PadButton> get buttons => _pad.buttons;

  @override
  void padDown(int controllerId, PadButton k) => _pad.keyDown(controllerId, k);

  @override
  void padUp(int controllerId, PadButton k) => _pad.keyUp(controllerId, k);

  CdromDrive? _drive;

  @override
  void setCdromDrive(CdromDrive drive) {
    _drive = drive;
    iopIo.cdvd.drive = drive;
  }

  @override
  void reset() {
    cpu.reset();
    io = _newIo();
    iop.reset();
    iopMemory.ram.fillRange(0, iopMemory.ram.length, 0);
    iopIo = _newIopIo();
    _iopFraction = 0;
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
    io.dmac.service();
    if (biosLoaded) _advanceIop(cpu.clocks - _lastDeviceClock);
    _lastDeviceClock = cpu.clocks;
    _nextDeviceClock = cpu.clocks + _deviceQuantum;
  }

  /// the IOP runs at 1/8 of the EE clock
  void _advanceIop(int eeClocks) {
    _iopFraction += eeClocks;
    final steps = _iopFraction >> 3;
    _iopFraction &= 7;
    for (var i = 0; i < steps; i++) {
      iop.step();
    }
    iopIo.advanceTimers(steps);
    iopIo.service();
    if (iopIo.dirty) {
      iopIo.dirty = false;
      iop.setInterrupt(iopIo.asserted);
    }
  }

  void _endOfScanline() {
    io.timers.hblank();
    if (biosLoaded) iopIo.hblank();
    _line++;
    if (_line == _vblankLine) {
      io.intc.raise(Intc.vblankStart);
      io.gs.vblank();
      iopIo.raise(IopIrq.vblankStart);
    } else if (_line == _scanlines) {
      _line = 0;
      io.intc.raise(Intc.vblankEnd);
      iopIo.raise(IopIrq.vblankEnd);
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

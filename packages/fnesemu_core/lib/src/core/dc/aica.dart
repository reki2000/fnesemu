import 'dart:typed_data';

import '../../state.dart';
import '../../util/uint8list.dart';
import 'aica_dsp.dart';
import 'aica_midi.dart';
import 'aica_sound.dart';
import 'arm7di.dart';
import 'fault.dart';

/// Retail AICA memory, RTC and timer/interrupt subset from System Architecture.
/// Sound interrupts use a functional number/end handshake; physical queue timing is pending.
class DcAica {
  DcAica({required this.onInterrupt, this.externalActive, this.externalSample});
  final bool Function()? externalActive;
  final (int, int) Function()? externalSample;
  bool _externalLatched = false;
  bool get needsSampleClock =>
      sound.needsSampleClock ||
      _externalLatched ||
      (externalActive?.call() ?? false);

  void _sampleExternal() {
    _externalLatched = externalActive?.call() ?? false;
    final sample = externalSample!();
    dsp.setExternalInput(sample.$1, sample.$2);
  }

  static const memorySize = 0x200000;
  static const masterHz = 200000000;
  static const sampleHz = 44100;
  static const armHz = 22579200;
  final void Function(bool) onInterrupt;
  final memory = Uint8List(memorySize);
  final dsp = DcAicaDsp();
  final _midi = DcAicaMidi();
  late final sound = DcAicaSound(memory, dsp: dsp);
  late final arm = DcArm7di(read: _armRead, write: _armWrite);
  final _timers = Uint16List(3), _timerPhase = Uint8List(3);
  final _levels = Uint8List(3);
  int _samplePhase = 0, _rtcPhase = 0, _rtc = 0;
  int _scEnable = 0, _scPending = 0, _mcEnable = 0, _mcPending = 0;
  int _resetControl = 1;
  int _armInterruptLevel = 0, _memoryControl = 0;
  bool _armRearm = false, _readProtected = false;
  int _armPhase = 0, _armRemaining = 1;
  int _dmaMemoryLow = 0, _dmaRegister = 0, _dmaControl = 0;
  int _dmaMemoryCursor = 0, _dmaRegisterCursor = 0, _dmaRemaining = 0;
  int _dmaPhase = 0;
  bool get internalDmaBusy => _dmaRemaining != 0;
  int get internalDmaRemaining => _dmaRemaining;
  int executedInstructions = 0;
  bool _rtcWritable = false;

  bool get armReset => _resetControl & 1 != 0;
  int get soundPending => _scPending;
  int get systemPending => _mcPending;
  int timerCounter(int index) => _timers[index] & 255;
  bool get systemInterrupt => _mcEnable & _mcPending != 0;
  int get armInterruptLevel => _armInterruptLevel;
  int get memoryInhibit => _memoryControl & 15;
  bool get readProtected => _readProtected;

  void _captureArmInterrupt() {
    if (_armInterruptLevel != 0 || _armRearm) return;
    final pending = _scEnable & _scPending;
    if (pending == 0) return;
    var selected = 0;
    for (var source = 0; source < 11; source++) {
      if (pending & (1 << source) == 0) continue;
      final group = source < 7 ? source : 7;
      final level = ((_levels[0] >> group) & 1) |
          (((_levels[1] >> group) & 1) << 1) |
          (((_levels[2] >> group) & 1) << 2);
      if (level > selected) selected = level;
    }
    _armInterruptLevel = selected;
  }

  void _signal() {
    _scPending = (_scPending & ~8) | (_midi.hasInput ? 8 : 0);
    _mcPending = (_mcPending & ~8) | (_midi.hasInput ? 8 : 0);
    _captureArmInterrupt();
    arm.fiq = !armReset && _armInterruptLevel != 0;
    onInterrupt(systemInterrupt);
  }

  /// Inject a completely received byte; serial framing/pin timing is not modeled.
  bool receiveMidiByte(int value) {
    final accepted = _midi.receive(value);
    _signal();
    return accepted;
  }

  /// Complete transmission of one queued byte at the external endpoint.
  int? takeMidiOutput() {
    final value = _midi.takeOutput();
    if (value != null && !_midi.hasOutput) {
      _scPending |= 0x200;
      _mcPending |= 0x200;
      _signal();
    }
    return value;
  }

  void _writeMidi(int value) {
    _midi.write(value);
    _scPending &= ~0x200;
    _mcPending &= ~0x200;
  }

  /// The current model stops on inhibited system cycles instead of modeling bus lockup.
  void validateSystemMemory({required bool write}) {
    if (memoryInhibit & 8 != 0 || (!write && _readProtected)) {
      throw const DcUnsupported('AICA system wave-memory access is inhibited');
    }
  }

  /// Full system reset retains the separately powered RTC and its fraction.
  void reset({bool clearMemory = false}) {
    _externalLatched = false;
    if (clearMemory) memory.fillRange(0, memory.length, 0);
    _timers.fillRange(0, 3, 0);
    _timerPhase.fillRange(0, 3, 0);
    _levels.fillRange(0, 3, 0);
    _samplePhase = 0;
    _scEnable = _scPending = _mcEnable = _mcPending = 0;
    _resetControl = 1;
    _armInterruptLevel = _memoryControl = 0;
    _armRearm = _readProtected = false;
    _dmaMemoryLow = _dmaRegister = _dmaControl = 0;
    _dmaMemoryCursor = _dmaRegisterCursor = _dmaRemaining = _dmaPhase = 0;
    arm.reset();
    dsp.reset();
    _midi.reset();
    sound.reset();
    executedInstructions = 0;
    _armPhase = 0;
    _armRemaining = 1;
    _rtcWritable = false;
    _signal();
  }

  List<int> get _stateScalars => [
        _samplePhase,
        _rtcPhase,
        _rtc,
        _scEnable,
        _scPending,
        _mcEnable,
        _mcPending,
        _resetControl,
        _armInterruptLevel,
        _memoryControl,
        _armPhase,
        _armRemaining,
        _dmaMemoryLow,
        _dmaRegister,
        _dmaControl,
        _dmaMemoryCursor,
        _dmaRegisterCursor,
        _dmaRemaining,
        _dmaPhase,
        executedInstructions
      ];

  void _restoreScalars(List<int> values) {
    if (values.length != 20 || values.any((value) => value < 0)) {
      throw const StateMismatch('AICA controller layout');
    }
    // The longest current ARM7DI instruction is a 20-cycle LDM including PC.
    bool fits(int index, int mask) => values[index] & ~mask == 0;
    if ([0, 1, 10, 18].any((index) => values[index] >= masterHz) ||
        !fits(2, 0xffffffff) ||
        [3, 4, 5, 6].any((index) => !fits(index, 0x7ff)) ||
        !fits(7, 0x301) ||
        values[8] > 7 ||
        !fits(9, 0xfe0f) ||
        values[11] < 1 ||
        values[11] > 20 ||
        [12, 13, 14].any((index) => !fits(index, 0xfffc)) ||
        values[15] > memorySize ||
        values[16] > 0x45c8 ||
        !fits(17, 0x7ffc) ||
        (values[15] | values[16]) & 3 != 0) {
      throw const StateMismatch('AICA controller values');
    }
    final remaining = values[17], length = values[14] & 0x7ffc;
    if (remaining != 0) {
      final memoryStart = ((values[9] & 0xfe00) << 7) | values[12];
      final registerStart = values[13] & 0x7ffc;
      if (remaining > length ||
          values[15] != memoryStart + length - remaining ||
          values[16] != registerStart + length - remaining ||
          memoryStart + length > memorySize ||
          registerStart + length > 0x45c8 ||
          (registerStart < 0x2890 && registerStart + length > 0x2880)) {
        throw const StateMismatch('AICA active DMA state');
      }
    }
    var i = 0;
    _samplePhase = values[i++];
    _rtcPhase = values[i++];
    _rtc = values[i++];
    _scEnable = values[i++];
    _scPending = values[i++];
    _mcEnable = values[i++];
    _mcPending = values[i++];
    _resetControl = values[i++];
    _armInterruptLevel = values[i++];
    _memoryControl = values[i++];
    _armPhase = values[i++];
    _armRemaining = values[i++];
    _dmaMemoryLow = values[i++];
    _dmaRegister = values[i++];
    _dmaControl = values[i++];
    _dmaMemoryCursor = values[i++];
    _dmaRegisterCursor = values[i++];
    _dmaRemaining = values[i++];
    _dmaPhase = values[i++];
    executedInstructions = values[i++];
  }

  void _saveComponents(StateWriter writer) {
    arm.saveState(writer);
    dsp.saveState(writer);
    _midi.saveState(writer);
    sound.saveState(writer);
  }

  void _loadComponents(StateReader reader) {
    arm.loadState(reader);
    dsp.loadState(reader);
    _midi.loadState(reader);
    sound.loadState(reader);
  }

  void saveState(StateWriter writer) {
    writer.section('dc.aica');
    writer.bytes(memory);
    writer.ints(_timers);
    writer.bytes(_timerPhase);
    writer.bytes(_levels);
    writer.ints(_stateScalars);
    writer.boolean(_externalLatched);
    writer.boolean(_armRearm);
    writer.boolean(_readProtected);
    writer.boolean(_rtcWritable);
    _saveComponents(writer);
  }

  void _readState(StateReader reader) {
    reader.section('dc.aica');
    reader.bytesInto(memory);
    final timers = reader.ints();
    if (timers.length != 3 ||
        timers.any((timer) => timer < 0 || timer > 0x7ff)) {
      throw const StateMismatch('AICA timer registers');
    }
    _timers.setAll(0, timers);
    reader.bytesInto(_timerPhase);
    reader.bytesInto(_levels);
    _restoreScalars(reader.ints());
    for (var i = 0; i < 3; i++) {
      if (_timerPhase[i] >= (1 << (_timers[i] >> 8))) {
        throw const StateMismatch('AICA timer state');
      }
    }
    _externalLatched = reader.boolean();
    _armRearm = reader.boolean();
    _readProtected = reader.boolean();
    _rtcWritable = reader.boolean();
    _loadComponents(reader);
  }

  /// Validate on an isolated chip before updating existing buffers and wiring.
  void loadState(StateReader reader) {
    final staged = DcAica(onInterrupt: (_) {});
    staged.sound.diagnosticByteAddressAdpcm = sound.diagnosticByteAddressAdpcm;
    staged._readState(reader);
    if (staged._externalLatched && externalSample == null) {
      throw const StateMismatch('AICA external audio provider is missing');
    }
    // Replay the component sections separately; wave RAM is copied directly.
    final writer = StateWriter('dc.aica.transfer', 1, 0);
    staged._saveComponents(writer);
    final components = StateReader(writer.take(), 'dc.aica.transfer', 1, 0);
    memory.setAll(0, staged.memory);
    _timers.setAll(0, staged._timers);
    _timerPhase.setAll(0, staged._timerPhase);
    _levels.setAll(0, staged._levels);
    _restoreScalars(staged._stateScalars);
    _externalLatched = staged._externalLatched;
    _armRearm = staged._armRearm;
    _readProtected = staged._readProtected;
    _rtcWritable = staged._rtcWritable;
    _loadComponents(components);
    components.end();
    // Restore the external level without capturing a new ARM interrupt number.
    onInterrupt(systemInterrupt);
  }

  static int? physical(int address) {
    address &= 0xffffffff;
    if (address >= 0xc0000000) return null;
    return address & 0x1dffffff;
  }

  static int? registerOffset(int address) {
    final location = physical(address);
    return location != null && location >= 0x700000 && location < 0x708000
        ? location - 0x700000
        : null;
  }

  static int? rtcOffset(int address) {
    final location = physical(address);
    return location != null && location >= 0x710000 && location < 0x71000c
        ? location - 0x710000
        : null;
  }

  static int? memoryOffset(int address) {
    final location = physical(address);
    return location != null && location >= 0x800000 && location < 0xa00000
        ? location - 0x800000
        : null;
  }

  void validateMemory(int offset, int size) {
    // Cache fills/store queues are eight longwords; FPU pairs are two.
    if (![4, 8, 32].contains(size) ||
        offset < 0 ||
        offset + size > memorySize) {
      throw const DcUnsupported('AICA wave memory requires longword cycles');
    }
  }

  void _validateRegister(int offset, int size) {
    if (size != 4 || offset & 3 != 0) {
      throw const DcUnsupported(
          'AICA registers require aligned longword access');
    }
  }

  int readRtc(int offset, int size) {
    _validateRegister(offset, size);
    return switch (offset) {
      0 => _rtc >> 16,
      4 => _rtc & 0xffff,
      _ => throw const DcUnsupported('AICA RTC write-enable is write-only'),
    };
  }

  void writeRtc(int offset, int size, int value) {
    _validateRegister(offset, size);
    value &= 0xffff;
    switch (offset) {
      case 8:
        _rtcWritable = value & 1 != 0;
      case 4:
        if (!_rtcWritable) return;
        _rtc = (_rtc & 0xffff0000) | value;
        _rtcPhase = 0;
      case 0:
        if (!_rtcWritable) return;
        _rtc = ((value << 16) | (_rtc & 0xffff)) & 0xffffffff;
        _rtcWritable = false;
      default:
        throw const DcUnsupported('unimplemented AICA RTC register');
    }
  }

  int read(int offset, int size,
      {bool sideEffects = true, bool fromArm = false}) {
    if (fromArm && size == 1) {
      final lane = offset & 3, aligned = offset & ~3;
      if (lane >= 2) return 0;
      final value = read(aligned, 4,
          fromArm: true,
          sideEffects: sideEffects &&
              (aligned != 0x2810 || lane == 1) &&
              (aligned != 0x2808 || lane == 0));
      return (value >> (lane * 8)) & 255;
    }
    _validateRegister(offset, size);
    if (offset == 0x2c00 && fromArm) {
      throw const DcUnsupported('AICA reset control is SH4-only');
    }
    if (offset == 0x2d00) {
      if (!fromArm) {
        throw const DcUnsupported('AICA interrupt number is ARM-only');
      }
      return _armInterruptLevel;
    }
    if (offset == 0x2808) {
      final value = _midi.read(sideEffects: sideEffects);
      if (sideEffects) _signal();
      return value;
    }
    if (DcAicaDsp.handles(offset)) return dsp.read(offset);
    if (DcAicaSound.outputRegister(offset)) return sound.readOutput(offset);
    if (DcAicaSound.channelRegister(offset)) return sound.read(offset);
    return switch (offset) {
      0x2800 => 0, // Chip-revision identification remains unverified.
      0x2810 => sound.readMonitor(sideEffects: sideEffects),
      0x2814 => sound.currentAddress,
      0x2888 => _dmaRegister & 0x8000,
      0x288c => (_dmaControl & 0x8000) | (internalDmaBusy ? 1 : 0),
      0x289c => _scEnable,
      0x28a0 => _scPending,
      0x28b4 => _mcEnable,
      0x28b8 => _mcPending,
      0x2c00 => _resetControl,
      _ => throw DcUnsupported('unimplemented AICA read: $offset'),
    };
  }

  void write(int offset, int size, int value, {bool fromArm = false}) {
    if (fromArm && size == 1) {
      final lane = offset & 3, aligned = offset & ~3;
      if (lane >= 2) return;
      if (aligned == 0x280c) {
        if (lane == 0) {
          _writeMidi(value);
        } else {
          sound.monitor = (value << 8) & 0x7f00;
        }
        _signal();
        return;
      }
      final shadow = _writeShadow(aligned);
      final payload =
          (shadow & ~(255 << (lane * 8))) | ((value & 255) << (lane * 8));
      if (DcAicaDsp.handles(aligned)) {
        dsp.write(aligned, payload, mask: 255 << (lane * 8));
        return;
      }
      write(aligned, 4, payload, fromArm: true);
      return;
    }
    _validateRegister(offset, size);
    value &= 0xffff;
    if (value == 0 &&
        ((offset >= 0x3300 && offset < 0x3400) ||
            (offset >= 0x3c00 && offset < 0x4000))) {
      return; // Inert writes while clearing the gaps in the DSP register map.
    }
    if (DcAicaDsp.handles(offset)) return dsp.write(offset, value);
    if (DcAicaSound.outputRegister(offset)) {
      return sound.writeOutput(offset, value);
    }
    if (DcAicaSound.channelRegister(offset)) return sound.write(offset, value);
    if (offset >= 0x2890 && offset <= 0x2898) {
      final index = (offset - 0x2890) ~/ 4;
      _timers[index] = value & 0x7ff;
      // Prescaler phase following a timer write needs hardware confirmation.
      _timerPhase[index] = 0;
      return;
    }
    switch (offset) {
      case 0x2880:
        if (internalDmaBusy && (value ^ _memoryControl) & 0xfe00 != 0) {
          throw const DcUnsupported('AICA DMA address changed during transfer');
        }
        if (value & 0xf0 != 0) {
          throw const DcUnsupported('AICA IC-test memory control');
        }
        _memoryControl = (value & 0xfe0f & (fromArm ? ~4 : -1)) |
            (fromArm ? _memoryControl & 4 : 0);
      case 0x2884:
        _requireDmaIdle();
        _dmaMemoryLow = value & 0xfffc;
      case 0x2888:
        _requireDmaIdle();
        _dmaRegister = value & 0xfffc;
      case 0x288c:
        if (internalDmaBusy) {
          // DEXE=0 cannot abort an active transfer or replace its descriptor.
          if ((value ^ _dmaControl) & 0xfffc != 0) _requireDmaIdle();
          break;
        }
        _dmaControl = value & 0xfffc;
        if (value & 1 != 0) _startDma();
      case 0x2d04:
        if (!fromArm) {
          throw const DcUnsupported(
              'AICA interrupt end/read protection is ARM-only');
        }
        if (value & 0xfe != 0) {
          throw const DcUnsupported('AICA reserved interrupt-end bits');
        }
        _readProtected = value & 0x100 != 0;
        if (value & 1 != 0) {
          _armInterruptLevel = 0;
          _armRearm = true;
        }
      case 0x2800:
        if (value & 0x200 != 0) {
          throw const DcUnsupported('AICA development 8 MiB memory mode');
        }
        sound.control = value & 0x810f;
      case 0x280c:
        _writeMidi(value);
        sound.monitor = value & 0x7f00;
      case 0x289c:
        _scEnable = value & 0x7ff;
      case 0x28a0:
        _scPending |= value & 0x20;
      case 0x28a4:
        _scPending &= ~(value & 0x7ff);
      case 0x28a8:
      case 0x28ac:
      case 0x28b0:
        _levels[(offset - 0x28a8) ~/ 4] = value & 255;
      case 0x28b4:
        _mcEnable = value & 0x7ff;
      case 0x28b8:
        _mcPending |= value & 0x20;
      case 0x28bc:
        _mcPending &= ~(value & 0x7ff);
      case 0x2c00:
        if (fromArm) {
          throw const DcUnsupported('AICA reset control is SH4-only');
        }
        final wasReset = armReset;
        _resetControl = value & 0x301;
        if (wasReset != armReset) {
          if (armReset) arm.reset();
          _armPhase = 0;
          _armRemaining = 1;
        }
      default:
        throw DcUnsupported('unimplemented AICA write: '
            '${offset.toRadixString(16)}=${value.toRadixString(16)} '
            '(fromArm=$fromArm)');
    }
    _signal();
  }

  int _writeShadow(int offset) {
    if (DcAicaDsp.handles(offset)) return dsp.writeShadow(offset);
    if (DcAicaSound.outputRegister(offset)) return sound.readOutput(offset);
    if (DcAicaSound.channelRegister(offset)) return sound.read(offset);
    if (offset >= 0x2890 && offset <= 0x2898) {
      return _timers[(offset - 0x2890) ~/ 4];
    }
    if (offset >= 0x28a8 && offset <= 0x28b0) {
      return _levels[(offset - 0x28a8) ~/ 4];
    }
    return switch (offset) {
      0x2800 => sound.control,
      0x280c => sound.monitor,
      0x2880 => _memoryControl,
      0x2884 => _dmaMemoryLow,
      0x2888 => _dmaRegister,
      0x288c => _dmaControl,
      0x289c => _scEnable,
      0x28b4 => _mcEnable,
      0x2d04 => _readProtected ? 0x100 : 0,
      0x28a0 || 0x28a4 || 0x28b8 || 0x28bc => 0,
      _ => throw DcUnsupported(
          'unimplemented AICA ARM byte-write register: $offset'),
    };
  }

  /// Next enabled, unlatched request, avoiding per-sample idle polling,
  /// or the next ARM instruction.
  int? get clocksToEvent {
    final deviceEvent = clocksToDeviceEvent;
    if (armReset || memoryInhibit & 4 != 0) return deviceEvent;
    final armEvent =
        (_armRemaining * masterHz - _armPhase + armHz - 1) ~/ armHz;
    return deviceEvent == null || armEvent < deviceEvent
        ? armEvent
        : deviceEvent;
  }

  /// [clocksToEvent] without ARM instructions, which [tickMasterClocks]
  /// interleaves with the other AICA events by itself.
  int? get clocksToDeviceEvent {
    final needed = (_scEnable & ~_scPending) | (_mcEnable & ~_mcPending);
    int? samples = needed & 0x400 != 0 ? 1 : null;
    if (needsSampleClock) samples = 1;
    for (var i = 0; i < 3; i++) {
      if (needed & (0x40 << i) == 0) continue;
      final remaining =
          ((256 - (_timers[i] & 255)) << (_timers[i] >> 8)) - _timerPhase[i];
      if (samples == null || remaining < samples) samples = remaining;
    }
    final timerEvent = samples == null
        ? null
        : (samples * masterHz - _samplePhase + sampleHz - 1) ~/ sampleHz;
    final dmaEvent =
        internalDmaBusy ? (masterHz - _dmaPhase + armHz - 1) ~/ armHz : null;
    return dmaEvent == null
        ? timerEvent
        : timerEvent == null || dmaEvent < timerEvent
            ? dmaEvent
            : timerEvent;
  }

  /// Advances in steps that end at each event, including ARM instructions.
  /// The device event holds until a sample or an ARM register access may
  /// move it.
  void tickMasterClocks(int clocks) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    do {
      final event = clocksToDeviceEvent;
      final span = event == null || event >= clocks
          ? clocks
          : event < 1
              ? 1
              : event;
      var done = 0;
      _deviceChanged = false;
      do {
        var step = span - done;
        if (!armReset && memoryInhibit & 4 == 0) {
          final armEvent =
              (_armRemaining * masterHz - _armPhase + armHz - 1) ~/ armHz;
          if (armEvent < step) step = armEvent < 1 ? 1 : armEvent;
        }
        _advance(step);
        done += step;
      } while (done < span && !_deviceChanged);
      clocks -= done;
    } while (clocks > 0);
  }

  bool _deviceChanged = false;

  void _advance(int clocks) {
    // Short advances stay within one second or one sample; skip the divisions then.
    final rtcClocks = _rtcPhase + clocks;
    if (rtcClocks < masterHz) {
      _rtcPhase = rtcClocks;
    } else {
      _rtc = (_rtc + rtcClocks ~/ masterHz) & 0xffffffff;
      _rtcPhase = rtcClocks % masterHz;
    }
    final sampleClocks = _samplePhase + clocks * sampleHz;
    var samples = 0;
    if (sampleClocks < masterHz) {
      _samplePhase = sampleClocks;
    } else {
      samples = sampleClocks ~/ masterHz;
      _samplePhase = sampleClocks % masterHz;
    }
    if (samples != 0) {
      _deviceChanged = true;
      if (memoryInhibit & 2 != 0 && sound.readsWaveMemory) {
        throw const DcUnsupported(
            'AICA sound-source memory reads are inhibited');
      }
      sound.advance(samples,
          dspMemoryInhibited: memoryInhibit & 1 != 0,
          beforeSample: externalSample != null &&
                  ((externalActive?.call() ?? false) || _externalLatched)
              ? _sampleExternal
              : null);
      var requests = 0x400;
      for (var i = 0; i < 3; i++) {
        final divisor = 1 << (_timers[i] >> 8);
        final elapsed = _timerPhase[i] + samples;
        final count = (_timers[i] & 255) + elapsed ~/ divisor;
        _timerPhase[i] = elapsed % divisor;
        if (count >= 256) requests |= 0x40 << i;
        _timers[i] = (_timers[i] & 0x700) | (count & 255);
      }
      _scPending |= requests;
      _mcPending |= requests;
      _signal();
    }
    _tickDma(clocks);
    if (armReset) return;
    final armClocks = _armPhase + clocks * armHz;
    if (armClocks < masterHz) {
      _armPhase = armClocks;
    } else {
      _armPhase = armClocks % masterHz;
      _armRemaining -= armClocks ~/ masterHz;
    }
    if (memoryInhibit & 4 != 0) {
      if (_armRemaining < 1) _armRemaining = 1;
      return;
    }
    while (_armRemaining <= 0) {
      try {
        _armRearm = false;
        _captureArmInterrupt();
        arm.fiq = _armInterruptLevel != 0;
        _armRemaining += arm.step();
        if (arm.instructionExecuted) executedInstructions++;
      } on DcUnsupported {
        // A development stop must not leave a zero/negative scheduler deadline.
        _armRemaining = 1;
        rethrow;
      }
    }
  }

  void _requireDmaIdle() {
    if (internalDmaBusy) {
      throw const DcUnsupported('AICA DMA descriptor changed during transfer');
    }
  }

  void _startDma() {
    final length = _dmaControl & 0x7ffc;
    final memoryAddress = ((_memoryControl & 0xfe00) << 7) | _dmaMemoryLow;
    final registerAddress = _dmaRegister & 0x7ffc;
    if (length == 0) {
      throw const DcUnsupported(
          'AICA zero-length internal DMA needs hardware validation');
    }
    if (memoryAddress + length > memorySize ||
        registerAddress + length > 0x45c8) {
      throw const DcUnsupported(
          'AICA internal DMA exceeds an implemented aperture');
    }
    // The descriptor must not overwrite itself, regardless of transfer direction.
    if (registerAddress < 0x2890 && registerAddress + length > 0x2880) {
      throw const DcUnsupported(
          'AICA internal DMA overlaps its control registers');
    }
    _dmaMemoryCursor = memoryAddress;
    _dmaRegisterCursor = registerAddress;
    _dmaRemaining = length;
    _dmaPhase = 0;
  }

  void _tickDma(int clocks) {
    if (!internalDmaBusy) return;
    // Functional rate only: one longword per nominal AICA clock, without arbitration.
    final elapsed = _dmaPhase + clocks * armHz;
    var words = elapsed ~/ masterHz;
    _dmaPhase = elapsed % masterHz;
    while (words-- > 0 && internalDmaBusy) {
      try {
        final toMemory = _dmaControl & 0x8000 != 0;
        final clear = _dmaRegister & 0x8000 != 0;
        if (toMemory) {
          final value = clear ? 0 : read(_dmaRegisterCursor, 4);
          memory.setUint32LE(_dmaMemoryCursor, value);
        } else {
          final value = clear ? 0 : memory.getUint32LE(_dmaMemoryCursor);
          write(_dmaRegisterCursor, 4, value);
        }
        _dmaMemoryCursor += 4;
        _dmaRegisterCursor += 4;
        _dmaRemaining -= 4;
        if (!internalDmaBusy) {
          _scPending |= 0x10;
          _mcPending |= 0x10;
          _signal();
        }
      } on DcUnsupported {
        // Retain the failed word and a positive retry deadline without a false end.
        _dmaPhase = 0;
        rethrow;
      }
    }
  }

  int _armRead(int address, int size) {
    if (address >= 0 && address + size <= memorySize) {
      if (memoryInhibit & 4 != 0) {
        throw const DcUnsupported('AICA ARM memory access is inhibited');
      }
      return size == 1 ? memory[address] : memory.getUint32LE(address);
    }
    if (address >= 0x800000 && address < 0x808000 && address != 0x802c00) {
      _deviceChanged = true;
      return read(address - 0x800000, size, fromArm: true);
    }
    throw DcUnsupported('AICA ARM memory read at $address ($size bytes)');
  }

  /// Side-effect-free access to the ARM address space for debugger inspection.
  int peekArmByte(int address) {
    address &= 0xffffffff;
    if (address < memorySize) return memory[address];
    if (address >= 0x800000 && address < 0x808000 && address & ~3 != 0x802c00) {
      return (read((address - 0x800000) & ~3, 4,
                  sideEffects: false, fromArm: true) >>
              ((address & 3) * 8)) &
          255;
    }
    return (_armRead(address & 0xfffffffc, 4) >> ((address & 3) * 8)) & 255;
  }

  void _armWrite(int address, int size, int value) {
    if (address >= 0 && address + size <= memorySize) {
      if (memoryInhibit & 4 != 0) {
        throw const DcUnsupported('AICA ARM memory access is inhibited');
      }
      if (size == 1) {
        memory[address] = value;
      } else {
        memory.setUint32LE(address, value);
      }
      return;
    }
    if (address >= 0x800000 && address < 0x808000 && address != 0x802c00) {
      _deviceChanged = true;
      write(address - 0x800000, size, value, fromArm: true);
      return;
    }
    throw DcUnsupported('AICA ARM memory write at $address ($size bytes)');
  }
}

import 'dart:typed_data';

import '../../state.dart';

import 'aica_dsp_alu.dart';
import 'fault.dart';

/// DSP CPU-visible storage and mixer boundary, System Architecture section 8.4.5.
/// Functional MPRO layout is inferred from original manufacturer tool data; chip-level matching remains unverified.
class DcAicaDsp {
  // Host execution policies; saved program/register data remain unchanged.
  bool diagnosticBypassProgram = false;
  bool diagnosticBypassUnsupportedProgram = false;
  final alu = DcAicaDspAlu();
  final _coefficients = Uint16List(128), _addresses = Uint16List(64);
  final _program = Uint16List(512), _effects = Uint16List(16);
  final _temporary = Uint32List(128), _memory = Uint32List(32);
  final _memoryLow = Uint8List(32);
  final _mix = Uint32List(16), _external = Uint16List(2);
  int _programWords = 0, _ringControl = 0, _ringCounter = 0;
  bool _mixNonzero = false;
  bool _programValidated = false;
  DcUnsupported? _programFailure;
  bool get programBypassed =>
      hasProgram &&
      (diagnosticBypassProgram ||
          (diagnosticBypassUnsupportedProgram && _programFailure != null));
  String? get programUnsupportedReason => _programFailure?.message;
  bool _programUsesMemory = false;
  int _readAddress = -1, _writeAddress = -1, _writeValue = 0;
  int _readReturn = 0, _readValue = 0;
  bool _readReady = false;
  bool get hasPendingMemory =>
      !diagnosticBypassProgram &&
      (_readAddress >= 0 || _writeAddress >= 0 || _readReady);
  bool get hasProgram => _programWords != 0;
  bool get hasMix => _mixNonzero;
  int get ringControl => _ringControl;
  int get ringCounter => _ringCounter;
  int get ringLengthWords => 8192 << ((_ringControl >> 13) & 3);
  int get ringBaseBytes => (_ringControl & 0xfff) << 11;

  static bool handles(int offset) =>
      offset == 0x2804 ||
      (offset >= 0x3000 && offset < 0x3300) ||
      (offset >= 0x3400 && offset < 0x3c00) ||
      (offset >= 0x4000 && offset < 0x45c8);

  void reset() {
    alu.reset();
    for (final buffer in [
      _coefficients,
      _addresses,
      _program,
      _effects,
      _external
    ]) {
      buffer.fillRange(0, buffer.length, 0);
    }
    for (final buffer in [_temporary, _memory, _mix]) {
      buffer.fillRange(0, buffer.length, 0);
    }
    _memoryLow.fillRange(0, _memoryLow.length, 0);
    _programWords = _ringControl = _ringCounter = 0;
    _mixNonzero = false;
    _programValidated = false;
    _programFailure = null;
    _programUsesMemory = false;
    _readAddress = _writeAddress = -1;
    _writeValue = _readReturn = _readValue = 0;
    _readReady = false;
  }

  List<List<int>> get _stateBuffers => [
        _coefficients,
        _addresses,
        _program,
        _effects,
        _temporary,
        _memory,
        _memoryLow,
        _mix,
        _external
      ];

  /// Wave RAM and the sample scheduler are owned by AICA, not this component.
  void saveState(StateWriter writer) {
    writer.section('dc.aica.dsp');
    for (final buffer in _stateBuffers) {
      writer.ints(buffer);
    }
    writer.int32(_ringControl);
    if (_readAddress >= 0 ||
        _writeAddress >= 0 ||
        _writeValue != 0 ||
        _readReturn != 0 ||
        _readValue != 0 ||
        _readReady) {
      writer.int32(-1);
      writer.int32(_ringCounter);
      writer.ints([
        _readAddress,
        _writeAddress,
        _writeValue,
        _readReturn,
        _readValue,
        _readReady ? 1 : 0
      ]);
    } else {
      writer.int32(_ringCounter);
    }
    alu.saveState(writer);
  }

  void loadState(StateReader reader) {
    reader.section('dc.aica.dsp');
    final buffers = _stateBuffers;
    final values = [for (final _ in buffers) reader.ints()];
    final control = reader.int32(), marker = reader.int32();
    final counter = marker == -1 ? reader.int32() : marker;
    final pipeline = marker == -1 ? reader.ints() : [-1, -1, 0, 0, 0, 0];
    if (pipeline.length != 6 ||
        pipeline
            .take(2)
            .any((v) => v < -1 || v >= 0x200000 || (v >= 0 && v.isOdd)) ||
        pipeline.skip(2).take(3).any((v) => v < 0 || v > 0xffffff) ||
        pipeline[5] < 0 ||
        pipeline[5] > 1) {
      throw const StateMismatch('AICA DSP memory pipeline');
    }
    final latches = DcAicaDspAlu()..loadState(reader);
    const widths = [16, 16, 16, 16, 24, 24, 8, 20, 16];
    for (var i = 0; i < buffers.length; i++) {
      if (values[i].length != buffers[i].length ||
          values[i].any((value) => value < 0 || value >= (1 << widths[i]))) {
        throw const StateMismatch('AICA DSP buffer');
      }
    }
    if (control & ~0x6fff != 0 ||
        counter < 0 ||
        counter >= (8192 << ((control >> 13) & 3)) ||
        values[0].any((value) => value & 7 != 0)) {
      throw const StateMismatch('AICA DSP control state');
    }
    for (var i = 0; i < buffers.length; i++) {
      buffers[i].setAll(0, values[i]);
    }
    _ringControl = control;
    _ringCounter = counter;
    _programWords = _program.where((word) => word != 0).length;
    _programValidated = false;
    _programFailure = null;
    _programUsesMemory = false;
    _readAddress = pipeline[0];
    _writeAddress = pipeline[1];
    _writeValue = pipeline[2];
    _readReturn = pipeline[3];
    _readValue = pipeline[4];
    _readReady = pipeline[5] != 0;
    _mixNonzero = _mix.any((sample) => sample != 0);
    alu.accumulator = latches.accumulator;
    alu.fraction = latches.fraction;
    alu.address = latches.address;
    alu.yRegister = latches.yRegister;
  }

  int read(int offset) {
    if (offset == 0x2804) return _ringControl;
    if (offset >= 0x3000 && offset < 0x3200) {
      return _coefficients[(offset - 0x3000) ~/ 4];
    }
    if (offset >= 0x3200 && offset < 0x3300) {
      return _addresses[(offset - 0x3200) ~/ 4];
    }
    if (offset >= 0x3400 && offset < 0x3c00) {
      return _program[(offset - 0x3400) ~/ 4];
    }
    if (offset >= 0x4000 && offset < 0x4400) {
      final value = _temporary[(offset - 0x4000) ~/ 8];
      return offset & 4 == 0 ? value & 255 : value >> 8;
    }
    if (offset >= 0x4400 && offset < 0x4500) {
      final value = _memory[(offset - 0x4400) ~/ 8];
      return offset & 4 == 0 ? value & 255 : value >> 8;
    }
    if (offset >= 0x4500 && offset < 0x4580) {
      final value = _mix[(offset - 0x4500) ~/ 8];
      return offset & 4 == 0 ? value & 15 : value >> 4;
    }
    if (offset >= 0x4580 && offset < 0x45c0) {
      return _effects[(offset - 0x4580) ~/ 4];
    }
    if (offset >= 0x45c0 && offset < 0x45c8) {
      return _external[(offset - 0x45c0) ~/ 4];
    }
    throw const DcUnsupported('unimplemented AICA DSP register');
  }

  int writeShadow(int offset) =>
      offset >= 0x4400 && offset < 0x4500 && offset & 4 == 0
          ? _memoryLow[(offset - 0x4400) ~/ 8]
          : read(offset);

  void write(int offset, int value, {int mask = 0xffff}) {
    value = (writeShadow(offset) & ~mask) | (value & mask);
    value &= 0xffff;
    if (offset == 0x2804) {
      if (value & 0x8000 != 0) {
        throw const DcUnsupported('AICA DSP IC-test mode');
      }
      _ringControl = value & 0x6fff;
      _ringCounter &= ringLengthWords - 1;
    } else if (offset >= 0x3000 && offset < 0x3200) {
      _coefficients[(offset - 0x3000) ~/ 4] = value & 0xfff8;
    } else if (offset >= 0x3200 && offset < 0x3300) {
      _addresses[(offset - 0x3200) ~/ 4] = value;
    } else if (offset >= 0x3400 && offset < 0x3c00) {
      _programValidated = false;
      _programFailure = null;
      final index = (offset - 0x3400) ~/ 4;
      if (_program[index] != 0) _programWords--;
      _program[index] = value;
      if (value != 0) _programWords++;
    } else if (offset >= 0x4000 && offset < 0x4400) {
      final index = (offset - 0x4000) ~/ 8;
      _temporary[index] = offset & 4 == 0
          ? (_temporary[index] & 0xffff00) | (value & 255)
          : (_temporary[index] & 255) | (value << 8);
    } else if (offset >= 0x4400 && offset < 0x4500) {
      final index = (offset - 0x4400) ~/ 8;
      if (offset & 4 == 0) {
        _memoryLow[index] = value & 255;
      } else {
        final low =
            mask & 0xff00 != 0 ? _memoryLow[index] : _memory[index] & 255;
        _memory[index] = (value << 8) | low;
      }
    } else if (offset >= 0x4500 && offset < 0x4580) {
      // Retail BIOS initialization clears this mixer-owned area without IC-test.
      if (value & mask == 0) return;
      throw const DcUnsupported(
          'AICA MIXS writes require unimplemented IC-test mode');
    } else if (offset >= 0x4580 && offset < 0x45c0) {
      _effects[(offset - 0x4580) ~/ 4] = value;
    } else if (offset >= 0x45c0 && offset < 0x45c8) {
      return; // External input latches are read-only to both CPUs.
    } else {
      throw const DcUnsupported('unimplemented AICA DSP register');
    }
  }

  /// Arithmetic stage shared by functional MPRO execution and decoded diagnostics.
  /// TEMP addresses here are physical; rotating address generation is separate.
  int executeArithmetic(
      {required int coefficientAddress,
      required int temporaryReadAddress,
      required int inputAddress,
      int? temporaryWriteAddress,
      int? effectWriteAddress,
      int ySelect = 0,
      int shift = 0,
      bool xInput = false,
      bool bAccumulator = false,
      bool zero = false,
      bool negate = false,
      bool latchY = false,
      bool latchFraction = false,
      bool latchAddress = false}) {
    if (coefficientAddress < 0 ||
        coefficientAddress >= 128 ||
        temporaryReadAddress < 0 ||
        temporaryReadAddress >= 128 ||
        (temporaryWriteAddress != null &&
            (temporaryWriteAddress < 0 || temporaryWriteAddress >= 128)) ||
        (effectWriteAddress != null &&
            (effectWriteAddress < 0 || effectWriteAddress >= 16))) {
      throw ArgumentError('AICA DSP physical register address is out of range');
    }
    final input = inputAddress >= 0 && inputAddress < 32
        ? _memory[inputAddress].toSigned(24)
        : inputAddress >= 32 && inputAddress < 48
            ? _mix[inputAddress - 32].toSigned(20) * 16
            : inputAddress >= 48 && inputAddress < 50
                ? _external[inputAddress - 48].toSigned(16) * 256
                : throw const DcUnsupported('AICA DSP reserved input address');
    final output = alu.step(
        input: input,
        temporary: _temporary[temporaryReadAddress],
        coefficient: _coefficients[coefficientAddress],
        ySelect: ySelect,
        shift: shift,
        xInput: xInput,
        bAccumulator: bAccumulator,
        zero: zero,
        negate: negate,
        latchY: latchY,
        latchFraction: latchFraction,
        latchAddress: latchAddress);
    if (temporaryWriteAddress != null) {
      _temporary[temporaryWriteAddress] = output & 0xffffff;
    }
    if (effectWriteAddress != null) {
      _effects[effectWriteAddress] = (output >> 8) & 0xffff;
    }
    return output;
  }

  /// Complete samples without introducing an idle per-sample DSP poll.
  void advanceSamples(int samples) {
    if (samples < 0) throw ArgumentError.value(samples, 'samples');
    _ringCounter = (_ringCounter - samples % ringLengthWords) % ringLengthWords;
  }

  /// Decoded relative word address, AICA manual pages 36 and 39.
  int relativeWordAddress(int addressIndex,
      {bool table = false, bool addressEnabled = false, bool next = false}) {
    if (addressIndex < 0 || addressIndex >= 64) {
      throw ArgumentError.value(addressIndex, 'addressIndex');
    }
    // The documented address gate is 12 bits wide; provisionally zero-extend it.
    // Signed extension into the 16-bit adder has not been established on hardware.
    final sum = _addresses[addressIndex] +
        (addressEnabled ? alu.address & 0xfff : 0) +
        (table ? 0 : _ringCounter) +
        (next ? 1 : 0);
    return sum & (table ? 0xffff : ringLengthWords - 1);
  }

  int _waveAddress(Uint8List wave, int addressIndex,
      {required bool table,
      required bool addressEnabled,
      required bool next,
      required bool inhibited}) {
    if (inhibited) {
      throw const DcUnsupported('AICA DSP wave-memory access is inhibited');
    }
    // Retain the existing functional RBP byte-base policy pending board validation.
    final address = ringBaseBytes +
        relativeWordAddress(addressIndex,
                table: table, addressEnabled: addressEnabled, next: next) *
            2;
    if (address < 0 || address + 2 > wave.length) {
      throw const DcUnsupported('AICA DSP address exceeds retail wave memory');
    }
    return address;
  }

  /// Synchronous NOFL=1 backend transaction; request/return latency belongs to the executor.
  int readLinear(Uint8List wave, int addressIndex,
      {bool table = false,
      bool addressEnabled = false,
      bool next = false,
      bool inhibited = false,
      int? inputWriteAddress}) {
    if (inputWriteAddress != null &&
        (inputWriteAddress < 0 || inputWriteAddress >= 32)) {
      throw ArgumentError.value(inputWriteAddress, 'inputWriteAddress');
    }
    final address = _waveAddress(wave, addressIndex,
        table: table,
        addressEnabled: addressEnabled,
        next: next,
        inhibited: inhibited);
    final value =
        ((wave[address] | (wave[address + 1] << 8)).toSigned(16) * 256) &
            0xffffff;
    if (inputWriteAddress != null) _memory[inputWriteAddress] = value;
    return value;
  }

  /// Synchronous NOFL=1 backend write of the high sixteen signed sample bits.
  void writeLinear(Uint8List wave, int addressIndex, int value,
      {bool table = false,
      bool addressEnabled = false,
      bool next = false,
      bool inhibited = false}) {
    final address = _waveAddress(wave, addressIndex,
        table: table,
        addressEnabled: addressEnabled,
        next: next,
        inhibited: inhibited);
    wave[address] = (value >> 8) & 255;
    wave[address + 1] = (value >> 16) & 255;
  }

  void validateSample({bool memoryInhibited = false}) {
    if (diagnosticBypassProgram) return;
    if (hasProgram && !_programValidated) {
      _programUsesMemory = false;
      _programFailure = null;
      try {
        for (var step = 0; step < 128; step++) {
          final at = step * 4;
          final a = _program[at], b = _program[at + 1];
          final c = _program[at + 2], d = _program[at + 3];
          if (a & 1 != 0 || b & 1 != 0 || d & 0x403f != 0) {
            throw DcUnsupported(
                'AICA DSP reserved instruction bits at step $step');
          }
          if ((b >> 7) & 63 >= 50) {
            throw DcUnsupported(
                'AICA DSP reserved input selector at step $step');
          }
          if (c & 0x6000 != 0) {
            _programUsesMemory = true;
            if (step.isEven || c & 0x6000 == 0x6000) {
              throw DcUnsupported(
                  'AICA DSP unsupported memory request timing at step $step');
            }
            if (d & 0x8000 == 0) {
              throw DcUnsupported(
                  'AICA DSP floating sound-memory conversion is pending at step $step');
            }
          }
        }
      } on DcUnsupported catch (error) {
        _programFailure = error;
      }
      _programValidated = true;
    }
    if (hasProgram &&
        _programFailure != null &&
        !diagnosticBypassUnsupportedProgram) {
      throw _programFailure!;
    }
    if (memoryInhibited &&
        ((hasProgram && _programFailure == null && _programUsesMemory) ||
            hasPendingMemory)) {
      throw const DcUnsupported('AICA DSP wave-memory access is inhibited');
    }
  }

  /// One functional microprogram per sample; NOFL=0 conversion remains unsupported.
  /// Field order comes from FX Program Editor 1.10's bit-name table and original FPB register data.
  /// Reserved positions and odd memory-step placement were checked across 45 original manufacturer programs.
  void executeSample(Uint8List wave) {
    if (diagnosticBypassProgram) return;
    validateSample();
    if (!hasProgram || programBypassed) {
      // Retire requests already issued before the program was cleared or bypassed.
      _memoryCycle(wave);
      _memoryCycle(wave);
      return;
    }
    final rotation = _ringCounter & 127;
    for (var step = 0; step < 128; step++) {
      _memoryCycle(wave);
      final at = step * 4;
      final a = _program[at],
          b = _program[at + 1],
          c = _program[at + 2],
          d = _program[at + 3];
      // Address generation observes the old address latch, before this step's ADRL write.
      final address = c & 0x6000 == 0
          ? -1
          : _waveAddress(wave, (d >> 8) & 63,
              table: c & 0x8000 != 0,
              addressEnabled: d & 0x80 != 0,
              next: d & 0x40 != 0,
              inhibited: false);
      final output = executeArithmetic(
          coefficientAddress: step,
          temporaryReadAddress: ((a >> 9) + rotation) & 127,
          temporaryWriteAddress:
              a & 0x100 != 0 ? ((a >> 1) + rotation) & 127 : null,
          inputAddress: (b >> 7) & 63,
          effectWriteAddress: c & 0x1000 != 0 ? (c >> 8) & 15 : null,
          xInput: b & 0x8000 != 0,
          ySelect: (b >> 13) & 3,
          shift: (c >> 4) & 3,
          latchAddress: c & 0x80 != 0,
          latchFraction: c & 0x40 != 0,
          latchY: c & 8 != 0,
          negate: c & 4 != 0,
          zero: c & 2 != 0,
          bAccumulator: c & 1 != 0);
      // The manual's step-1 MRD reaches IWT at step 3, then IRA at step 4.
      // Reading INPUTS/TEMP precedes their writes within the same step.
      if (b & 0x40 != 0) _memory[(b >> 1) & 31] = _readValue;
      if (c & 0x2000 != 0) _readAddress = address;
      if (c & 0x4000 != 0) {
        _writeAddress = address;
        _writeValue = output & 0xffffff;
      }
    }
  }

  void _memoryCycle(Uint8List wave) {
    if (_readReady) {
      _readValue = _readReturn;
      _readReturn = 0;
      _readReady = false;
    }
    if (_readAddress >= 0) {
      if (_readAddress + 1 >= wave.length) {
        throw const DcUnsupported('AICA DSP pending read exceeds wave memory');
      }
      _readReturn =
          ((wave[_readAddress] | (wave[_readAddress + 1] << 8)).toSigned(16) *
                  256) &
              0xffffff;
      _readReady = true;
      _readAddress = -1;
    }
    if (_writeAddress >= 0) {
      if (_writeAddress + 1 >= wave.length) {
        throw const DcUnsupported('AICA DSP pending write exceeds wave memory');
      }
      wave[_writeAddress] = (_writeValue >> 8) & 255;
      wave[_writeAddress + 1] = (_writeValue >> 16) & 255;
      _writeAddress = -1;
      _writeValue = 0;
    }
  }

  void latchMix(Float64List samples) {
    _mixNonzero = false;
    for (var i = 0; i < 16; i++) {
      // Functional nearest-integer conversion and 20-bit wrap, not measured mixer arithmetic.
      _mix[i] = (samples[i] * 0x80000).round() & 0xfffff;
      if (_mix[i] != 0) _mixNonzero = true;
    }
  }

  void setExternalInput(int left, int right) {
    _external[0] = left & 0xffff;
    _external[1] = right & 0xffff;
  }

  int output(int index) => index < 16 && programBypassed
      ? 0
      : (index < 16 ? _effects[index] : _external[index - 16]).toSigned(16);
}

import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/aica.dart';
import 'package:fnesemu_core/src/core/dc/aica_dsp.dart';
import 'package:fnesemu_core/src/core/dc/aica_sound.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:test/test.dart';

void main() {
  late DcAicaDsp dsp;
  late Uint8List wave;
  setUp(() {
    dsp = DcAicaDsp();
    wave = Uint8List(0x200000);
  });
  test(
      'all four ring sizes decrement once per sample and wrap in constant time',
      () {
    for (var size = 0; size < 4; size++) {
      dsp.reset();
      dsp.write(0x2804, size << 13);
      final length = 8192 << size;
      expect(dsp.ringCounter, 0);
      dsp.advanceSamples(1);
      expect(dsp.ringCounter, length - 1);
      dsp.advanceSamples(length - 1);
      expect(dsp.ringCounter, 0);
      dsp.advanceSamples(1000000000000 + 17);
      expect(
          dsp.ringCounter, (length - (1000000000000 + 17) % length) % length);
    }
  });
  test('TABLE gates both decrement offset and ring-length mask', () {
    dsp.write(0x3200, 0x9000);
    dsp.advanceSamples(3);
    expect(dsp.relativeWordAddress(0), 0xffd);
    expect(dsp.relativeWordAddress(0, table: true), 0x9000);
    expect(dsp.relativeWordAddress(0, table: true, next: true), 0x9001);
  });
  test('MADRS, address latch and NXADR add before word-address wrap', () {
    dsp.write(0x32fc, 0xffff);
    dsp.alu.address = 2;
    expect(dsp.relativeWordAddress(63, table: true), 0xffff);
    expect(dsp.relativeWordAddress(63, table: true, next: true), 0);
    expect(dsp.relativeWordAddress(63, table: true, addressEnabled: true), 1);
    expect(
        dsp.relativeWordAddress(63,
            table: true, addressEnabled: true, next: true),
        2);
    dsp.alu.address = 0xfff;
    expect(dsp.relativeWordAddress(0), 0);
    expect(
        dsp.relativeWordAddress(63, table: true, addressEnabled: true), 0xffe);
  });
  test('ring resize masks the retained counter without resetting its phase',
      () {
    dsp.write(0x2804, 3 << 13);
    dsp.advanceSamples(1);
    expect(dsp.ringCounter, 65535);
    dsp.write(0x2804, 0);
    expect(dsp.ringCounter, 8191);
    expect(() => dsp.advanceSamples(-1), throwsArgumentError);
    expect(dsp.ringCounter, 8191);
  });
  test(
      'NOFL transactions align signed sixteen-bit wave data with 24-bit samples',
      () {
    dsp.write(0x3200, 5);
    for (final value in [0, 0x7fffff, 0x800000, 0xffffff, 0x123456]) {
      dsp.writeLinear(wave, 0, value, table: true);
      expect(dsp.readLinear(wave, 0, table: true), value & 0xffff00);
      expect(wave[9], 0);
      expect(wave[12], 0);
    }
  });
  test('functional RBP base and word offsets leave neighboring bytes untouched',
      () {
    dsp.write(0x2804, 1);
    dsp.write(0x3200, 7);
    dsp.writeLinear(wave, 0, 0x812345, table: true);
    expect(wave.sublist(2048 + 12, 2048 + 18), [0, 0, 0x23, 0x81, 0, 0]);
    expect(dsp.readLinear(wave, 0, table: true), 0x812300);
  });
  test('read result can enter MEMS without destroying a pending CPU low byte',
      () {
    dsp.write(0x4400, 0xaa);
    wave[0] = 0x34;
    wave[1] = 0x12;
    expect(dsp.readLinear(wave, 0, inputWriteAddress: 0), 0x123400);
    expect(dsp.read(0x4400), 0);
    expect(dsp.read(0x4404), 0x1234);
    dsp.write(0x4404, 0x5678);
    expect(dsp.read(0x4400), 0xaa);
    expect(dsp.read(0x4404), 0x5678);
  });
  test('inhibited accesses and invalid destinations are atomic', () {
    wave[0] = 0x55;
    expect(() => dsp.writeLinear(wave, 0, 0xffffff, inhibited: true),
        throwsA(isA<DcUnsupported>()));
    expect(() => dsp.readLinear(wave, 0, inhibited: true, inputWriteAddress: 0),
        throwsA(isA<DcUnsupported>()));
    expect(() => dsp.readLinear(wave, 0, inputWriteAddress: 32),
        throwsArgumentError);
    expect(wave[0], 0x55);
    expect(dsp.read(0x4400), 0);
    expect(dsp.read(0x4404), 0);
  });
  test('out-of-range retail wave addresses stop without wrapping memory', () {
    dsp.write(0x2804, 0xfff);
    expect(() => dsp.readLinear(wave, 0), throwsA(isA<DcUnsupported>()));
    expect(() => dsp.writeLinear(wave, 0, 0x123456),
        throwsA(isA<DcUnsupported>()));
    expect(wave, everyElement(0));
  });
  test(
      'decoded linear memory, ALU and effect output form an explicit data path',
      () {
    wave[1] = 0xc0;
    dsp.readLinear(wave, 0, inputWriteAddress: 3);
    dsp.write(0x3000, 0x8000);
    dsp.executeArithmetic(
        coefficientAddress: 0,
        temporaryReadAddress: 0,
        inputAddress: 3,
        xInput: true,
        ySelect: 1,
        zero: true);
    final shifted = dsp.executeArithmetic(
        coefficientAddress: 0,
        temporaryReadAddress: 0,
        inputAddress: 0,
        zero: true,
        effectWriteAddress: 0);
    dsp.writeLinear(wave, 0, shifted, table: true, next: true);
    expect(wave.sublist(0, 4), [0, 0xc0, 0, 0x40]);
    expect(dsp.output(0), 0x4000);
  });
  test('idle and audible mixer samples advance the same ring phase', () {
    final sound = DcAicaSound(wave, dsp: dsp);
    sound.advance(10000);
    expect(dsp.ringCounter, (-10000) % 8192);
    final packets = <AudioBuffer>[];
    sound.setAudio(packets.add);
    sound.advance(256);
    expect(dsp.ringCounter, (-10256) % 8192);
    expect(packets.single.buffer, everyElement(0));
  });
  test('reserved MPRO bits stop before counter or source advancement', () {
    final sound = DcAicaSound(wave, dsp: dsp);
    dsp.write(0x3400, 1);
    expect(() => sound.advance(1), throwsA(isA<DcUnsupported>()));
    expect(dsp.ringCounter, 0);
    dsp.reset();
    expect(dsp.ringCounter, 0);
  });
  test('AICA master clock chunks and idle batches yield equal counter phase',
      () {
    final large = DcAica(onInterrupt: (_) {}),
        small = DcAica(onInterrupt: (_) {});
    const clocks = 1234567;
    large.tickMasterClocks(clocks);
    for (var left = clocks; left > 0;) {
      final chunk = left < 997 ? left : 997;
      small.tickMasterClocks(chunk);
      left -= chunk;
    }
    expect(large.dsp.ringCounter, small.dsp.ringCounter);
    expect(large.dsp.ringCounter, -(clocks * 44100 ~/ DcAica.masterHz) % 8192);
  });
}

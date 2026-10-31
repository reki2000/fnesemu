import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/aica.dart';
import 'package:fnesemu_core/src/core/dc/aica_sound.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const base = 0xa0700000;
  late Dc core;
  late List<AudioBuffer> packets;
  int clocks(int samples) => (samples * DcAica.masterHz + 44099) ~/ 44100;
  void configure(int slot,
      {int format = 0,
      int end = 255,
      int pan = 0,
      int pitch = 0,
      bool loop = false,
      int loopStart = 0,
      int send = 15}) {
    final bus = core.bus, address = base + slot * 0x80;
    bus.write32(address, 0x4000 | (format << 7) | (loop ? 0x200 : 0));
    bus.write32(address + 4, 0x1000);
    bus.write32(address + 8, loopStart);
    bus.write32(address + 12, end);
    bus.write32(address + 0x10, 31);
    bus.write32(address + 0x14, 0x3fe0);
    bus.write32(address + 0x18, pitch);
    bus.write32(address + 0x24, (send << 8) | pan);
    bus.write32(address + 0x28, 4);
    for (var i = 0x2c; i <= 0x3c; i += 4) {
      bus.write32(address + i, 0x1ff8);
    }
  }

  void key(int slot, {int format = 0, bool loop = false, bool on = true}) =>
      core.bus.write32(base + slot * 0x80,
          0x8000 | (on ? 0x4000 : 0) | (format << 7) | (loop ? 0x200 : 0));
  setUp(() {
    core = Dc();
    packets = [];
    core.onAudio(packets.add);
    core.bus.write32(base + 0x2800, 15);
  });

  test('PCM16 emits signed stereo samples through the Core audio callback', () {
    configure(0);
    const source = [-32768, -16384, 0, 16384, 32767];
    for (var i = 0; i < 256; i++) {
      core.bus.aica.memory
          .setUint16LE(0x1000 + i * 2, source[i % source.length]);
    }
    key(0);
    core.bus.tickMasterClocks(clocks(256));
    expect(packets, hasLength(1));
    expect(packets.single.sampleRate, 44100);
    expect(packets.single.channels, 2);
    for (var i = 0; i < 256; i++) {
      expect(packets.single.buffer[i * 2], source[i % source.length] / 32768);
      expect(
          packets.single.buffer[i * 2 + 1], source[i % source.length] / 32768);
    }
    expect(core.bus.aica.sound.active, isFalse);
    expect(core.bus.read32(base + 0x2814), 255);
  });

  test('envelope gain falls 96 dB over the attenuation range', () {
    for (final attenuation in [0.0, 1.0, 100.25, 511.5, 1022.75, 1023.0]) {
      final gain = math.pow(10, -96 * attenuation / (1023 * 20));
      expect(DcAicaSound.envelopeGain(attenuation), closeTo(gain, gain * 1e-4));
    }
  });

  test('PCM8 sign extension and pan endpoints preserve the unattenuated side',
      () {
    configure(0, format: 1, pan: 15);
    core.bus.aica.memory.fillRange(0x1000, 0x1100, 0x80);
    key(0, format: 1);
    core.bus.tickMasterClocks(clocks(256));
    expect(packets.single.buffer, [
      for (var i = 0; i < 256; i++) ...[0.0, -1.0]
    ]);
  });

  test('all 64 slots key on together and the mixer clips at the DAC boundary',
      () {
    for (var slot = 0; slot < 64; slot++) {
      configure(slot);
    }
    for (var i = 0; i < 256; i++) {
      core.bus.aica.memory.setUint16LE(0x1000 + i * 2, 1000);
    }
    key(63);
    core.bus.tickMasterClocks(clocks(256));
    expect(packets.single.buffer, everyElement(32767 / 32768));
    expect(core.bus.read32(base + 63 * 0x80) & 0x8000, 0);
  });

  test(
      'fractional pitch interpolates adjacent PCM samples and preserves loop fraction',
      () {
    configure(0, pitch: 0x7800, loop: true, loopStart: 0, end: 2); // OCT=-1.
    core.bus.aica.memory.setUint16LE(0x1000, 0);
    core.bus.aica.memory.setUint16LE(0x1002, 16384);
    core.bus.aica.memory.setUint16LE(0x1004, 0);
    key(0, loop: true);
    core.bus.tickMasterClocks(clocks(256));
    expect([for (var i = 0; i < 8; i++) packets.single.buffer[i * 2]],
        [0.0, 0.25, 0.5, 0.25, 0.0, 0.25, 0.5, 0.25]);
    final status = core.bus.read32(base + 0x2810, peek: true);
    expect(status & 0x8000, 0x8000);
    expect(core.bus.read32(base + 0x2810) & 0x8000, 0x8000);
    expect(core.bus.read32(base + 0x2810) & 0x8000, 0);
  });

  test('ADPCM uses low nibble first and the original quantization factors', () {
    configure(0, format: 2);
    core.bus.aica.memory.fillRange(0x1000, 0x1080, 0);
    core.bus.aica.memory.setRange(0x1000, 0x1004, [0x10, 0x32, 0x54, 0x76]);
    key(0, format: 2);
    core.bus.tickMasterClocks(clocks(256));
    // Deltas 15,47,79,111 then 142; the step stays at its minimum through code 3.
    expect([
      for (var i = 0; i < 8; i++) packets.single.buffer[i * 2]
    ], [
      15 / 32768,
      62 / 32768,
      141 / 32768,
      252 / 32768,
      394 / 32768,
      603 / 32768,
      996 / 32768,
      1903 / 32768
    ]);
    core.reset();
    packets.clear();
    core.bus.write32(base + 0x2800, 15);
    configure(0, format: 2);
    core.bus.aica.memory.fillRange(0x1000, 0x1080, 0x88);
    key(0, format: 2);
    core.bus.tickMasterClocks(clocks(256));
    expect([for (var i = 0; i < 3; i++) packets.single.buffer[i * 2]],
        [-15 / 32768, -30 / 32768, -45 / 32768]);
  });

  test('audio packets own their buffers and full reset discards partial output',
      () {
    configure(0, loop: true, end: 2);
    core.bus.aica.memory.setUint16LE(0x1000, 16384);
    core.bus.aica.memory.setUint16LE(0x1002, 16384);
    core.bus.aica.memory.setUint16LE(0x1004, 16384);
    key(0, loop: true);
    core.bus.tickMasterClocks(clocks(256));
    final saved = Float32List.fromList(packets.single.buffer);
    core.bus.tickMasterClocks(clocks(300));
    expect(packets.first.buffer, saved);
    expect(identical(packets[0].buffer, packets[1].buffer), isFalse);
    core.reset();
    packets.clear();
    core.bus.tickMasterClocks(clocks(DcAicaSound.packetFrames));
    expect(packets, hasLength(1));
    expect(packets.single.buffer, everyElement(0));
  });

  test(
      'direct send, total level and master volume apply the published dB gains',
      () {
    configure(0, pan: 1, send: 14);
    core.bus.aica.memory.fillRange(0x1000, 0x1200, 0);
    for (var i = 0; i < 256; i++) {
      core.bus.aica.memory.setUint16LE(0x1000 + i * 2, 16384);
    }
    core.bus.write32(base + 0x28, 0x1004); // TL bit 4: -6 dB.
    core.bus.write32(base + 0x2800, 14); // MVOL: -3 dB.
    key(0);
    core.bus.tickMasterClocks(clocks(256));
    expect(packets.single.buffer[0],
        closeTo(0.0889139705, 1e-7)); // -15 dB at half scale.
    expect(packets.single.buffer[1],
        closeTo(0.1255943216, 1e-7)); // -12 dB at half scale.
  });

  test(
      'key-off enters release and the nominal envelope eventually becomes silent',
      () {
    configure(0, loop: true, end: 2);
    for (var i = 0; i < 3; i++) {
      core.bus.aica.memory.setUint16LE(0x1000 + i * 2, 16384);
    }
    core.bus.write32(
        base + 0x14, 0x3fff); // RR=31, scaling disabled: rate 62, 3.6 ms.
    key(0, loop: true);
    core.bus.tickMasterClocks(clocks(1));
    key(0, loop: true, on: false);
    expect((core.bus.read32(base + 0x2810) >> 13) & 3, 3);
    core.bus.tickMasterClocks(clocks(255));
    expect(packets.single.buffer[0], 0.5);
    expect(packets.single.buffer[2], lessThan(0.5));
    expect(packets.single.buffer.last, 0);
    expect(core.bus.aica.sound.active, isFalse);
  });

  test('a self-authored SH4 instruction starts the PCM source through MMIO',
      () {
    core.setRom(Uint8List.fromList([2, 0x21, 0xfe, 0xaf, 9, 0]));
    configure(0);
    core.bus.write32(base + 0x2800, 15);
    for (var i = 0; i < 256; i++) {
      core.bus.aica.memory.setUint16LE(0x1000 + i * 2, 8192);
    }
    core.cpu.r[0] = 0xc000;
    core.cpu.r[1] = base;
    expect(core.exec(false).stopped, isFalse, reason: core.stopReason);
    core.bus.tickMasterClocks(clocks(256));
    expect(packets.single.buffer, everyElement(0.25));
  });

  test('rate 31 uses the standalone specification correction of 790 ms', () {
    configure(0, loop: true, pitch: 512);
    for (var i = 0; i < 256; i++) {
      core.bus.aica.memory.setUint16LE(0x1000 + i * 2, 16384);
    }
    core.bus.write32(
        base + 0x14, 0x03ef); // KRS=0, RR=15 and FNS[9]=1 produce rate 31.
    key(0, loop: true);
    core.bus.tickMasterClocks(clocks(1));
    key(0, loop: true, on: false);
    core.bus.tickMasterClocks(
        20000000); // 100 ms is shorter than the corrected release time.
    expect(core.bus.aica.sound.active, isTrue);
    expect(core.bus.read32(base + 0x2810) & 1023, 129);
  });

  test('batched audio matches individual clocks with shared wave-RAM DMA', () {
    final single = Dc();
    final singlePackets = <AudioBuffer>[];
    single.onAudio(singlePackets.add);
    configure(0, loop: true, end: 2);
    key(0, loop: true);
    for (var offset = 0; offset <= 0x44; offset += 4) {
      single.bus.write32(base + offset, core.bus.read32(base + offset));
    }
    single.bus.write32(base + 0x2800, 15);
    single.bus.write32(base, 0xc200);
    for (final target in [core, single]) {
      target.bus.ram.setUint32LE(0x20000, 0x40004000);
      target.bus.write32(0xffa00000, 0x0c020000);
      target.bus.write32(0xffa00004, 0x00801000);
      target.bus.write32(0xffa00008, 1);
      target.bus.write32(0xffa0000c, 0x5435);
      target.bus.write32(0xffa00040, 1);
    }
    final total = clocks(256);
    core.bus.tickMasterClocks(total);
    for (var i = 0; i < total; i++) {
      single.bus.tickMasterClocks(1);
    }
    expect(packets.single.buffer, singlePackets.single.buffer);
    expect(core.bus.read32(base + 0x2814), single.bus.read32(base + 0x2814));
  });

  test(
      'a standalone SH4 diagnostic initializes waveform and channels without host setup',
      () {
    final ops = <int>[];
    final literals = <(int, int)>[];
    void load(int register, int value) {
      literals.add((ops.length, value));
      ops.add(0xd000 | (register << 8));
    }

    void store(int address, int value) {
      load(0, value);
      load(1, address);
      ops.add(0x2102);
    }

    load(0, 0x20002000);
    load(1, 0xa0801000);
    load(2, 128);
    final loop = ops.length;
    ops.addAll([0x2102, 0x7104, 0x4210]); // Store, advance, decrement and test.
    ops.add(0x8b00 | ((loop - (ops.length + 2)) & 255));
    store(base, 0x4000);
    store(base + 4, 0x1000);
    store(base + 8, 0);
    store(base + 12, 255);
    store(base + 0x10, 31);
    store(base + 0x14, 0x3fe0);
    store(base + 0x18, 0);
    store(base + 0x1c, 0);
    store(base + 0x20, 0);
    store(base + 0x24, 0xf00);
    store(base + 0x28, 4);
    for (var offset = 0x2c; offset <= 0x3c; offset += 4) {
      store(base + offset, 0x1ff8);
    }
    store(base + 0x2800, 15);
    store(base, 0xc000);
    ops.addAll([0xaffe, 9]);
    if (ops.length.isOdd) ops.add(9);
    final poolStart = ops.length * 2;
    final program = Uint8List(poolStart + literals.length * 4);
    for (final (i, literal) in literals.indexed) {
      final (instruction, value) = literal;
      final address = poolStart + i * 4;
      final displacement = (address - ((instruction * 2 + 4) & ~3)) ~/ 4;
      expect(displacement, inInclusiveRange(0, 255));
      ops[instruction] |= displacement;
      program.setUint32LE(address, value);
    }
    for (final (i, op) in ops.indexed) {
      program.setUint16LE(i * 2, op);
    }
    core.setRom(program);
    for (var i = 0; i < 2000000 && packets.isEmpty; i++) {
      expect(core.exec(false).stopped, isFalse, reason: core.stopReason);
    }
    expect(packets, hasLength(1));
    expect(packets.single.buffer, everyElement(0.25));
    expect(core.bus.aica.memory.getUint32LE(0x1000), 0x20002000);
  });
}

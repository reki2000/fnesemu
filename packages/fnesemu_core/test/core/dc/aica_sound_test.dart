import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/aica.dart';
import 'package:fnesemu_core/src/core/dc/aica_sound.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
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
    addTearDown(core.dispose);
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

  test('clearing KYONB with the source of a held ADPCM voice retires it', () {
    configure(0, format: 2, loop: true);
    core.bus.aica.memory.fillRange(0x1000, 0x1080, 0x17);
    key(0, format: 2, loop: true);
    core.bus.tickMasterClocks(clocks(64));
    expect(core.bus.aica.sound.active, isTrue);
    // a source change that keeps KYONB is still rejected
    expect(() => core.bus.write32(base, 0x4000), throwsA(isA<DcUnsupported>()));
    core.bus.write32(base, 0);
    expect(core.bus.aica.sound.active, isFalse);
    core.bus.write32(base, 0x8000);
    core.bus.tickMasterClocks(clocks(64));
    expect(core.bus.aica.sound.active, isFalse);
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

  test('batched audio matches individual clocks with shared wave-RAM DMA', () {
    final single = Dc();
    addTearDown(single.dispose);
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
}

import 'package:fnesemu_core/src/core/dc/aica.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const base = 0xa0700000;
  late Dc core;
  late List<AudioBuffer> packets;
  DcAica getChip() => core.bus.aica;
  int clocks(int samples) => (samples * DcAica.masterHz + 44099) ~/ 44100;
  void write(int offset, int value) => core.bus.write32(base + offset, value);
  int read(int offset) => core.bus.read32(base + offset);
  int mix(int index) =>
      (read(0x4500 + index * 8) | (read(0x4504 + index * 8) << 4)).toSigned(20);
  void configure(int slot,
      {int sample = 16384,
      int input = 0,
      int dspSend = 15,
      int directSend = 0,
      int pan = 0,
      int level = 0,
      int end = 255}) {
    final offset = slot * 0x80, start = 0x1000 + slot * 0x400;
    write(offset, 0x4000 | (start >> 16));
    write(offset + 4, start & 0xffff);
    write(offset + 12, end);
    write(offset + 0x10, 31);
    write(offset + 0x14, 15 << 10);
    write(offset + 0x20, (dspSend << 4) | input);
    write(offset + 0x24, (directSend << 8) | pan);
    write(offset + 0x28, (level << 8) | 4);
    for (var reg = 0x2c; reg <= 0x3c; reg += 4) {
      write(offset + reg, 0x1ff8);
    }
    for (var i = 0; i <= end; i++) {
      getChip().memory.setUint16LE(start + i * 2, sample);
    }
  }

  void key([int slot = 0]) => write(slot * 0x80, read(slot * 0x80) | 0x8000);
  void frames([int count = 256]) => core.bus.tickMasterClocks(clocks(count));
  setUp(() {
    core = Dc();
    packets = [];
    core.onAudio(packets.add);
    write(0x2800, 15);
  });

  test('COEF and MADRS expose their documented count and bit widths', () {
    write(0x3000, 0xffff);
    write(0x31fc, 0x123f);
    expect(read(0x3000), 0xfff8);
    expect(read(0x31fc), 0x1238);
    write(0x3200, 0xffff);
    write(0x32fc, 0xabcd);
    expect(read(0x3200), 0xffff);
    expect(read(0x32fc), 0xabcd);
    expect(() => read(0x3300), throwsA(isA<DcUnsupported>()));
  });

  test('MPRO stores all four halfwords at both ends without guessing opcodes',
      () {
    for (final (i, value) in [0x1234, 0x5678, 0x9abc, 0xdef0].indexed) {
      write(0x3400 + i * 4, value);
      write(0x3bf0 + i * 4, value);
      expect(read(0x3400 + i * 4), value);
      expect(read(0x3bf0 + i * 4), value);
    }
    expect(getChip().dsp.hasProgram, isTrue);
    for (final start in [0x3400, 0x3bf0]) {
      for (var i = 0; i < 4; i++) {
        write(start + i * 4, 0);
      }
    }
    expect(getChip().dsp.hasProgram, isFalse);
    expect(() => read(0x3c00), throwsA(isA<DcUnsupported>()));
  });

  test('TEMP has independent low-byte and high-halfword access to 128 entries',
      () {
    write(0x4000, 0x12ef);
    expect(read(0x4000), 0xef);
    write(0x4004, 0xabcd);
    expect(read(0x4004), 0xabcd);
    write(0x43f8, 0xff);
    write(0x43fc, 0xffff);
    expect(read(0x43f8), 0xff);
    expect(read(0x43fc), 0xffff);
    expect(read(0x4000), 0xef);
  });

  test('MEMS low bytes are committed only by writes to the upper byte', () {
    write(0x4400, 0x11);
    expect(read(0x4400), 0);
    write(0x4404, 0x1234);
    expect(read(0x4400), 0x11);
    getChip().write(0x4400, 1, 0x56, fromArm: true);
    getChip().write(0x4404, 1, 0x78, fromArm: true);
    expect(read(0x4404), 0x1278);
    expect(read(0x4400), 0x11);
    getChip().write(0x4405, 1, 0x9a, fromArm: true);
    expect(read(0x4404), 0x9a78);
    expect(read(0x4400), 0x56);
    getChip().write(0x4401, 1, 0xff, fromArm: true);
    write(0x4404, 0xabcd);
    expect(read(0x4400), 0x56);
  });

  test(
      'DSP and output controls support ARM byte lanes while SH4 requires longwords',
      () {
    getChip().write(0x3000, 1, 0xff, fromArm: true);
    getChip().write(0x3001, 1, 0x12, fromArm: true);
    expect(read(0x3000), 0x12f8);
    getChip().write(0x2001, 1, 15, fromArm: true);
    getChip().write(0x2000, 1, 31, fromArm: true);
    expect(read(0x2000), 0xf1f);
    getChip().write(0x3402, 1, 255, fromArm: true);
    expect(getChip().dsp.hasProgram, isFalse);
    expect(() => core.bus.read16(base + 0x3000), throwsA(isA<DcUnsupported>()));
  });

  test('ring controls retain RBL and RBP while rejecting IC-test mode', () {
    write(0x2804, 0x7fff);
    expect(read(0x2804), 0x6fff);
    expect(getChip().dsp.ringLengthWords, 65536);
    expect(getChip().dsp.ringBaseBytes, 0x7ff800);
    expect(() => write(0x2804, 0x8000), throwsA(isA<DcUnsupported>()));
    expect(read(0x2804), 0x6fff);
  });

  test('MIXS writes reject ordinary CPU use and EXTS ignores CPU writes', () {
    expect(() => write(0x4500, 1), throwsA(isA<DcUnsupported>()));
    expect(() => write(0x4504, 1), throwsA(isA<DcUnsupported>()));
    getChip().dsp.setExternalInput(-16384, 8192);
    write(0x45c0, 1);
    expect(read(0x45c0), 0xc000);
    expect(read(0x45c4), 0x2000);
    expect(() => read(0x45c8), throwsA(isA<DcUnsupported>()));
  });

  test('effect controls mask reserved bits in all 18 mixer slots', () {
    for (var i = 0; i < 18; i++) {
      write(0x2000 + i * 4, 0xffff);
      expect(read(0x2000 + i * 4), 0xf1f);
    }
    expect(() => read(0x2048), throwsA(isA<DcUnsupported>()));
  });

  test('slot outputs sum into independently selected signed 20-bit MIXS inputs',
      () {
    configure(0, sample: 16384, input: 3);
    configure(1, sample: 8192, input: 3);
    configure(2, sample: -4096, input: 5);
    key(2);
    frames(1);
    expect(mix(3), 0x60000);
    expect(mix(5), -0x10000);
    expect(mix(0), 0);
    expect(read(0x4528), 0);
    expect(read(0x452c), 0xf000);
  });

  test('the later System Architecture IMXL/ISEL layout takes precedence', () {
    configure(0, input: 9);
    write(0x24, 0xf000);
    key();
    frames(1);
    expect(read(0x20), 0xf9);
    expect(read(0x24), 0);
    expect(mix(9), 0x40000);
  });

  test('DSP send is independent of direct send and direct pan', () {
    configure(0, input: 2, directSend: 15, pan: 15);
    key();
    frames();
    expect(mix(2), 0x40000);
    expect(packets.single.buffer[0], 0);
    expect(packets.single.buffer[1], 0.5);
  });

  test('DSP input applies total level and IMXL before 20-bit quantization', () {
    configure(0, dspSend: 14, level: 0x10);
    key();
    frames(1);
    expect(
        mix(0), 93012); // Half scale with the documented -6 dB and -3 dB gains.
  });

  test('unprotected MIXS overflow follows the explicit functional wrap policy',
      () {
    configure(0, sample: 32767);
    configure(1, sample: 32767);
    key(1);
    frames(1);
    expect(mix(0), -32);
  });

  test(
      'MIXS clears on the sample after the last voice even without an audio sink',
      () {
    core = Dc();
    write(0x2800, 15);
    configure(0, end: 0);
    key();
    frames(1);
    expect(mix(0), 0x40000);
    expect(getChip().sound.active, isFalse);
    expect(getChip().clocksToEvent, isNotNull);
    frames(1);
    expect(mix(0), 0);
    expect(getChip().sound.needsSampleClock, isFalse);
  });

  test(
      'CPU-defined EFREG values reach stereo audio with independent effect pan',
      () {
    write(0x4580, 16384);
    write(0x45bc, 0xe000);
    write(0x2000, 0xf0f);
    write(0x203c, 0xf1f);
    frames();
    expect(getChip().sound.active, isFalse);
    expect(packets.single.buffer, [
      for (var i = 0; i < 256; i++) ...[-0.25, 0.5]
    ]);
  });

  test('EXTS left and right feed mixer slots 16 and 17', () {
    getChip().dsp.setExternalInput(16384, -8192);
    write(0x2040, 0xf0f);
    write(0x2044, 0xf1f);
    frames();
    expect(packets.single.buffer, [
      for (var i = 0; i < 256; i++) ...[-0.25, 0.5]
    ]);
  });

  test('effect send and master gain both use the published dB scale', () {
    write(0x4580, 16384);
    write(0x2000, 0xe00);
    write(0x2800, 14);
    frames();
    expect(packets.single.buffer[0], closeTo(0.2505936168, 1e-7));
    expect(packets.single.buffer[1], closeTo(0.2505936168, 1e-7));
  });

  test(
      'mono disables effect pan and muted outputs do not need per-sample polling',
      () {
    write(0x2000, 0xf0f);
    expect(getChip().sound.needsSampleClock, isFalse);
    write(0x4580, 16384);
    expect(getChip().sound.needsSampleClock, isTrue);
    write(0x2800, 0x800f);
    frames();
    expect(packets.single.buffer, everyElement(0.5));
    write(0x2000, 0);
    expect(getChip().sound.needsSampleClock, isFalse);
  });

  test('direct and effect sums clip only at the selected DAC boundary', () {
    for (final mode in [0, 0x100]) {
      core = Dc();
      packets.clear();
      core.onAudio(packets.add);
      write(0x2800, 15 | mode);
      configure(0, directSend: 15);
      key();
      write(0x4580, 16384);
      write(0x2000, 0xf00);
      frames();
      expect(packets.single.buffer,
          everyElement(mode == 0 ? 32767 / 32768 : 131071 / 131072));
    }
  });

  test('sound-source inhibit allows effects and rejects wave-memory voices',
      () {
    write(0x4580, 16384);
    write(0x2000, 0xf00);
    write(0x2880, 2);
    frames();
    expect(packets.single.buffer, everyElement(0.5));
    configure(0);
    key();
    expect(() => frames(1), throwsA(isA<DcUnsupported>()));
  });

  test(
      'DSP memory inhibit does not block CPU register access or output latches',
      () {
    write(0x2880, 1);
    write(0x4580, 16384);
    write(0x3000, 0x1238);
    write(0x2000, 0xf00);
    frames();
    expect(read(0x3000), 0x1238);
    expect(packets.single.buffer, everyElement(0.5));
  });

  test(
      'reserved MPRO bits stop before voice advancement or fake sample interrupts',
      () {
    configure(0);
    key();
    write(0x289c, 0x400);
    write(0x3400, 1);
    expect(() => frames(1), throwsA(isA<DcUnsupported>()));
    expect(read(0x2814), 0);
    expect(getChip().soundPending & 0x400, 0);
    expect(mix(0), 0);
    expect(packets, isEmpty);
    write(0x3400, 0);
    frames(1);
    expect(read(0x2814), 1);
    expect(mix(0), 0x40000);
  });

  test('reserved MPRO bits are checked even when there are no voices', () {
    write(0x3bfc, 1);
    expect(getChip().clocksToEvent, isNotNull);
    expect(() => frames(1), throwsA(isA<DcUnsupported>()));
  });

  test(
      'internal DMA commits the staged MEMS low byte through normal register writes',
      () {
    getChip().memory.setUint32LE(0x1800, 0x56);
    getChip().memory.setUint32LE(0x1804, 0x9a78);
    write(0x2884, 0x1800);
    write(0x2888, 0x4400);
    write(0x288c, 9);
    core.bus.tickMasterClocks(18);
    expect(read(0x4400), 0x56);
    expect(read(0x4404), 0x9a78);
    expect(getChip().internalDmaBusy, isFalse);
    expect(getChip().soundPending & 16, 16);
  });

  test('guest ARM code configures an EFREG output without host mixer setup',
      () {
    final words = [
      0xe59f0014,
      0xe59f1014,
      0xe5801000,
      0xe59f0010,
      0xe59f1010,
      0xe5801000,
      0xeafffffe,
      0x00804580,
      0x4000,
      0x00802000,
      0xf00
    ];
    for (final (i, value) in words.indexed) {
      getChip().memory.setUint32LE(i * 4, value);
    }
    write(0x2c00, 0);
    frames();
    expect(read(0x4580), 0x4000);
    expect(read(0x2000), 0xf00);
    expect(packets.single.buffer, everyElement(0.5));
  });

  test('reset clears DSP storage, pending byte latches and output controls',
      () {
    getChip().memory.setUint32LE(0x1000, 0x12345678);
    write(0x3000, 0xfff8);
    write(0x3400, 1);
    write(0x4000, 0xff);
    write(0x4400, 0x56);
    write(0x4580, 16384);
    write(0x2000, 0xf00);
    getChip().dsp.setExternalInput(123, -123);
    getChip().reset();
    for (final offset in [
      0x2804,
      0x3000,
      0x3400,
      0x4000,
      0x4400,
      0x4580,
      0x45c0,
      0x2000
    ]) {
      expect(read(offset), 0);
    }
    write(0x4404, 0xffff);
    expect(read(0x4400), 0);
    expect(getChip().memory.getUint32LE(0x1000), 0x12345678);
  });
}

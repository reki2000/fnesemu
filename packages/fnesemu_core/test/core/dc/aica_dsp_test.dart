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
    addTearDown(core.dispose);
    packets = [];
    core.onAudio(packets.add);
    write(0x2800, 15);
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

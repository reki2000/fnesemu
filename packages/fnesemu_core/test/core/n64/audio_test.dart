import 'package:fnesemu_core/src/core/n64/audio.dart';
import 'package:fnesemu_core/src/core/n64/bus.dart';
import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:test/test.dart';

void _commands(N64Audio audio, List<int> words, {bool newer = true}) {
  for (var i = 0; i < words.length; i++) {
    audio.bus.ramWrite(0x10000 + i * 4, words[i], 4);
  }
  audio.task(0x10000, words.length * 4, newer: newer);
}

void main() {
  test('the task microcode selects extended mixing without a ROM revision', () {
    final core = N64(jit: false);
    addTearDown(core.dispose);
    final bus = core.bus;
    bus.ramWrite(0x1000, 1, 4);
    bus.ramWrite(0x1004, 0x0002ffff, 4);
    bus.ramWrite(0x3000, 0x4000c000, 4);
    const commands = [
      0x14010100, 0x3000, // Load sixteen bytes to DMEM 0x100.
      0x02000200, 16, // Clear the right channel.
      0x0c017fff, 0x01000200, // Mix without SETBUFF.
      0x0d010300, 0x01000200, // Interleave eight samples.
      0x15020300, 0x4000, // Save thirty-two bytes of stereo output.
    ];
    for (var i = 0; i < commands.length; i++) {
      bus.ramWrite(0x2000 + i * 4, commands[i], 4);
    }
    bus.spData.setUint32(0xfc0, 2);
    bus.spData.setUint32(0xfd8, 0x1000);
    bus.spData.setUint32(0xfdc, 0x800);
    bus.spData.setUint32(0xff0, 0x2000);
    bus.spData.setUint32(0xff4, commands.length * 4);
    bus.onTask!();
    expect(core.audio.extendedAbi, isTrue);
    expect(bus.ramRead(0x4000, 2).toSigned(16), 16384);
    expect(bus.ramRead(0x4002, 2).toSigned(16), 16383);
    expect(bus.ramRead(0x4004, 2).toSigned(16), -16384);
    expect(bus.ramRead(0x4006, 2).toSigned(16), -16384);
    bus.ramWrite(0x1004, 0, 4);
    core.audio.task(0, 0, ucodeData: 0x1000);
    expect(core.audio.extendedAbi, isFalse);
  });

  test('the original ABI retains SETBUFF lengths and output addresses', () {
    final audio = N64Audio(N64Bus());
    audio.bus.ramWrite(0x3000, 0x20004000, 4);
    _commands(
        audio,
        [
          0x08000100,
          0x02000004,
          0x04000000,
          0x3000,
          0x02000200,
          4,
          0x0c007fff,
          0x01000200,
          0x06000000,
          0x4000,
        ],
        newer: false);
    expect(audio.extendedAbi, isFalse);
    expect(audio.bus.ramRead(0x4000, 2), 8191);
    expect(audio.bus.ramRead(0x4002, 2), 16383);
  });

  test('FIR impulse response uses current and preceding samples in tap order',
      () {
    final audio = N64Audio(N64Bus());
    audio.bus.ramWrite(0x2000, 0x40002000, 4);
    audio.bus.ramWrite(0x3010, 0x40002000, 4);
    audio.write(0x100, 16384);
    _commands(audio, [0x07020010, 0x2000, 0x07000100, 0x3000]);
    expect([for (var i = 0; i < 8; i++) audio.read(0x100 + i * 2)],
        [8192, 4096, 0, 0, 0, 0, 0, 0]);
    expect(audio.bus.ramRead(0x3000, 2), 16384);
  });

  test('FIR continuation carries input history and smooths coefficients', () {
    final audio = N64Audio(N64Bus());
    audio.bus.ramWrite(0x200e, 0x4000, 2); // Seven-sample delay.
    audio.bus.ramWrite(0x301e, 0x4000, 2);
    audio.write(0x10e, 16384);
    _commands(audio, [0x07020010, 0x2000, 0x07000100, 0x3000]);
    expect(audio.read(0x10e), 0);
    _commands(audio, [0x07000110, 0x3000]);
    expect(audio.read(0x11c), 8192);
    audio.write(0x100, 16384);
    audio.bus.ramWrite(0x2000, 0x4000, 2);
    _commands(audio, [0x07020010, 0x2000, 0x07010100, 0x3000]);
    expect(audio.read(0x100), 4096); // INIT averages target taps with zero.
  });

  test('extended envelope flags affect independent dry and wet destinations',
      () {
    final audio = N64Audio(N64Bus());
    for (var i = 0; i < 16; i++) {
      audio.write(0x100 + i * 2, 16384);
    }
    audio.write(0x210, 1234); // Outside the eight-sample command.
    _commands(audio, [
      0x12800000, 0, // Wet gain 0x8000, no ramp.
      0x16000000, 0xffff8000, // Left/right Q16 gains.
      0x13100819, 0x20304050, // Swap wet channels, invert dry L and wet R.
    ]);
    expect(audio.read(0x200), -16384);
    expect(audio.read(0x300), 8192);
    expect(audio.read(0x400), 4096);
    expect(audio.read(0x500), -8192);
    expect(audio.read(0x210), 1234);
  });

  test('extended short ADPCM expands signed two-bit residuals', () {
    final audio = N64Audio(N64Bus());
    audio.memory.setRange(0x100, 0x105, [0x40, 0x1b, 0x1b, 0x1b, 0x1b]);
    _commands(audio, [0x08000100, 0x02000020, 0x01050000, 0x3000]);
    expect([
      for (var i = 0; i < 16; i++) audio.read(0x220 + i * 2)
    ], [
      for (var i = 0; i < 4; i++) ...[0, 16, -32, -16]
    ]);
    expect(audio.bus.ramRead(0x3002, 2).toSigned(16), 16);
    expect(audio.bus.ramRead(0x301e, 2).toSigned(16), -16);
  });

  test('extended DUPLICATE copies a preserved 128-byte source block', () {
    final audio = N64Audio(N64Bus());
    for (var i = 0; i < 128; i++) {
      audio.memory[0x100 + i] = i;
    }
    _commands(audio, [0x09020100, 0x02000080]);
    expect(audio.memory.sublist(0x200, 0x300),
        [...List.generate(128, (i) => i), ...List.generate(128, (i) => i)]);
  });
}

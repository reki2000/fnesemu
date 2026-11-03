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




}

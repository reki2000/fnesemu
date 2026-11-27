import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:mp_jit_recompiler/src/arm64/assembler.dart';
import 'package:mp_jit_recompiler/src/arm64/backend.dart';
import 'package:mp_jit_recompiler/src/native_env.dart';
import 'package:test/test.dart';

final class _StubEnv implements NativeEnv {
  _StubEnv({required this.addrMask});

  @override
  bool get win64 => false;

  @override
  final int addrMask;

  @override
  int get pageShift => 12;

  @override
  int get exitStub => 0x100000;

  @override
  int get readFn => 0x200000;

  @override
  int get writeFn => 0x300000;

  @override
  int get blockEntryFn => 0;

  @override
  int? guardAddr(int guestAddr) => 0x10000000 + guestAddr;

  @override
  int helperFn(int id) => 0x400000 + id * 16;

  @override
  int slotFor(int pc, int tag) => (pc >>> 2) & 0xff;

  @override
  int translationAddress(int id) => 0x500000 + id * 0x1000;

  @override
  JitTranslationTable translationTable(int id) => throw UnimplementedError();
}

void main() {
  test('Arm64Assembler encodes immediate, shift, cbz and indexed ops', () {
    final a = Arm64Assembler();
    final target = Arm64Label();
    a.cbz(5, target);
    a.cbnz(0, target, wide: true);
    a.bind(target);
    a.cbnz(2, target, wide: true);
    a.constant(1, -1);
    a.constant(1, -4, wide: true);
    a.immediate(0, 0, 12, wide: false);
    a.immediate(0, 0, 12, sub: true, wide: false);
    a.immediate(1, 2, 1, shifted: true, wide: true);
    a.cmpImmediate(3, 42);
    a.cmpImmediate(3, 1, shifted: true, wide: true);
    a.ubfx(4, 0, 12, 17);
    a.ubfx(3, 0, 0, 12);
    a.lslImm(4, 4, 4);
    a.lsrImm(4, 0, 12);
    a.asrImm(4, 0, 3);
    a.lslImm(0, 1, 32, wide: true);
    a.lsrImm(0, 0, 32, wide: true);
    a.asrImm(0, 1, 5, wide: true);
    a.memoryIndexed(true, 5, 20, 4, size: 8, scaled: true);
    a.memoryIndexed(true, 0, 5, 3, size: 4);
    a.memoryIndexed(false, 0, 5, 3, size: 4);
    a.memoryIndexed(true, 0, 5, 3, size: 2);
    a.memoryIndexed(false, 0, 5, 3, size: 1);
    a.vmemoryIndexed(true, 0, 5, 3);
    a.vmemoryIndexed(false, 16, 5, 3);
    a.v2(V.umaxv4s, 1, 1);

    expect(a.words, [
      0x34000045, // cbz w5, +8
      0xb5000020, // cbnz x0, +4
      0xb5000002, // cbnz x2, +0
      0x12800001, // movn w1, #0
      0x92800061, // movn x1, #3
      0x11003000, // add w0, w0, #12
      0x51003000, // sub w0, w0, #12
      0x91400441, // add x1, x2, #1, lsl #12
      0x7100a87f, // cmp w3, #42
      0xf140047f, // cmp x3, #1, lsl #12
      0x530c7004, // ubfx w4, w0, #12, #17
      0x53002c03, // ubfx w3, w0, #0, #12
      0x531c6c84, // lsl w4, w4, #4
      0x530c7c04, // lsr w4, w0, #12
      0x13037c04, // asr w4, w0, #3
      0xd3607c20, // lsl x0, x1, #32
      0xd360fc00, // lsr x0, x0, #32
      0x9345fc20, // asr x0, x1, #5
      0xf8647a85, // ldr x5, [x20, x4, lsl #3]
      0xb86368a0, // ldr w0, [x5, x3]
      0xb82368a0, // str w0, [x5, x3]
      0x786368a0, // ldrh w0, [x5, x3]
      0x382368a0, // strb w0, [x5, x3]
      0x3ce368a0, // ldr q0, [x5, x3]
      0x3ca368b0, // str q16, [x5, x3]
      0x6eb0a821, // umaxv s1, v1.4s
    ]);
  });

  test('Arm64Backend emits grouped guards and compact lookup', () {
    final b = IrBuilder(0);
    for (var k = 0; k < 7; k++) {
      b.guard(k * 4, 0x11223344 + k, endian: IrEndian.big);
    }
    final addr = b.ctxLoad(0);
    final loaded = b.load(4, addr);
    final shifted = b.shrU(loaded, b.c32(3));
    final added = b.add(shifted, b.c32(5));
    b.ctxStore(1, added);
    final cond = b.eq(added, b.c32(0));
    final block = b.finish(IrBranch(cond, 4, 8), cost: 7);

    final contig = Arm64Backend.compile(
      block,
      0,
      _StubEnv(addrMask: 0x1fffffff),
    );
    final nonContig = Arm64Backend.compile(
      block,
      0,
      _StubEnv(addrMask: 0x9fffffff),
    );

    List<int> wordsOf(List<int> bytes) => [
      for (var i = 0; i < bytes.length; i += 4)
        bytes[i] |
            (bytes[i + 1] << 8) |
            (bytes[i + 2] << 16) |
            (bytes[i + 3] << 24),
    ];

    final contigWords = wordsOf(contig);
    final nonContigWords = wordsOf(nonContig);

    // 4-word SIMD guard emits UMAXV s1, v1.4s and no REV instructions.
    expect(contigWords, contains(0x6eb0a821));
    expect(contigWords.where((w) => (w & 0xfffffc00) == 0x5ac00800), isEmpty);
    // Contiguous mask uses UBFX + scaled LDR [x20, x4, lsl #3].
    expect(contigWords, contains(0x530c7004));
    expect(contigWords, contains(0xf8647a85));
    // Non-contiguous mask keeps the explicit AND before LSR #12.
    expect(nonContigWords, isNot(contains(0x530c7004)));
    expect(nonContigWords, contains(0x530c7c64)); // lsr w4, w3, #12
    expect(nonContigWords, contains(0xf8647a85));
  });
}

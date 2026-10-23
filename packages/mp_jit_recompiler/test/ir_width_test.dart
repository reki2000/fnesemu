import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

BigInt _hex(String value) => BigInt.parse(value, radix: 16);
BigInt _ctx64(JitRuntime rt, int at) =>
    BigInt.from(rt.ctx[at]) | BigInt.from(rt.ctx[at + 1]) << 32;

IrBlock _finish(IrBuilder b) =>
    b.finish(const IrExitTerm(IrExit(JitReason.user, 0x104)), cost: 1);

void _run(JitRuntime rt, IrBuilder b) {
  rt.install(_finish(b));
  rt.ctx[JitCtx.budget] = 100;
  expect(rt.run(0x100, 0), JitReason.user);
}

void main() {
  for (final native in [false, true]) {
    group(native ? 'compiled widths' : 'reference widths', () {
      late JitRuntime rt;
      JitRuntime make(
              {required int ctxWords,
              required int addrMask,
              required JitRead read,
              required JitWrite write}) =>
          native && JitRuntime.nativeSupported
              ? JitRuntime.native(
                  ctxWords: ctxWords,
                  addrMask: addrMask,
                  read: read,
                  write: write)!
              : JitRuntime.interpreter(
                  ctxWords: ctxWords,
                  addrMask: addrMask,
                  read: read,
                  write: write);
      setUp(() {
        rt = make(
            ctxWords: 64,
            addrMask: 0x1fffffff,
            read: (_, __) => 0,
            write: (_, __, ___) {});
      });
      tearDown(() => rt.dispose());

      test('constants preserve all 64 bits and deduplicate by width', () {
        final b = IrBuilder(0x100);
        final exact =
            _hex('fedcba9876543211'); // cannot pass through a JS number
        final x = b.c64(exact);
        expect(b.c64Parts(0x76543211, 0xfedcba98), x);
        expect(b.c32(1), isNot(b.c64(BigInt.one)));
        b.ctxStore(9, x); // context indices count words, not registers
        b.ctxStore(11, b.ctxLoad(9, type: IrType.i64));
        _run(rt, b);
        expect(_ctx64(rt, 9), exact);
        expect(_ctx64(rt, 11), exact);
        expect(rt.ctx[9], 0x76543211);
        expect(rt.ctx[10], 0xfedcba98);
      });

      test(
          'word extension and truncation preserve N64 upper-register semantics',
          () {
        final b = IrBuilder(0x100);
        final word = b.c32(0x80000001);
        b.ctxStore(8, b.sext32(word));
        b.ctxStore(10, b.zext32(word));
        b.ctxStore(12, b.trunc32(b.c64(_hex('1234567880000001'))));
        b.ctxStore(13, b.sext8(b.c32(0x80), type: IrType.i64));
        b.ctxStore(15, b.sext16(b.c32(0x8001), type: IrType.i64));
        b.ctxStore(17, b.zext16(b.c64Parts(-1, -1)));
        b.ctxStore(19, b.sext8(b.c64Parts(0x80, 0), type: IrType.i32));
        _run(rt, b);
        expect(_ctx64(rt, 8), _hex('ffffffff80000001'));
        expect(_ctx64(rt, 10), _hex('80000001'));
        expect(rt.ctx[12], 0x80000001);
        expect(_ctx64(rt, 13), _hex('ffffffffffffff80'));
        expect(_ctx64(rt, 15), _hex('ffffffffffff8001'));
        expect(_ctx64(rt, 17), BigInt.from(0xffff));
        expect(rt.ctx[19], 0xffffff80);
      });

      test('arithmetic wraps at value width and shifts use the correct mask',
          () {
        final b = IrBuilder(0x100);
        final one = b.c64(BigInt.one), all = b.c64Parts(-1, -1);
        b.ctxStore(8, b.add(all, one));
        b.ctxStore(10, b.sub(b.c64(BigInt.zero), one));
        b.ctxStore(12, b.shl(one, b.c32(63)));
        b.ctxStore(14, b.shl(one, b.c32(64)));
        b.ctxStore(16, b.shrS(b.c64Parts(0, 0x80000000), b.c32(63)));
        b.ctxStore(18, b.shrU(b.c64Parts(0, 0x80000000), b.c32(63)));
        b.ctxStore(20, b.add(b.c32(-1), b.c32(1)));
        b.ctxStore(21, b.not(b.c64Parts(0x89abcdef, 0x01234567)));
        _run(rt, b);
        expect(_ctx64(rt, 8), BigInt.zero);
        expect(_ctx64(rt, 10), _hex('ffffffffffffffff'));
        expect(_ctx64(rt, 12), _hex('8000000000000000'));
        expect(_ctx64(rt, 14), BigInt.one);
        expect(_ctx64(rt, 16), _hex('ffffffffffffffff'));
        expect(_ctx64(rt, 18), BigInt.one);
        expect(rt.ctx[20], 0);
        expect(_ctx64(rt, 21), _hex('fedcba9876543210'));
      });

      test(
          'wide comparisons return i32 and multiplication retains the high half',
          () {
        final b = IrBuilder(0x100);
        final all = b.c64Parts(-1, -1), two = b.c64(BigInt.two);
        final less = b.ltS(all, b.c64(BigInt.zero));
        expect(b.typeOf(less), IrType.i32);
        b.ctxStore(8, less);
        b.ctxStore(9, b.ltU(all, b.c64(BigInt.zero)));
        b.ctxStore(10, b.select(less, all, two));
        b.ctxStore(12, b.mul(all, two));
        b.ctxStore(14, b.mulHiU(all, two));
        b.ctxStore(16, b.mulHiS(all, two));
        _run(rt, b);
        expect(rt.ctx[8], 1);
        expect(rt.ctx[9], 0);
        expect(_ctx64(rt, 10), _hex('ffffffffffffffff'));
        expect(_ctx64(rt, 12), _hex('fffffffffffffffe'));
        expect(_ctx64(rt, 14), BigInt.one);
        expect(_ctx64(rt, 16), _hex('ffffffffffffffff'));
      });

      for (final mapped in [false, true]) {
        test('${mapped ? 'mapped' : 'callback'} memory has explicit byte order',
            () {
          final bytes = List<int>.filled(4096, 0);
          bytes.setAll(0, [1, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]);
          final calls = <String>[];
          rt.dispose();
          rt = make(
              ctxWords: 64,
              addrMask: 0x1fffffff,
              read: (addr, size) {
                calls.add('r $addr $size');
                int value = 0;
                for (int i = 0; i < size; i++) {
                  value |= bytes[(addr & 4095) + i] << (i * 8);
                }
                return value.toUnsigned(32);
              },
              write: (addr, size, value) {
                calls.add('w $addr $size');
                for (int i = 0; i < size; i++) {
                  bytes[(addr & 4095) + i] = (value >>> (i * 8)) & 255;
                }
              });
          final ram = rt.alloc(4096)..setAll(0, bytes);
          if (mapped) rt.mapPages(0x1000, ram.length, ram);
          final b = IrBuilder(0x100), address = 0x1000;
          b.ctxStore(8, b.load(8, b.c32(address), type: IrType.i64));
          b.ctxStore(
              10,
              b.load(8, b.c32(address),
                  type: IrType.i64, endian: IrEndian.big));
          b.ctxStore(12, b.load(4, b.c32(address), endian: IrEndian.big));
          b.ctxStore(
              13,
              b.load(2, b.c32(address + 4),
                  signed: true, endian: IrEndian.big));
          b.ctxStore(
              14,
              b.load(4, b.c32(address + 4),
                  type: IrType.i64, signed: true, endian: IrEndian.big));
          final value = b.c64(_hex('0123456789abcdef'));
          b.store(8, b.c32(address + 16), value, endian: IrEndian.big);
          b.store(8, b.c32(address + 24), value);
          b.store(4, b.c32(address + 32), b.c32(0x89abcdef),
              endian: IrEndian.big);
          b.store(2, b.c32(address + 36), value, endian: IrEndian.big);
          _run(rt, b);
          expect(_ctx64(rt, 8), _hex('efcdab8967452301'));
          expect(_ctx64(rt, 10), _hex('0123456789abcdef'));
          expect(rt.ctx[12], 0x01234567);
          expect(rt.ctx[13], 0xffff89ab);
          expect(_ctx64(rt, 14), _hex('ffffffff89abcdef'));
          final result = mapped ? ram : bytes;
          expect(result.sublist(16, 24),
              [1, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]);
          expect(result.sublist(24, 32),
              [0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 1]);
          expect(result.sublist(32, 36), [0x89, 0xab, 0xcd, 0xef]);
          expect(result.sublist(36, 38), [0xcd, 0xef]);
          if (mapped) {
            expect(calls, isEmpty);
          } else {
            expect(calls.where((c) => c.startsWith('w')).length, 6);
          }
        });
      }

      final invalid = <String, void Function(IrBuilder)>{
        'mixed arithmetic': (b) {
          b.add(b.c32(1), b.c64(BigInt.one));
        },
        'mixed comparison': (b) {
          b.eq(b.c32(1), b.c64(BigInt.one));
        },
        'wide condition': (b) {
          b.select(b.c64(BigInt.one), b.c32(1), b.c32(2));
        },
        'mixed select': (b) {
          b.select(b.c32(1), b.c32(1), b.c64(BigInt.one));
        },
        'wide address': (b) {
          b.load(4, b.c64(BigInt.zero));
        },
        'wide shift count': (b) {
          b.shl(b.c64(BigInt.one), b.c64(BigInt.one));
        },
        'i64 helper argument': (b) {
          b.call(0, b.c64(BigInt.one));
        },
        'invalid extension': (b) {
          b.sext32(b.c64(BigInt.one));
        },
        'invalid truncation': (b) {
          b.trunc32(b.c32(1));
        },
        'oversized load': (b) {
          b.load(8, b.c32(0));
        },
        'oversized store': (b) {
          b.store(8, b.c32(0), b.c32(1));
        },
      };
      for (final entry in invalid.entries) {
        test('verifier rejects ${entry.key}', () {
          final b = IrBuilder(0x100);
          entry.value(b);
          expect(() => _finish(b), throwsStateError);
        });
      }
      test('branch and dynamic addresses remain i32', () {
        final b = IrBuilder(0x100), wide = b.c64(BigInt.one);
        expect(() => b.finish(IrBranch(wide, 0x100, 0x200), cost: 1),
            throwsStateError);
        expect(() => b.finish(IrJumpDyn(wide), cost: 1), throwsStateError);
      });
      test('i64 context accesses check both words', () {
        final b = IrBuilder(0x100);
        b.ctxLoad(63, type: IrType.i64);
        expect(() => rt.install(_finish(b)), throwsStateError);
      });
      test('instruction guards use the declared guest byte order', () {
        final ram = rt.alloc(4096)..setAll(0, [1, 0x23, 0x45, 0x67]);
        rt.mapPages(0x1000, ram.length, ram);
        final b = IrBuilder(0x100)
          ..guard(0x1000, 0x01234567, endian: IrEndian.big);
        b.ctxStore(8, b.c32(42));
        _run(rt, b);
        expect(rt.ctx[8], 42);
        ram[0] = 2;
        rt.ctx[8] = 0;
        rt.ctx[JitCtx.budget] = 100;
        expect(rt.run(0x100, 0), JitReason.invalid);
        expect(rt.ctx[8], 0);
      });
      test('wide side exits preserve all bits and refund partial costs', () {
        final b = IrBuilder(0x100);
        final value = b.add(b.ctxLoad(8, type: IrType.i64), b.c64Parts(3, 1));
        b.exitIf(b.c32(1),
            IrExit(JitReason.user, 0x104, spent: 1, stores: [(10, value)]));
        rt.ctx[8] = 0xffffffff;
        rt.ctx[9] = 0x80000000;
        rt.install(b.finish(const IrJump(0x200), cost: 4));
        rt.ctx[JitCtx.budget] = 10;
        expect(rt.run(0x100, 0), JitReason.user);
        expect(_ctx64(rt, 10), _hex('8000000200000002'));
        expect(rt.ctx[JitCtx.budget], 9);
      });
    },
        skip: native && !JitRuntime.nativeSupported
            ? 'No compiled backend'
            : false);
  }
}

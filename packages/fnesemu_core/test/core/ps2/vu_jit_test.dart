import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/jit/vu_jit.dart';
import 'package:fnesemu_core/src/core/ps2/vu.dart';
import 'package:test/test.dart';

const _upperNop = 0x000002ff, _lowerNop = 0x8000033c;

/// Random micro programs: a loop over random pairs that the recompiler
/// translates, with a few that it leaves to the interpreter, and the end.
final class _Program {
  final Random rnd;
  final pairs = <(int, int)>[];

  _Program(this.rnd);

  int _reg() => rnd.nextInt(8) == 0 ? 0 : 1 + rnd.nextInt(31);
  int _vi() => rnd.nextInt(14); // vi14 is the loop counter, vi15 a base
  int _mask() => 1 + rnd.nextInt(15);

  int _upper() {
    final mask = _mask(), fd = _reg(), fs = _reg(), ft = _reg();
    final base = mask << 21 | ft << 16 | fs << 11 | fd << 6;
    switch (rnd.nextInt(10)) {
      case 0:
        return _upperNop;
      case < 5:
        return base | rnd.nextInt(0x30);
      case < 9:
        return base & ~(31 << 6) |
            (rnd.nextInt(12) << 6) |
            0x3c |
            rnd.nextInt(4);
      default:
        // an upper opcode that the recompiler leaves out
        return base | (0x30 + rnd.nextInt(12));
    }
  }

  int _special(int sub, int col, {int it = 0, int fs = 0, int mask = 0}) =>
      0x80000000 | mask << 21 | it << 16 | fs << 11 | sub << 6 | 0x3c | col;

  int _lower() {
    final mask = _mask(), it = _reg(), fs = _reg();
    final imm = rnd.nextInt(0x800);
    int op(int code, {int t = 0, int s = 0, int m = 0, int i = 0}) =>
        code << 25 | m << 21 | t << 16 | s << 11 | (i & 0x7ff);
    switch (rnd.nextInt(24)) {
      case 0:
        return _lowerNop;
      case 1:
        return op(0x00, t: it, s: 15, m: mask, i: rnd.nextInt(64)); // LQ
      case 2:
        return op(0x01, t: 15, s: fs, m: mask, i: rnd.nextInt(64)); // SQ
      case 3:
        return op(rnd.nextBool() ? 0x04 : 0x05,
            t: _vi(), s: 15, m: mask, i: rnd.nextInt(64)); // ILW, ISW
      case 4:
        return op(rnd.nextBool() ? 0x08 : 0x09,
            t: _vi(), s: _vi(), m: rnd.nextInt(16), i: imm); // IADDIU
      case 5 || 6:
        // the flag instructions
        final code = const [
          0x10,
          0x11,
          0x12,
          0x13,
          0x14,
          0x15,
          0x16,
          0x17,
          0x18,
          0x1a,
          0x1b,
          0x1c,
        ][rnd.nextInt(12)];
        final value = rnd.nextInt(1 << 21);
        return code << 25 |
            (value & ~(31 << 16 | 15 << 11)) |
            _vi() << 11 |
            _vi() << 16;
      case 7:
        // IADD, ISUB, IADDI, IAND, IOR
        final funct = const [0x30, 0x31, 0x32, 0x34, 0x35][rnd.nextInt(5)];
        return 0x40 << 25 |
            _vi() << 16 |
            _vi() << 11 |
            (funct == 0x32 ? rnd.nextInt(32) : _vi()) << 6 |
            funct;
      case 8:
        // MOVE, MR32, MTIR, MFIR
        final (sub, col) =
            const [(0x0c, 0), (0x0c, 1), (0x0f, 0), (0x0f, 1)][rnd.nextInt(4)];
        return _special(sub, col,
            it: it,
            fs: col == 1 && sub == 0x0f ? _vi() : fs,
            mask: sub == 0x0f && col == 0 ? rnd.nextInt(4) << 0 : mask);
      case 9:
        // LQI, SQI, LQD, SQD with vi15 as the address
        final col = rnd.nextInt(4);
        final load = col == 0 || col == 2;
        return _special(0x0d, col,
            it: load ? it : 15, fs: load ? 15 : fs, mask: mask);
      case 10 || 11:
        // DIV, SQRT, RSQRT, WAITQ
        final col = rnd.nextInt(4);
        return _special(0x0e, col, it: it, fs: fs, mask: rnd.nextInt(16));
      case 12:
        // ILWR, ISWR
        return _special(0x0f, 2 + rnd.nextInt(2),
            it: _vi(), fs: 15, mask: mask);
      case 13:
        // RNEXT, RGET, RINIT, RXOR
        return _special(0x10, rnd.nextInt(4), it: it, fs: fs, mask: mask);
      case 14:
        // MFP, WAITP
        return rnd.nextBool()
            ? _special(0x19, 0, it: it, mask: mask)
            : _special(0x1e, 3);
      case 15 || 16:
        // the EFU, with the operations the recompiler leaves out
        final code = 0x70 + rnd.nextInt(16);
        return _special(code >> 2, code & 3, fs: fs, mask: rnd.nextInt(4) << 0);
      case 17:
        // XTOP, XITOP
        return _special(0x1a, rnd.nextInt(2), it: _vi());
      case 18:
        // XGKICK
        return _special(0x1b, 0, fs: _vi());
      default:
        return _lowerNop;
    }
  }

  int _float() {
    switch (rnd.nextInt(8)) {
      case 0:
        return rnd.nextBool() ? 0 : 0x80000000;
      case 1:
        return rnd.nextInt(0x800000) | (rnd.nextBool() ? 0x80000000 : 0);
      case 2:
        return 0x7f000000 | rnd.nextInt(0x1000000);
      case 3:
        return rnd.nextInt(1 << 32);
      default:
        // moderate values
        return (rnd.nextBool() ? 0x80000000 : 0) |
            (120 + rnd.nextInt(16)) << 23 |
            rnd.nextInt(0x800000);
    }
  }

  void build(int body) {
    // vi14 counts the loop down from 3
    pairs.add((0x08 << 25 | 14 << 16 | 3, _upperNop));
    final start = pairs.length;
    for (var n = 0; n < body; n++) {
      final iBit = rnd.nextInt(10) == 0;
      final lower = iBit ? _float() : _lower();
      pairs.add((lower, _upper() | (iBit ? 1 << 31 : 0)));
      if (!iBit && rnd.nextInt(12) == 0) {
        // a forward branch over the next pair
        final cond = const [
          0x20,
          0x21,
          0x28,
          0x29,
          0x2c,
          0x2d,
          0x2e,
          0x2f
        ][rnd.nextInt(8)];
        final link = cond == 0x21 ? _vi() : 0;
        pairs.add((
          cond << 25 | (cond == 0x21 ? link : _vi()) << 16 | _vi() << 11 | 2,
          _upper()
        ));
        pairs.add((_lower(), _upper())); // the delay slot
        pairs.add((_lower(), _upper())); // skipped when taken
      }
    }
    // ISUBIU vi14, vi14, 1; IBNE vi14, vi0, start; delay
    pairs.add((0x09 << 25 | 14 << 16 | 14 << 11 | 1, _upperNop));
    final offset = start - (pairs.length + 1);
    pairs.add((0x29 << 25 | 14 << 16 | (offset & 0x7ff), _upperNop));
    pairs.add((_lowerNop, _upperNop));
    pairs.add((_lowerNop, _upperNop | 1 << 30));
    pairs.add((_lowerNop, _upperNop));
  }
}

/// the observable state of [vu] after a program, with the XGKICKs, by
/// name
Map<String, Object> _state(Vu vu, List<String> kicks) => {
      'pc': vu.pc,
      'cycles': vu.cycles,
      'i': vu.i,
      'q': vu.q,
      'p': vu.p,
      'r': vu.r,
      'mac': vu.mac,
      'status': vu.status,
      'clip': vu.clip,
      for (var n = 0; n < 128; n++) 'vf${n >> 2}.${'xyzw'[n & 3]}': vu.vf[n],
      for (var n = 0; n < 16; n++) 'vi$n': vu.vi[n],
      for (var n = 0; n < 4; n++) 'acc$n': vu.acc[n],
      for (var n = 0; n < vu.data.length; n++) 'data$n': vu.data[n],
      'kicks': kicks.join(','),
    };

/// the entries of [got] that differ from [expected]
List<String> _differences(
        Map<String, Object> got, Map<String, Object> expected) =>
    [
      for (final key in expected.keys)
        if (got[key] != expected[key])
          '$key ${got[key] is int ? (got[key] as int).toRadixString(16) : got[key]} '
              'instead of ${expected[key] is int ? (expected[key] as int).toRadixString(16) : expected[key]}'
    ];

void _load(Vu vu, _Program program, Uint32List data, Uint32List vf,
    List<int> vi, List<String> kicks) {
  vu.micro.fillRange(0, vu.micro.length, 0);
  for (var n = 0; n < program.pairs.length; n++) {
    vu.micro[n * 2] = program.pairs[n].$1;
    vu.micro[n * 2 + 1] = program.pairs[n].$2;
  }
  vu.data.setAll(0, data);
  vu.vf.setAll(4, vf.sublist(4));
  for (var n = 1; n < 16; n++) {
    vu.vi[n] = vi[n];
  }
  vu.top = () => 0x123;
  vu.itop = () => 0x2a5;
  vu.onXgkick = (q) {
    var h = 0;
    for (var n = 0; n < 16; n++) {
      h = (h * 31 + vu.data[(q * 4 + n) & 4095]) & 0xffffffff;
    }
    kicks.add('$q:$h');
  };
}

void _compare(int seed, {required bool native}) {
  final jit = VuJit.create(native: native, compileThreshold: 1);
  if (jit == null) {
    markTestSkipped('no recompiler on this host');
    return;
  }
  final rnd = Random(seed);
  final program = _Program(rnd)..build(4 + rnd.nextInt(24));
  final data =
      Uint32List.fromList([for (var n = 0; n < 4096; n++) program._float()]);
  final vf =
      Uint32List.fromList([for (var n = 0; n < 128; n++) program._float()]);
  final vi = [for (var n = 0; n < 16; n++) rnd.nextInt(0x10000)];
  vi[15] = rnd.nextInt(1024);
  final reference = Vu(1), compiled = jit.newVu();
  final referenceKicks = <String>[], compiledKicks = <String>[];
  _load(reference, program, data, vf, vi, referenceKicks);
  _load(compiled, program, data, vf, vi, compiledKicks);
  // the second run uses the blocks that the first one compiled
  for (var run = 0; run < 2; run++) {
    reference.start(0);
    compiled.start(0);
    expect(
        _differences(
            _state(compiled, compiledKicks), _state(reference, referenceKicks)),
        isEmpty,
        reason: 'seed $seed, run $run');
  }
  jit.dispose();
}

void main() {
  test('compiled micro programs match the interpreter (reference IR)', () {
    for (var seed = 0; seed < 150; seed++) {
      _compare(seed, native: false);
    }
  });

  test('compiled micro programs match the interpreter (native)', () {
    for (var seed = 0; seed < 1000; seed++) {
      _compare(seed, native: true);
    }
  });
}

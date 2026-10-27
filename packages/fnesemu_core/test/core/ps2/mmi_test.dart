import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/r5900/r5900.dart';
import 'package:test/test.dart';

int _mmi(int fn, {int sub = 0, int rs = 0, int rt = 0, int rd = 0}) =>
    28 << 26 | rs << 21 | rt << 16 | rd << 11 | sub << 6 | fn;
int _mmi0(int sub, int rs, int rt, int rd) =>
    _mmi(0x08, sub: sub, rs: rs, rt: rt, rd: rd);
int _mmi1(int sub, int rs, int rt, int rd) =>
    _mmi(0x28, sub: sub, rs: rs, rt: rt, rd: rd);
int _mmi2(int sub, int rs, int rt, int rd) =>
    _mmi(0x09, sub: sub, rs: rs, rt: rt, rd: rd);
int _mmi3(int sub, int rs, int rt, int rd) =>
    _mmi(0x29, sub: sub, rs: rs, rt: rt, rd: rd);

/// words as 32-bit lanes, lowest first
(int, int) _w(int w0, int w1, int w2, int w3) =>
    ((w1 << 32) | w0, (w3 << 32) | w2);

/// runs one instruction with r1 = [a] and r2 = [b]; the result is r3
R5900 _run(int ir, {(int, int)? a, (int, int)? b}) {
  final cpu = R5900(Ps2Bus());
  cpu.bus.write32(0x100000, ir);
  cpu.jumpTo(0x100000);
  if (a != null) {
    cpu.gpr[2] = a.$1;
    cpu.gpr[3] = a.$2;
  }
  if (b != null) {
    cpu.gpr[4] = b.$1;
    cpu.gpr[5] = b.$2;
  }
  expect(cpu.step(), isTrue);
  return cpu;
}

(int, int) _r3(R5900 cpu) => (cpu.gpr[6], cpu.gpr[7]);

void main() {
  // r1 -> gpr[2], gpr[3]; r2 -> gpr[4], gpr[5]; r3 -> gpr[6], gpr[7]
  test('PADDW wraps and PADDSW saturates', () {
    final a = _w(0x7fffffff, 1, 0x80000000, 5);
    final b = _w(1, 2, 0xffffffff, 6);
    expect(_r3(_run(_mmi0(0x00, 1, 2, 3), a: a, b: b)),
        _w(0x80000000, 3, 0x7fffffff, 11));
    expect(_r3(_run(_mmi0(0x10, 1, 2, 3), a: a, b: b)),
        _w(0x7fffffff, 3, 0x80000000, 11));
  });

  test('PSUBUB saturates at zero', () {
    expect(_r3(_run(_mmi1(0x19, 1, 2, 3), a: (0x0a05, 0), b: (0x0108, 0))),
        (0x0900, 0));
  });

  test('PCGTH and PMAXH are signed', () {
    final a = (0x0001ffff00020000, 0);
    final b = (0x0000000000000001, 0);
    expect(_r3(_run(_mmi0(0x06, 1, 2, 3), a: a, b: b)).$1, 0xffff0000ffff0000);
    expect(_r3(_run(_mmi0(0x07, 1, 2, 3), a: a, b: b)).$1, 0x0001000000020001);
  });

  test('PEXTLW, PEXTUW and PPACW', () {
    final a = _w(0xa0, 0xa1, 0xa2, 0xa3);
    final b = _w(0xb0, 0xb1, 0xb2, 0xb3);
    expect(_r3(_run(_mmi0(0x12, 1, 2, 3), a: a, b: b)),
        _w(0xb0, 0xa0, 0xb1, 0xa1));
    expect(_r3(_run(_mmi1(0x12, 1, 2, 3), a: a, b: b)),
        _w(0xb2, 0xa2, 0xb3, 0xa3));
    expect(_r3(_run(_mmi0(0x13, 1, 2, 3), a: a, b: b)),
        _w(0xb0, 0xb2, 0xa0, 0xa2));
  });

  test('PINTH takes the lower halves of rt and the upper halves of rs', () {
    final a = (0, 0x0008000700060005);
    final b = (0x0004000300020001, 0);
    expect(_r3(_run(_mmi2(0x0a, 1, 2, 3), a: a, b: b)),
        (0x0006000200050001, 0x0008000400070003));
  });

  test('PCPYLD, PCPYUD and PCPYH', () {
    final a = (0x11, 0x22);
    final b = (0x33, 0x44);
    expect(_r3(_run(_mmi2(0x0e, 1, 2, 3), a: a, b: b)), (0x33, 0x11));
    expect(_r3(_run(_mmi3(0x0e, 1, 2, 3), a: a, b: b)), (0x22, 0x44));
    final h =
        _run(_mmi3(0x1b, 0, 1, 3), a: (0xddddccccbbbbaaaa, 0x4444333322221111));
    expect(_r3(h), (0xaaaaaaaaaaaaaaaa, 0x1111111111111111));
  });

  test('PAND, POR, PXOR and PNOR work on 128 bits', () {
    final a = (0xff00, 0xf0f0);
    final b = (0x0ff0, 0x00ff);
    expect(_r3(_run(_mmi2(0x12, 1, 2, 3), a: a, b: b)), (0x0f00, 0x00f0));
    expect(_r3(_run(_mmi3(0x12, 1, 2, 3), a: a, b: b)), (0xfff0, 0xf0ff));
    expect(_r3(_run(_mmi2(0x13, 1, 2, 3), a: a, b: b)), (0xf0f0, 0xf00f));
    expect(_r3(_run(_mmi3(0x13, 1, 2, 3), a: a, b: b)), (~0xfff0, ~0xf0ff));
  });

  test('PSLLH, PSRAH and PSRAW shift lanes independently', () {
    final v = (0x8000000180000001, 0);
    expect(_r3(_run(_mmi(0x34, sub: 1, rt: 1, rd: 3), a: v)).$1,
        0x0000000200000002);
    expect(_r3(_run(_mmi(0x37, sub: 4, rt: 1, rd: 3), a: v)).$1,
        0xf8000000f8000000);
    expect(
        _r3(_run(_mmi(0x3f, sub: 4, rt: 1, rd: 3),
            a: _w(0x80000000, 0x40, 0, 0))),
        _w(0xf8000000, 0x4, 0, 0));
  });

  test('PSLLVW shifts words 0 and 2 and sign extends', () {
    final cpu = _run(_mmi2(0x02, 1, 2, 3),
        a: _w(1, 9, 31, 9), b: _w(0x40000000, 0, 1, 0));
    expect(_r3(cpu), (-0x80000000, -0x80000000));
  });

  test('PMULTW fills HI, LO and rd; PMFHL.LW gathers them', () {
    final cpu = _run(_mmi2(0x0c, 1, 2, 3),
        a: _w(0xfffffffd, 0, 0x10000, 0), b: _w(7, 0, 0x10000, 0));
    expect(cpu.gpr[6], -21);
    expect(cpu.gpr[7], 0x100000000);
    expect(cpu.lo, -21);
    expect(cpu.hi, -1);
    expect(cpu.lo1, 0);
    expect(cpu.hi1, 1);
    cpu.bus.write32(0x100004, _mmi(0x30, sub: 0, rd: 8));
    cpu.step();
    expect((cpu.gpr[16], cpu.gpr[17]), _w(0xffffffeb, 0xffffffff, 0, 1));
  });

  test('PMADDW accumulates into HI and LO', () {
    final cpu = R5900(Ps2Bus());
    cpu.bus.write32(0x100000, _mmi2(0x00, 1, 2, 3));
    cpu.jumpTo(0x100000);
    cpu.lo = 5;
    cpu.gpr[2] = 3;
    cpu.gpr[4] = 4;
    cpu.step();
    expect(cpu.lo, 17);
    expect(cpu.gpr[6], 17);
  });

  test('PDIVW divides two lanes', () {
    final cpu =
        _run(_mmi2(0x0d, 1, 2, 3), a: _w(17, 0, 100, 0), b: _w(5, 0, 7, 0));
    expect((cpu.lo, cpu.hi, cpu.lo1, cpu.hi1), (3, 2, 14, 2));
  });

  test('MULT1 and DIVU1 use the second pipeline', () {
    final m = R5900(Ps2Bus());
    m.bus.write32(0x100000, _mmi(0x18, rs: 1, rt: 2, rd: 3));
    m.jumpTo(0x100000);
    m.gpr[2] = 6;
    m.gpr[4] = -7;
    m.step();
    expect(m.lo1, -42);
    expect(m.hi1, -1);
    expect(m.reg(3), -42);
    expect(m.lo, 0);
    final d = R5900(Ps2Bus());
    d.bus.write32(0x100000, _mmi(0x1b, rs: 1, rt: 2));
    d.jumpTo(0x100000);
    d.gpr[2] = 17;
    d.gpr[4] = 5;
    d.step();
    expect((d.lo1, d.hi1), (3, 2));
  });

  test('MADD adds to HI/LO and writes rd', () {
    final cpu = R5900(Ps2Bus());
    cpu.bus.write32(0x100000, _mmi(0x00, rs: 1, rt: 2, rd: 3));
    cpu.jumpTo(0x100000);
    cpu.lo = 10;
    cpu.gpr[2] = -3;
    cpu.gpr[4] = 4;
    cpu.step();
    expect((cpu.lo, cpu.hi, cpu.reg(3)), (-2, -1, -2));
  });

  test('PLZCW counts redundant sign bits', () {
    final cpu =
        _run(_mmi(0x04, rs: 1, rd: 3), a: _w(0x00ffffff, 0xfffff000, 0, 0));
    expect(cpu.gpr[6], (19 << 32) | 7);
  });

  test('PABSW, PEXEH, PREVH and PROT3W', () {
    expect(_r3(_run(_mmi1(0x01, 0, 1, 3), a: _w(0xfffffffe, 5, 0x80000000, 0))),
        _w(2, 5, 0x7fffffff, 0));
    final h = (0x0004000300020001, 0x0008000700060005);
    expect(_r3(_run(_mmi2(0x1a, 0, 1, 3), a: h)),
        (0x0004000100020003, 0x0008000500060007));
    expect(_r3(_run(_mmi2(0x1b, 0, 1, 3), a: h)),
        (0x0001000200030004, 0x0005000600070008));
    expect(_r3(_run(_mmi2(0x1f, 0, 1, 3), a: _w(1, 2, 3, 4))), _w(2, 3, 1, 4));
  });

  test('PMTHI moves 128 bits', () {
    final cpu = _run(_mmi3(0x08, 1, 0, 0), a: (7, 9));
    expect((cpu.hi, cpu.hi1), (7, 9));
  });

  test('instructions without an implementation are reported', () {
    final cpu = R5900(Ps2Bus());
    cpu.bus.write32(0x100000, _mmi(0x09, sub: 0x1c)); // PMULTH
    cpu.jumpTo(0x100000);
    expect(cpu.step(), isFalse);
  });
}

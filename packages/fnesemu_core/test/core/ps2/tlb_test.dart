import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/r5900/r5900.dart';
import 'package:test/test.dart';

const _code = 0x80100000;
const _tlbr = 0x42000001, _tlbwi = 0x42000002, _tlbwr = 0x42000006;
const _tlbp = 0x42000008;

int _i(int op, int rs, int rt, int imm) =>
    op << 26 | rs << 21 | rt << 16 | (imm & 0xffff);
int _r(int fn, {int rs = 0, int rt = 0, int rd = 0}) =>
    rs << 21 | rt << 16 | rd << 11 | fn;

int _lo(int pfn, {bool dirty = true, bool valid = true, bool global = true}) =>
    (pfn << 6) |
    (3 << 3) |
    (dirty ? 4 : 0) |
    (valid ? 2 : 0) |
    (global ? 1 : 0);

R5900 _cpu() {
  final cpu = R5900(Ps2Bus());
  // BEV and ERL cleared: vectors are in main memory
  cpu.cop0[R5900.cop0Status] = 0;
  cpu.jumpTo(_code);
  return cpu;
}

/// puts [program] at the start of kseg0 code memory and runs [count]
/// instructions
void _run(R5900 cpu, List<int> program, {int? count}) {
  for (var i = 0; i < program.length; i++) {
    cpu.bus.write32(_code + i * 4, program[i]);
  }
  cpu.jumpTo(_code);
  for (var i = 0; i < (count ?? program.length); i++) {
    expect(cpu.step(), isTrue);
  }
}

void _write(R5900 cpu, int index, int vaddr, int lo0, int lo1,
    {int asid = 0, int mask = 0}) {
  cpu.cop0[R5900.cop0Index] = index;
  cpu.cop0[R5900.cop0EntryHi] = vaddr | asid;
  cpu.cop0[R5900.cop0EntryLo0] = lo0;
  cpu.cop0[R5900.cop0EntryLo1] = lo1;
  cpu.cop0[R5900.cop0PageMask] = mask;
  _run(cpu, [_tlbwi]);
}

void main() {
  test('mapped segments translate to themselves until an entry is written', () {
    final cpu = _cpu();
    cpu.bus.write32(0x4000, 0x1234);
    expect(cpu.bus.read32(0x4000), 0x1234);
    expect(cpu.tlb.active, isFalse);
  });

  test('a written entry maps its even and odd pages', () {
    final cpu = _cpu();
    cpu.bus.write32(0x200010, 0xaaaa);
    cpu.bus.write32(0x301010, 0xbbbb);
    _write(cpu, 3, 0x00400000, _lo(0x200), _lo(0x301));
    expect(cpu.bus.read32(0x00400010), 0xaaaa);
    expect(cpu.bus.read32(0x00401010), 0xbbbb);
    cpu.bus.write32(0x00400020, 0xcccc);
    expect(cpu.bus.read32(0x80200020), 0xcccc);
  });

  test('a miss raises a refill exception with the BadVAddr fields', () {
    final cpu = _cpu();
    _write(cpu, 0, 0x00400000, _lo(0x200), _lo(0x201));
    // lw r2, 0(r1) with r1 = 0x00800004 (not mapped)
    cpu.setReg(1, 0x00800004);
    _run(cpu, [_i(35, 1, 2, 0)]);
    expect(cpu.pc, 0x80000000);
    expect(cpu.cop0[R5900.cop0Cause] >> 2 & 31, 2);
    expect(cpu.cop0[R5900.cop0BadVAddr], 0x00800004);
    expect(cpu.cop0[R5900.cop0Epc], _code);
    expect(cpu.cop0[R5900.cop0EntryHi] & 0xffffe000, 0x00800000);
    expect(cpu.cop0[R5900.cop0Context] >> 4 & 0x7ffff, 0x00800004 >> 13);
  });

  test('a store miss reports a store exception', () {
    final cpu = _cpu();
    _write(cpu, 0, 0x00400000, _lo(0x200), _lo(0x201));
    cpu.setReg(1, 0x00900000);
    _run(cpu, [_i(43, 1, 2, 0)]);
    expect(cpu.cop0[R5900.cop0Cause] >> 2 & 31, 3);
    expect(cpu.pc, 0x80000000);
  });

  test('an invalid page uses the general vector', () {
    final cpu = _cpu();
    _write(cpu, 0, 0x00400000, _lo(0x200, valid: false), _lo(0x201));
    cpu.setReg(1, 0x00400000);
    _run(cpu, [_i(35, 1, 2, 0)]);
    expect(cpu.pc, 0x80000180);
    expect(cpu.cop0[R5900.cop0Cause] >> 2 & 31, 2);
  });

  test('a store to a clean page raises TLB modified', () {
    final cpu = _cpu();
    _write(cpu, 0, 0x00400000, _lo(0x200, dirty: false), _lo(0x201));
    cpu.setReg(1, 0x00400000);
    _run(cpu, [_i(35, 1, 2, 0), _i(43, 1, 2, 0)]);
    expect(cpu.cop0[R5900.cop0Cause] >> 2 & 31, 1);
    expect(cpu.pc, 0x80000180);
  });

  test('ASIDs separate non-global entries', () {
    final cpu = _cpu();
    cpu.bus.write32(0x200000, 0x11);
    cpu.bus.write32(0x300000, 0x22);
    _write(cpu, 0, 0x00400000, _lo(0x200, global: false),
        _lo(0x201, global: false),
        asid: 1);
    _write(cpu, 1, 0x00400000, _lo(0x300, global: false),
        _lo(0x301, global: false),
        asid: 2);
    cpu.cop0[R5900.cop0EntryHi] = 1;
    cpu.tlb.setAsid(1);
    expect(cpu.bus.read32(0x00400000), 0x11);
    cpu.tlb.setAsid(2);
    expect(cpu.bus.read32(0x00400000), 0x22);
  });

  test('page masks select larger pages', () {
    final cpu = _cpu();
    cpu.bus.write32(0x100100, 0x77);
    // 64 KiB pages (mask 0x1e000): even page at 0x00400000 -> 0x00100000
    _write(cpu, 0, 0x00400000, _lo(0x100), _lo(0x110), mask: 0x1e000);
    expect(cpu.bus.read32(0x00400100), 0x77);
    cpu.bus.write32(0x8010fffc, 0x55);
    expect(cpu.bus.read32(0x0040fffc), 0x55);
  });

  test('TLBR and TLBP read back and find an entry', () {
    final cpu = _cpu();
    _write(cpu, 5, 0x00600000, _lo(0x210), _lo(0x211));
    cpu.cop0[R5900.cop0Index] = 5;
    cpu.cop0[R5900.cop0EntryHi] = 0;
    cpu.cop0[R5900.cop0EntryLo0] = 0;
    _run(cpu, [_tlbr]);
    expect(cpu.cop0[R5900.cop0EntryHi] & 0xffffe000, 0x00600000);
    expect(cpu.cop0[R5900.cop0EntryLo0], _lo(0x210));
    cpu.cop0[R5900.cop0Index] = 0;
    cpu.cop0[R5900.cop0EntryHi] = 0x00600000;
    _run(cpu, [_tlbp]);
    expect(cpu.cop0[R5900.cop0Index], 5);
    cpu.cop0[R5900.cop0EntryHi] = 0x00a00000;
    _run(cpu, [_tlbp]);
    expect(cpu.cop0[R5900.cop0Index], 0x80000000);
  });

  test('TLBWR picks an index at or above Wired', () {
    final cpu = _cpu();
    cpu.cop0[R5900.cop0Wired] = 40;
    for (var i = 0; i < 20; i++) {
      cpu.cop0[R5900.cop0EntryHi] = 0x00400000 + i * 0x2000;
      cpu.cop0[R5900.cop0EntryLo0] = _lo(0x200);
      cpu.cop0[R5900.cop0EntryLo1] = _lo(0x201);
      _run(cpu, [_tlbwr]);
    }
    final used = [
      for (var i = 0; i < 48; i++)
        if (cpu.tlb.entries[i].vpn2 != 0) i
    ];
    expect(used, isNotEmpty);
    expect(used.every((i) => i >= 40), isTrue);
  });

  test('misaligned accesses raise address errors', () {
    final cpu = _cpu();
    cpu.setReg(1, 0x1001);
    _run(cpu, [_i(35, 1, 2, 0)]);
    expect(cpu.cop0[R5900.cop0Cause] >> 2 & 31, 4);
    expect(cpu.cop0[R5900.cop0BadVAddr], 0x1001);
    final store = _cpu();
    store.setReg(1, 0x1002);
    _run(store, [_i(43, 1, 2, 0)]);
    expect(store.cop0[R5900.cop0Cause] >> 2 & 31, 5);
    final half = _cpu();
    half.setReg(1, 0x1002);
    _run(half, [_i(33, 1, 2, 0)]);
    expect(half.cop0[R5900.cop0Cause] >> 2 & 31, 0, reason: 'aligned halfword');
  });

  test('LQ ignores the low address bits', () {
    final cpu = _cpu();
    cpu.bus.write64(0x2000, 5);
    cpu.setReg(1, 0x2007);
    _run(cpu, [_i(30, 1, 2, 0)]);
    expect(cpu.reg(2), 5);
  });

  test('trap instructions raise code 13', () {
    final cpu = _cpu();
    cpu.setReg(1, 3);
    cpu.setReg(2, 3);
    _run(cpu, [_r(0x34, rs: 1, rt: 2)]);
    expect(cpu.cop0[R5900.cop0Cause] >> 2 & 31, 13);
    final none = _cpu();
    none.setReg(1, 3);
    none.setReg(2, 4);
    _run(none, [_r(0x34, rs: 1, rt: 2)]);
    expect(none.cop0[R5900.cop0Cause] >> 2 & 31, 0);
    final imm = _cpu();
    imm.setReg(1, -5);
    _run(imm, [1 << 26 | 1 << 21 | 10 << 16 | 0]); // tlti r1, 0
    expect(imm.cop0[R5900.cop0Cause] >> 2 & 31, 13);
  });

  test('DMA reaches memory without the TLB', () {
    final cpu = _cpu();
    _write(cpu, 0, 0x00000000, 0x2, 0x2, mask: 0);
    cpu.bus.write32(0x80003000, 0x99);
    expect(cpu.bus.readPhysical64(0x3000), 0x99);
  });
}

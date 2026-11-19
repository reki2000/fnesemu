import 'package:fnesemu_core/src/core/ps2/ps2.dart';
import 'package:test/test.dart';

void main() {
  late Ps2 core;

  setUp(() {
    core = Ps2(jit: false);
    addTearDown(core.dispose);
  });

  test('PS2 debug CPU identity, PC, SP and memory read', () {
    expect(core.cpuInfos.map((cpu) => (cpu.no, cpu.name)),
        [(0, 'R5900'), (1, 'IOP')]);

    // Initial PC
    expect(core.programCounter(0), 0xbfc00000);
    expect(core.programCounter(1), 0xbfc00000);

    // Set SP
    core.cpu.setReg(29, 0x01ff0000);
    core.iop.r[29] = 0x001f0000;
    expect(core.stackPointer(0), 0x01ff0000);
    expect(core.stackPointer(1), 0x001f0000);

    // Read EE memory and IOP memory
    core.bus.write8(0x1000, 0x42);
    core.iopMemory.write8(0x2000, 0x99);
    expect(core.read(0, 0x1000), 0x42);
    expect(core.read(1, 0x2000), 0x99);
  });

  test('PS2 VRAM dump and render getters', () {
    expect(core.vram.length, 4 * 1024 * 1024);
    core.io.gs.mem.bytes[100] = 0x77;
    expect(core.vram[100], 0x77);

    final bg = core.renderBg();
    final vramImg = core.renderVram(false, 0);
    expect(bg.width, core.imageBuffer().width);
    expect(vramImg.width, core.imageBuffer().width);
    expect(core.renderColorTable(0).width, 0);
    expect(core.spriteInfo(), isEmpty);
  });

  test('PS2 EE disassembly covers standard and R5900-specific instructions',
      () {
    // 0x00000000: nop
    core.bus.write32(0x1000, 0x00000000);
    expect(core.disasm(0, 0x1000).$1, contains('nop'));
    expect(core.disasm(0, 0x1000).$2, 4);

    // addiu v0, zero, 1: 0x24020001
    core.bus.write32(0x1004, 0x24020001);
    expect(core.disasm(0, 0x1004).$1, contains('li v0, 1'));

    // lui a0, 0x1234: 0x3c041234
    core.bus.write32(0x1008, 0x3c041234);
    expect(core.disasm(0, 0x1008).$1, contains('lui a0, 0x1234'));

    // lq t0, 16(sp): op 30, rs=29, rt=8, imm=16 -> 0x7ba80010
    core.bus.write32(0x100c, (30 << 26) | (29 << 21) | (8 << 16) | 16);
    expect(core.disasm(0, 0x100c).$1, contains('lq t0, 16(sp)'));

    // sq t0, 32(sp): op 31, rs=29, rt=8, imm=32 -> 0x7fa80020
    core.bus.write32(0x1010, (31 << 26) | (29 << 21) | (8 << 16) | 32);
    expect(core.disasm(0, 0x1010).$1, contains('sq t0, 32(sp)'));

    // MMI: paddw v0, a0, a1 (op=28, rs=4, rt=5, rd=2, sa=0, fn=8)
    core.bus.write32(
        0x1014, (28 << 26) | (4 << 21) | (5 << 16) | (2 << 11) | (0 << 6) | 8);
    expect(core.disasm(0, 0x1014).$1, contains('paddw v0, a0, a1'));

    // COP0: eret (op=16, rs=16, fn=24)
    core.bus.write32(0x1018, (16 << 26) | (16 << 21) | 24);
    expect(core.disasm(0, 0x1018).$1, contains('eret'));

    // COP1: add.s f0, f1, f2 (op=17, rs=16, rt=2, rd=1, sa=0, fn=0)
    core.bus.write32(
        0x101c, (17 << 26) | (16 << 21) | (2 << 16) | (1 << 11) | (0 << 6) | 0);
    expect(core.disasm(0, 0x101c).$1, contains('add.s f0, f1, f2'));

    // COP2: qmfc2 v0, vf1 (op=18, rs=1, rt=2, rd=1)
    core.bus.write32(0x1020, (18 << 26) | (1 << 21) | (2 << 16) | (1 << 11));
    expect(core.disasm(0, 0x1020).$1, contains('qmfc2 v0, vf1'));
  });

  test('PS2 IOP disassembly covers MIPS I instructions', () {
    // nop
    core.iopMemory.write32(0x1000, 0x00000000);
    expect(core.disasm(1, 0x1000).$1, contains('nop'));
    expect(core.disasm(1, 0x1000).$2, 4);

    // addiu v0, zero, 1
    core.iopMemory.write32(0x1004, 0x24020001);
    expect(core.disasm(1, 0x1004).$1, contains('li v0, 1'));

    // rfe (0x42000010)
    core.iopMemory.write32(0x1008, 0x42000010);
    expect(core.disasm(1, 0x1008).$1, contains('rfe'));
  });

  test('PS2 trace and dump reports status and registers', () {
    core.bus.write32(core.cpu.pc, 0x00000000);
    final eeTrace = core.trace(0);
    expect(eeTrace.pc, core.cpu.pc);
    expect(eeTrace.disasm, contains('nop'));
    expect(eeTrace.regs, contains('CP0[0]'));
    expect(eeTrace.regs, contains('HI:'));

    final iopTrace = core.trace(1);
    expect(iopTrace.pc, core.iop.pc);
    expect(iopTrace.regs, contains('r0:'));

    final dumpReport = core.dump();
    expect(dumpReport, contains('PS2 (EE R5900 + IOP)'));
    expect(dumpReport, contains('EE'));
    expect(dumpReport, contains('IOP'));
    expect(dumpReport, contains('GS CSR:'));
    expect(dumpReport, contains('INTC stat:'));
    expect(dumpReport, contains('DMAC stat:'));
  });
}

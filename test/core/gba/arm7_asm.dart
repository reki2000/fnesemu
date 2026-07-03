/// Tiny hand-assembler for ARMv4T (ARM + Thumb) opcodes.
///
/// Used by the ARM7TDMI unit tests and the self-checking test-ROM generator.
/// Each helper returns the raw 32-bit (ARM) or 16-bit (Thumb) encoding as
/// specified in the ARM7TDMI datasheet. Only the forms the tests need are
/// covered.
library;

// --- condition codes ---------------------------------------------------------
const condEq = 0x0;
const condNe = 0x1;
const condAl = 0xe;

// --- barrel shifter types ----------------------------------------------------
const shLsl = 0;
const shLsr = 1;
const shAsr = 2;
const shRor = 3; // shImm 0 = RRX

// --- ARM: data processing ----------------------------------------------------
// opcode field (bits 24..21)
const _opSub = 2;
const _opAdd = 4;
const _opAdc = 5;
const _opSbc = 6;
const _opCmp = 10;
const _opOrr = 12;
const _opMov = 13;
const _opMvn = 15;

// immediate operand2: imm8 rotated right by 2*rot4
int _dpI(int cond, int opc, bool s, int rn, int rd, int rot4, int imm8) =>
    (cond << 28) |
    (1 << 25) |
    (opc << 21) |
    ((s ? 1 : 0) << 20) |
    (rn << 16) |
    (rd << 12) |
    (rot4 << 8) |
    imm8;

// register operand2 with immediate shift
int _dpR(int cond, int opc, bool s, int rn, int rd, int shImm, int shType,
        int rm) =>
    (cond << 28) |
    (opc << 21) |
    ((s ? 1 : 0) << 20) |
    (rn << 16) |
    (rd << 12) |
    (shImm << 7) |
    (shType << 5) |
    rm;

int aMovI(int rd, int imm8, {int rot4 = 0, bool s = false, int cond = condAl}) =>
    _dpI(cond, _opMov, s, 0, rd, rot4, imm8);

int aMvnI(int rd, int imm8, {int rot4 = 0, bool s = false, int cond = condAl}) =>
    _dpI(cond, _opMvn, s, 0, rd, rot4, imm8);

int aAddI(int rd, int rn, int imm8,
        {int rot4 = 0, bool s = false, int cond = condAl}) =>
    _dpI(cond, _opAdd, s, rn, rd, rot4, imm8);

int aSubI(int rd, int rn, int imm8,
        {int rot4 = 0, bool s = false, int cond = condAl}) =>
    _dpI(cond, _opSub, s, rn, rd, rot4, imm8);

int aAdcI(int rd, int rn, int imm8,
        {int rot4 = 0, bool s = false, int cond = condAl}) =>
    _dpI(cond, _opAdc, s, rn, rd, rot4, imm8);

int aSbcI(int rd, int rn, int imm8,
        {int rot4 = 0, bool s = false, int cond = condAl}) =>
    _dpI(cond, _opSbc, s, rn, rd, rot4, imm8);

int aOrrI(int rd, int rn, int imm8,
        {int rot4 = 0, bool s = false, int cond = condAl}) =>
    _dpI(cond, _opOrr, s, rn, rd, rot4, imm8);

int aCmpI(int rn, int imm8, {int rot4 = 0, int cond = condAl}) =>
    _dpI(cond, _opCmp, true, rn, 0, rot4, imm8);

int aMovR(int rd, int rm,
        {int shType = shLsl, int shImm = 0, bool s = false, int cond = condAl}) =>
    _dpR(cond, _opMov, s, 0, rd, shImm, shType, rm);

int aAddR(int rd, int rn, int rm, {bool s = false, int cond = condAl}) =>
    _dpR(cond, _opAdd, s, rn, rd, 0, 0, rm);

int aSubR(int rd, int rn, int rm, {bool s = false, int cond = condAl}) =>
    _dpR(cond, _opSub, s, rn, rd, 0, 0, rm);

int aCmpR(int rn, int rm, {int cond = condAl}) =>
    _dpR(cond, _opCmp, true, rn, 0, 0, 0, rm);

int aOrrR(int rd, int rn, int rm, {bool s = false, int cond = condAl}) =>
    _dpR(cond, _opOrr, s, rn, rd, 0, 0, rm);

/// MOV rd, rm, {shType} rs  — shift amount taken from a register.
int aMovRS(int rd, int rm, int rs,
        {int shType = shLsl, bool s = false, int cond = condAl}) =>
    (cond << 28) |
    (_opMov << 21) |
    ((s ? 1 : 0) << 20) |
    (rd << 12) |
    (rs << 8) |
    (shType << 5) |
    0x10 |
    rm;

/// build an arbitrary 32-bit constant with MOV + up to three ORRs
/// (each byte is an 8-bit immediate with a rotation).
List<int> aMovI32(int rd, int v, {int cond = condAl}) => [
      aMovI(rd, v & 0xff, cond: cond),
      if (v & 0xff00 != 0) aOrrI(rd, rd, (v >> 8) & 0xff, rot4: 12, cond: cond),
      if (v & 0xff0000 != 0)
        aOrrI(rd, rd, (v >> 16) & 0xff, rot4: 8, cond: cond),
      if (v & 0xff000000 != 0)
        aOrrI(rd, rd, (v >> 24) & 0xff, rot4: 4, cond: cond),
    ];

const aNop = 0xe1a00000; // mov r0, r0

// --- ARM: multiply -----------------------------------------------------------

/// MUL rd, rm, rs
int aMul(int rd, int rm, int rs, {bool s = false, int cond = condAl}) =>
    (cond << 28) | ((s ? 1 : 0) << 20) | (rd << 16) | (rs << 8) | 0x90 | rm;

/// MLA rd, rm, rs, rn  (rd = rm*rs + rn)
int aMla(int rd, int rm, int rs, int rn, {bool s = false, int cond = condAl}) =>
    (cond << 28) |
    0x00200000 |
    ((s ? 1 : 0) << 20) |
    (rd << 16) |
    (rn << 12) |
    (rs << 8) |
    0x90 |
    rm;

/// UMULL rdLo, rdHi, rm, rs
int aUmull(int rdLo, int rdHi, int rm, int rs,
        {bool s = false, int cond = condAl}) =>
    (cond << 28) |
    0x00800090 |
    ((s ? 1 : 0) << 20) |
    (rdHi << 16) |
    (rdLo << 12) |
    (rs << 8) |
    rm;

/// SMULL rdLo, rdHi, rm, rs
int aSmull(int rdLo, int rdHi, int rm, int rs,
        {bool s = false, int cond = condAl}) =>
    (cond << 28) |
    0x00c00090 |
    ((s ? 1 : 0) << 20) |
    (rdHi << 16) |
    (rdLo << 12) |
    (rs << 8) |
    rm;

// --- ARM: single data transfer -------------------------------------------------

int _sdt(int cond, bool load, bool byte, bool pre, bool up, bool wb, int rn,
        int rd, int off12) =>
    (cond << 28) |
    (1 << 26) |
    ((pre ? 1 : 0) << 24) |
    ((up ? 1 : 0) << 23) |
    ((byte ? 1 : 0) << 22) |
    ((wb ? 1 : 0) << 21) |
    ((load ? 1 : 0) << 20) |
    (rn << 16) |
    (rd << 12) |
    off12;

int aLdr(int rd, int rn, int off,
        {bool pre = true, bool up = true, bool wb = false, int cond = condAl}) =>
    _sdt(cond, true, false, pre, up, wb, rn, rd, off);

int aStr(int rd, int rn, int off,
        {bool pre = true, bool up = true, bool wb = false, int cond = condAl}) =>
    _sdt(cond, false, false, pre, up, wb, rn, rd, off);

int aLdrb(int rd, int rn, int off,
        {bool pre = true, bool up = true, bool wb = false, int cond = condAl}) =>
    _sdt(cond, true, true, pre, up, wb, rn, rd, off);

int aStrb(int rd, int rn, int off,
        {bool pre = true, bool up = true, bool wb = false, int cond = condAl}) =>
    _sdt(cond, false, true, pre, up, wb, rn, rd, off);

// --- ARM: halfword / signed transfer (immediate offset) -----------------------

// sh: 1 = unsigned half, 2 = signed byte, 3 = signed half
int _hdt(int cond, bool load, int sh, bool pre, bool up, bool wb, int rn,
        int rd, int off8) =>
    (cond << 28) |
    ((pre ? 1 : 0) << 24) |
    ((up ? 1 : 0) << 23) |
    (1 << 22) | // immediate form
    ((wb ? 1 : 0) << 21) |
    ((load ? 1 : 0) << 20) |
    (rn << 16) |
    (rd << 12) |
    ((off8 >> 4) << 8) |
    0x90 |
    (sh << 5) |
    (off8 & 0xf);

int aLdrh(int rd, int rn, int off, {int cond = condAl}) =>
    _hdt(cond, true, 1, true, true, false, rn, rd, off);

int aStrh(int rd, int rn, int off, {int cond = condAl}) =>
    _hdt(cond, false, 1, true, true, false, rn, rd, off);

int aLdrsb(int rd, int rn, int off, {int cond = condAl}) =>
    _hdt(cond, true, 2, true, true, false, rn, rd, off);

int aLdrsh(int rd, int rn, int off, {int cond = condAl}) =>
    _hdt(cond, true, 3, true, true, false, rn, rd, off);

// --- ARM: block transfer -------------------------------------------------------

/// LDMIA by default (pre=false, up=true)
int aLdm(int rn, int list,
        {bool pre = false, bool up = true, bool wb = false, int cond = condAl}) =>
    (cond << 28) |
    (4 << 25) |
    ((pre ? 1 : 0) << 24) |
    ((up ? 1 : 0) << 23) |
    ((wb ? 1 : 0) << 21) |
    (1 << 20) |
    (rn << 16) |
    list;

/// STMIA by default (pre=false, up=true)
int aStm(int rn, int list,
        {bool pre = false, bool up = true, bool wb = false, int cond = condAl}) =>
    (cond << 28) |
    (4 << 25) |
    ((pre ? 1 : 0) << 24) |
    ((up ? 1 : 0) << 23) |
    ((wb ? 1 : 0) << 21) |
    (rn << 16) |
    list;

// --- ARM: branch / misc --------------------------------------------------------

/// B with a signed word offset relative to pc+8:
/// target = thisInstr + 8 + 4*offWords. offWords=0 skips exactly one word.
int aB(int offWords, {bool link = false, int cond = condAl}) =>
    (cond << 28) | (5 << 25) | ((link ? 1 : 0) << 24) | (offWords & 0xffffff);

int aBl(int offWords, {int cond = condAl}) => aB(offWords, link: true, cond: cond);

const aBSelf = 0xeafffffe; // b .

int aBx(int rm, {int cond = condAl}) => (cond << 28) | 0x012fff10 | rm;

int aMrs(int rd, {int cond = condAl}) => (cond << 28) | 0x010f0000 | (rd << 12);

/// MSR CPSR_f, #imm (flags field only)
int aMsrFlagsI(int imm8, {int rot4 = 0, int cond = condAl}) =>
    (cond << 28) | 0x0328f000 | (rot4 << 8) | imm8;

/// MSR CPSR_c, #imm (control field only: mode/I/F bits)
int aMsrCtlI(int imm8, {int rot4 = 0, int cond = condAl}) =>
    (cond << 28) | 0x0321f000 | (rot4 << 8) | imm8;

/// SWP rd, rm, [rn]
int aSwp(int rd, int rm, int rn, {bool byte = false, int cond = condAl}) =>
    (cond << 28) |
    0x01000090 |
    ((byte ? 1 : 0) << 22) |
    (rn << 16) |
    (rd << 12) |
    rm;

int aSwi(int imm24) => 0xef000000 | imm24;

// === Thumb ====================================================================

// format 1: shift by immediate
int tLslsI(int rd, int rm, int imm5) => (imm5 << 6) | (rm << 3) | rd;
int tLsrsI(int rd, int rm, int imm5) => 0x0800 | (imm5 << 6) | (rm << 3) | rd;
int tAsrsI(int rd, int rm, int imm5) => 0x1000 | (imm5 << 6) | (rm << 3) | rd;

// format 2: add/sub register or 3-bit immediate
int tAddR(int rd, int rn, int rm) => 0x1800 | (rm << 6) | (rn << 3) | rd;
int tSubR(int rd, int rn, int rm) => 0x1a00 | (rm << 6) | (rn << 3) | rd;
int tAddI3(int rd, int rn, int imm3) => 0x1c00 | (imm3 << 6) | (rn << 3) | rd;
int tSubI3(int rd, int rn, int imm3) => 0x1e00 | (imm3 << 6) | (rn << 3) | rd;

// format 3: mov/cmp/add/sub with 8-bit immediate
int tMovsI(int rd, int imm8) => 0x2000 | (rd << 8) | imm8;
int tCmpI(int rd, int imm8) => 0x2800 | (rd << 8) | imm8;
int tAddI8(int rd, int imm8) => 0x3000 | (rd << 8) | imm8;
int tSubI8(int rd, int imm8) => 0x3800 | (rd << 8) | imm8;

// format 4: register ALU (rd = rd op rm)
int _t4(int op, int rd, int rm) => 0x4000 | (op << 6) | (rm << 3) | rd;
int tAnds(int rd, int rm) => _t4(0, rd, rm);
int tEors(int rd, int rm) => _t4(1, rd, rm);
int tNegs(int rd, int rm) => _t4(9, rd, rm);
int tOrrs(int rd, int rm) => _t4(12, rd, rm);
int tMuls(int rd, int rm) => _t4(13, rd, rm);
int tMvns(int rd, int rm) => _t4(15, rd, rm);

// format 5: hi-register ops / BX (full 4-bit register numbers)
int _t5(int op, int rd, int rm) =>
    0x4400 | (op << 8) | ((rd >> 3) << 7) | ((rm >> 3) << 6) | ((rm & 7) << 3) | (rd & 7);
int tAddHi(int rd, int rm) => _t5(0, rd, rm);
int tMovHi(int rd, int rm) => _t5(2, rd, rm);
int tBx(int rm) => 0x4700 | ((rm >> 3) << 6) | ((rm & 7) << 3);
const tBxLr = 0x4770;

// format 6: pc-relative load (word8 = offset/4 from (pc+4)&~3)
int tLdrPc(int rd, int word8) => 0x4800 | (rd << 8) | word8;

// format 7/9: register / 5-bit immediate offset word transfer
int tStrR(int rd, int rb, int ro) => 0x5000 | (ro << 6) | (rb << 3) | rd;
int tLdrR(int rd, int rb, int ro) => 0x5800 | (ro << 6) | (rb << 3) | rd;
int tStrI(int rd, int rb, int imm5w) => 0x6000 | (imm5w << 6) | (rb << 3) | rd;
int tLdrI(int rd, int rb, int imm5w) => 0x6800 | (imm5w << 6) | (rb << 3) | rd;

// format 13/14: push/pop (list = low register bitmask)
int tPush(int list, {bool lr = false}) => 0xb400 | ((lr ? 1 : 0) << 8) | list;
int tPop(int list, {bool pc = false}) => 0xbc00 | ((pc ? 1 : 0) << 8) | list;

// format 16/18: branches (offsets in halfwords relative to pc+4)
int tBCond(int cond, int off8) => 0xd000 | (cond << 8) | (off8 & 0xff);
int tB(int off11) => 0xe000 | (off11 & 0x7ff);
const tBSelf = 0xe7fe; // b .
int tBlHi(int off11) => 0xf000 | (off11 & 0x7ff);
int tBlLo(int off11) => 0xf800 | (off11 & 0x7ff);

const tNop = 0x46c0; // mov r8, r8

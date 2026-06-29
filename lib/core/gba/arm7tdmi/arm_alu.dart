part of 'arm7.dart';

/// Barrel shifter and arithmetic helpers shared by the ARM and THUMB decoders.
extension ArmAlu on Arm7 {
  /// barrel shifter.
  /// [type]: 0=LSL 1=LSR 2=ASR 3=ROR.
  /// [imm]=true uses the immediate-form special cases (#0 meanings, RRX);
  /// [imm]=false uses the register-form rules (amount = Rs & 0xff).
  /// updates [_shiftC] with the carry-out.
  int _barrel(int type, int v, int amount, {required bool imm}) {
    v &= 0xffffffff;

    if (imm) {
      switch (type) {
        case 0: // LSL
          if (amount == 0) return v; // C unchanged
          _shiftC = (v >> (32 - amount)) & 1 != 0;
          return (v << amount) & 0xffffffff;
        case 1: // LSR (#0 means #32)
          if (amount == 0) {
            _shiftC = v & 0x80000000 != 0;
            return 0;
          }
          _shiftC = (v >> (amount - 1)) & 1 != 0;
          return v >>> amount;
        case 2: // ASR (#0 means #32)
          if (amount == 0) {
            _shiftC = v & 0x80000000 != 0;
            return _shiftC ? 0xffffffff : 0;
          }
          _shiftC = (v >> (amount - 1)) & 1 != 0;
          return (v.toSigned(32) >> amount) & 0xffffffff;
        default: // 3: ROR (#0 means RRX)
          if (amount == 0) {
            final cin = regs.cf ? 1 : 0;
            _shiftC = v & 1 != 0;
            return ((v >>> 1) | (cin << 31)) & 0xffffffff;
          }
          _shiftC = (v >> (amount - 1)) & 1 != 0;
          return ((v >>> amount) | (v << (32 - amount))) & 0xffffffff;
      }
    } else {
      // register form
      if (amount == 0) return v; // C unchanged, value passes through
      switch (type) {
        case 0: // LSL
          if (amount < 32) {
            _shiftC = (v >> (32 - amount)) & 1 != 0;
            return (v << amount) & 0xffffffff;
          }
          if (amount == 32) {
            _shiftC = v & 1 != 0;
            return 0;
          }
          _shiftC = false;
          return 0;
        case 1: // LSR
          if (amount < 32) {
            _shiftC = (v >> (amount - 1)) & 1 != 0;
            return v >>> amount;
          }
          if (amount == 32) {
            _shiftC = v & 0x80000000 != 0;
            return 0;
          }
          _shiftC = false;
          return 0;
        case 2: // ASR
          if (amount < 32) {
            _shiftC = (v >> (amount - 1)) & 1 != 0;
            return (v.toSigned(32) >> amount) & 0xffffffff;
          }
          _shiftC = v & 0x80000000 != 0;
          return _shiftC ? 0xffffffff : 0;
        default: // 3: ROR
          final a = amount & 31;
          if (a == 0) {
            _shiftC = v & 0x80000000 != 0;
            return v;
          }
          _shiftC = (v >> (a - 1)) & 1 != 0;
          return ((v >>> a) | (v << (32 - a))) & 0xffffffff;
      }
    }
  }

  /// add with carry; records carry/overflow in [_aluC]/[_aluV].
  int _adc(int a, int b, int cin) {
    final sum = a + b + cin; // dart ints are 64-bit, no overflow up to 2^33
    _aluC = sum > 0xffffffff;
    final res = sum & 0xffffffff;
    _aluV = ((a ^ res) & (b ^ res) & 0x80000000) != 0;
    return res;
  }

  /// a - b (borrow = !carry). overflow/carry recorded in [_aluV]/[_aluC].
  int _sbc(int a, int b, int cin) => _adc(a, (~b) & 0xffffffff, cin);
}

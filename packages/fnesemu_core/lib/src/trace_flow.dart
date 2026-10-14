import 'types.dart';

int _signed(int value, int bits) =>
    (value & ((1 << bits) - 1)) - (value & (1 << (bits - 1))) * 2;

/// Debug-only native instruction semantics; never parse assembly text.
TraceFlow trace6502Flow(int op, int pc,
    {int operand = 0, bool pce = false, bool wide = false}) {
  final bank = wide ? pc & 0xff0000 : 0;
  int next(int length) => bank | ((pc + length) & 0xffff);
  if (op == 0x20) {
    return TraceFlow.call(next(3), target: bank | operand & 0xffff);
  }
  if (wide && op == 0x22) {
    return TraceFlow.call(next(4), target: operand & 0xffffff);
  }
  if (wide && op == 0xfc) {
    return TraceFlow.call(next(3));
  }
  if (pce && op == 0x44) {
    return TraceFlow.call(next(2),
        target: (next(2) + _signed(operand, 8)) & 0xffff);
  }
  if (op == 0x60 || wide && op == 0x6b) {
    return const TraceFlow.returned();
  }
  if (op == 0x40) {
    return const TraceFlow.interruptReturn();
  }
  if (op == 0 || wide && op == 2) {
    return TraceFlow.exception(next(2));
  }
  return TraceFlow.none;
}

TraceFlow traceZ80Flow(int op, int pc, int flags,
    {int operand = 0, int second = 0, bool gb = false}) {
  bool condition(int code) {
    final z = flags & (gb ? 0x80 : 0x40) != 0, c = flags & (gb ? 0x10 : 1) != 0;
    return switch (code) {
      0 => !z,
      1 => z,
      2 => !c,
      3 => c,
      4 => flags & 4 == 0,
      5 => flags & 4 != 0,
      6 => flags & 0x80 == 0,
      _ => flags & 0x80 != 0,
    };
  }

  if (op == 0xcd ||
      op & 0xc7 == 0xc4 &&
          (!gb || (op >> 3 & 7) < 4) &&
          condition(op >> 3 & 7)) {
    return TraceFlow.call((pc + 3) & 0xffff, target: operand & 0xffff);
  }
  if (op & 0xc7 == 0xc7) {
    return TraceFlow.call((pc + 1) & 0xffff, target: op & 0x38);
  }
  if (op == 0xc9 ||
      op & 0xc7 == 0xc0 &&
          (!gb || (op >> 3 & 7) < 4) &&
          condition(op >> 3 & 7)) {
    return const TraceFlow.returned();
  }
  if (gb && op == 0xd9 || !gb && op == 0xed && second & 0xc7 == 0x45) {
    return const TraceFlow.interruptReturn();
  }
  return TraceFlow.none;
}

TraceFlow traceM68kFlow(int op, int pc, {int extension = 0, int? target}) {
  if (op & 0xff00 == 0x6100) {
    final length = op & 255 == 0 ? 4 : 2;
    final offset = op & 255 == 0 ? _signed(extension, 16) : _signed(op, 8);
    return TraceFlow.call((pc + length) & 0xffffff,
        target: (pc + 2 + offset) & 0xffffff);
  }
  if (op & 0xffc0 == 0x4e80) {
    final mode = op >> 3 & 7, reg = op & 7;
    final length = mode == 5 || mode == 6 || mode == 7 && reg != 1
        ? 4
        : mode == 7 && reg == 1
            ? 6
            : 2;
    return TraceFlow.call((pc + length) & 0xffffff, target: target);
  }
  if (op == 0x4e75 || op == 0x4e77) {
    return const TraceFlow.returned();
  }
  if (op == 0x4e73) {
    return const TraceFlow.interruptReturn();
  }
  if (op & 0xfff0 == 0x4e40) {
    return TraceFlow.exception((pc + 2) & 0xffffff);
  }
  return TraceFlow.none;
}

TraceFlow traceSh2Flow(int op, int pc) {
  if (op & 0xf000 == 0xb000) {
    return TraceFlow.call((pc + 4) & 0xffffffff,
        target: (pc + 4 + _signed(op, 12) * 2) & 0xffffffff, delaySlots: 1);
  }
  if (op & 0xf0ff == 0x400b || op & 0xf0ff == 0x0003) {
    return TraceFlow.call((pc + 4) & 0xffffffff, delaySlots: 1);
  }
  if (op == 0x000b) {
    return const TraceFlow.returned(delaySlots: 1);
  }
  if (op == 0x002b) {
    return const TraceFlow.interruptReturn(delaySlots: 1);
  }
  if (op & 0xff00 == 0xc300) {
    return TraceFlow.exception((pc + 2) & 0xffffffff);
  }
  return TraceFlow.none;
}

TraceFlow traceMipsFlow(int op, int pc, List<int> registers,
    {bool wide = false}) {
  final major = op >>> 26,
      rs = op >>> 21 & 31,
      rt = op >>> 16 & 31,
      rd = op >>> 11 & 31;
  int address(int value) => value & 0xffffffff;
  if (major == 3) {
    return TraceFlow.call(address(pc + 8),
        target: address((pc + 4) & 0xf0000000 | (op & 0x03ffffff) << 2),
        delaySlots: 1);
  }
  if (major == 0 && op & 63 == 9 && rd != 0) {
    return TraceFlow.call(address(pc + 8),
        target: address(registers[rs]), delaySlots: 1);
  }
  if (major == 1 && rt >= 16 && rt <= 19) {
    final value = wide ? registers[rs] : _signed(registers[rs], 32);
    final taken = rt & 1 == 0 ? value < 0 : value >= 0;
    if (taken) {
      return TraceFlow.call(address(pc + 8),
          target: address(pc + 4 + _signed(op, 16) * 4), delaySlots: 1);
    }
  }
  if (major == 0 && op & 63 == 8) {
    return rs == 31
        ? const TraceFlow.returned(delaySlots: 1)
        : const TraceFlow.jump(delaySlots: 1);
  }
  return TraceFlow.none;
}

bool _armCondition(int condition, int status) {
  final n = status & 0x80000000 != 0, z = status & 0x40000000 != 0;
  final c = status & 0x20000000 != 0, v = status & 0x10000000 != 0;
  return switch (condition) {
    0 => z,
    1 => !z,
    2 => c,
    3 => !c,
    4 => n,
    5 => !n,
    6 => v,
    7 => !v,
    8 => c && !z,
    9 => !c || z,
    10 => n == v,
    11 => n != v,
    12 => !z && n == v,
    13 => z || n != v,
    14 => true,
    _ => false,
  };
}

TraceFlow traceArmFlow(int op, int pc, int status, List<int> registers) {
  if (status & 32 != 0) {
    if (op & 0xf800 == 0xf800) {
      return TraceFlow.call((pc + 2) & 0xfffffffe,
          target: (registers[14] + (op & 0x7ff) * 2) & 0xfffffffe);
    }
    if (op & 0xff87 == 0x4700) {
      return op >> 3 & 15 == 14
          ? const TraceFlow.returned()
          : const TraceFlow.jump();
    }
    if (op & 0xff00 == 0xbd00) {
      return const TraceFlow.returned();
    }
    if (op & 0xff00 == 0xdf00) {
      return TraceFlow.exception((pc + 2) & 0xffffffff);
    }
    return TraceFlow.none;
  }
  if (!_armCondition(op >>> 28, status)) {
    return TraceFlow.none;
  }
  if (op & 0x0f000000 == 0x0b000000) {
    return TraceFlow.call((pc + 4) & 0xffffffff,
        target: (pc + 8 + _signed(op, 24) * 4) & 0xffffffff);
  }
  if (op & 0x0ffffff0 == 0x012fff10) {
    return op & 15 == 14 ? const TraceFlow.returned() : const TraceFlow.jump();
  }
  if (op & 0x0fe0ffff == 0x01a0f00e) {
    return op & 0x100000 != 0
        ? const TraceFlow.interruptReturn()
        : const TraceFlow.returned();
  }
  if (op & 0x0fff0000 == 0x08bd0000 && op & 0x8000 != 0) {
    return const TraceFlow.returned();
  }
  if (op & 0x0ffff000 == 0x025ef000) {
    return const TraceFlow.interruptReturn();
  }
  if (op & 0x0f000000 == 0x0f000000) {
    return TraceFlow.exception((pc + 4) & 0xffffffff);
  }
  return TraceFlow.none;
}

part of 'r3000.dart';

extension Hook on R3000 {
  static int biosCallAddr = 0;

  String dumpCString(int addr, {maxLength = 32}) {
    final sb = StringBuffer();
    for (int i = 0; i < maxLength; i++) {
      final ch = bus.read8(addr + i).mask8;
      if (ch == 0) break;
      sb.writeCharCode(ch);
    }
    return sb.toString();
  }

  String dump8(int addr, int len) =>
      range(0, len).map((i) => "0x${bus.read8(addr + i).hex8}").join(":");

  String dump8x(int addr, int len) =>
      range(0, len).map((i) => bus.read8(addr + i).hex8).join(":");

  String dumpc(int addr, int len) {
    final sb = StringBuffer();
    for (int i = 0; i < len; i++) {
      final ch = bus.read8(addr + i).mask8;
      if (ch == 0x0a || (ch >= 0x20 && ch < 0x7f)) {
        sb.writeCharCode(ch);
      } else {
        sb.write(".");
      }
    }
    return sb.toString();
  }

  handleTty(int ch) {
    switch (ch) {
      case >= 0x20 && < 0x80 || 0x09:
        console.write(String.fromCharCode(ch));
      case 0x0a:
        debugLog("tty: ${console.toString()}");
        console.clear();
    }
  }

  String buildArgs(String funcSpec, List<int> regs) {
    final regex = RegExp(r'%[0-9]*[dxcb]');
    final matches = regex.allMatches(funcSpec).toList();
    int i = 0;
    String result = funcSpec;
    int offset = 0;

    for (final match in matches) {
      final format = match.group(0)!;
      final arg = switch (format) {
        "%d" => regs[i++].toString(),
        "%08x" => "0x${regs[i++].hex32}",
        "%04x" => "0x${regs[i++].hex16}",
        "%02x" => "0x${regs[i++].hex8}",
        "%s" => '"${dumpCString(regs[i++])}"',
        "%b" => dump8x(regs[i++], regs[i]),
        "%B" => dump8(regs[i++], 3),
        "%c" => '"${dumpc(regs[i++], regs[i])}"',
        _ => "---",
      };
      result = result.substring(0, match.start + offset) +
          arg +
          result.substring(match.end + offset);
      offset += arg.length - format.length;
    }

    return result;
  }

  hook() {
    final vector = pc & 0x1fffff;
    if (vector == 0xa0 || vector == 0xb0 || vector == 0xc0) {
      String name = _bios[vector]?[r[9]] ?? "-";
      if (name.startsWith("*putchar")) {
        // tty putchar
        handleTty(r[4].mask8);
      } else if (name.startsWith("*write(") && (r[4] == 1 || r[4] == 2)) {
        // write to stdout/stderr
        final str = dumpc(r[5], r[6]);
        str.runes.forEach(handleTty);
      } else if (!name.startsWith("*")) {
        biosCallAddr = r[31];

        if (name.startsWith("TestEvent")) {
          biosCallAddr = 0;
        }

        if (!name.endsWith(")")) {
          name += "(%08x, %08x, %08x, %08x)";
        }

        // for strout, dump buffer as a string instead of hex dump
        if (name.startsWith("write") && (r[4] == 1 || r[4] == 2)) {
          name = name.replaceFirst("%b", "%c");
        }

        name = buildArgs(name, r.sublist(4, 8));

        debugLog("bios: ${vector.hex8}(${r[9].hex8}): $name");
      }
    }

    if (pc == biosCallAddr) {
      debugLog("bios: returns ${r[2].hex32}");
      biosCallAddr = 0;
    }

    // exe sideloading
    if (pc == 0x80030000) {
      if (exe.length > 0x400) {
        runExe();
      }
    }
  }

  void runExe() {
    pc = exe.getUInt32LE(0x10);
    nextPc = pc.inc4.mask32;

    r[28] = exe.getUInt32LE(0x14);
    if (exe.getUInt32LE(0x30) != 0) {
      r[29] = r[30] = exe.getUInt32LE(0x30);
    }

    final loadAddr = exe.getUInt32LE(0x18);
    final size = exe.getUInt32LE(0x1c);
    const headerSize = 0x800;
    for (int i = 0; i < exe.length - headerSize; i += 4) {
      write32(i + loadAddr, exe.getUInt32LE(i + headerSize));
    }

    debugLog(
        "exe sideloaded on ${loadAddr.hex32} size:${size.hex32} entry:${pc.hex32}");
  }
}

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
      if (ch >= 0x20 && ch < 0x7f) {
        sb.writeCharCode(ch);
      } else {
        sb.write(".");
      }
    }
    return sb.toString();
  }

  hook() {
    final vector = pc & 0x1fffff;
    if (vector == 0xa0 || vector == 0xb0 || vector == 0xc0) {
      final name = _bios[vector]?[r[9]] ?? "-";
      // tty putchar
      if (vector == 0xb0 && r[9] == 0x3d || vector == 0xa0 && r[9] == 0x3c) {
        final ch = r[4].mask8;
        switch (ch) {
          case >= 0x20 && < 0x80 || 0x09:
            console.write(String.fromCharCode(ch));
          case 0x0a:
            debugLog("bios: tty: ${console.toString()}");
            console.clear();
        }
      } else {
        if (!name.startsWith("*")) {
          biosCallAddr = r[31];

          String args = [4, 5, 6, 7].map((i) => r[i].hex32).join(",");
          if (name == "CdAsyncSeekL") {
            args = dump8(r[4], 3);
          } else if (name == "open") {
            args = "${r[4]},[${dumpCString(r[4])}], 0x${r[5].hex32}";
          } else if (name == "write") {
            if (r[4] == 1) {
              args = "stdout,[${dumpc(r[5], r[6])}]";
            } else {
              args = "${r[4]},[${dump8x(r[5], r[6])}]";
            }
          } else if (name == "TestEvent") {
            biosCallAddr = 0;
          }

          debugLog("bios: called ${vector.hex8}(${r[9].hex32}): $name($args)");
        }
      }
    }

    if (pc == biosCallAddr) {
      debugLog("bios: returns ${r[2].hex32} pc:${pc.hex32}");
      biosCallAddr = 0;
    }

    // exe sideloading
    if (pc == 0x80030000 && exe.length > 0x400) {
      pc = exe.getUInt32LE(0x10);
      nextPc = pc.inc4.mask32;

      r[28] = exe.getUInt32LE(0x14);
      if (exe.getUInt32LE(0x30) != 0) {
        r[29] = r[30] = exe.getUInt32LE(0x30);
      }

      final loadAddr = exe.getUInt32LE(0x18);
      final size = exe.getUInt32LE(0x1c);
      const headerSize = 0x800;
      for (int i = 0; i < size - headerSize; i += 4) {
        write32(i + loadAddr, exe.getUInt32LE(i + headerSize));
      }

      debugLog(
          "exe sideloaded on ${loadAddr.hex32} size:${size.hex32} entry:${pc.hex32}");
    }
  }
}

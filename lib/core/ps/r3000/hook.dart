part of 'r3000.dart';

extension Hook on R3000 {
  hook() {
    final vector = pc & 0x1fffff;
    if (vector == 0xa0 || vector == 0xb0 || vector == 0xc0) {
      final name = _bios[vector]?[r[9]] ?? "-";
      switch ((vector, r[9])) {
        case (0xb0, 0x3d):
        case (0xa0, 0x3c):
        case (0xa0, 0x09):
          // tty putchar
          final ch = r[4];
          if ((ch >= 0x20 && ch < 0x80) || ch == 0x0a || ch == 0x09) {
            if (ch == 0x0a) {
              debugLog("tty clk[$clocks] : ${console.toString()}");
              console.clear();
            } else {
              console.write(String.fromCharCode(ch));
            }
          }

        default:
          if (!name.startsWith("*")) {
            debugLog("unhandled BIOS ${vector.hex8}(${r[9].hex32}): $name ");
          }
      }
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

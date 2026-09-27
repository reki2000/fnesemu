import 'dart:typed_data';
import '../pad_button.dart';
import '../sram.dart';
import '../types.dart';

class N64AddressFault implements Exception {
  final int address;
  final bool write;
  const N64AddressFault(this.address, this.write);
}

/// RDRAM and RCP register bus with synchronous bounded DMA transfers.
class N64Bus {
  final ram = Uint8List(0x800000);
  final sp = Uint8List(0x2000);
  late final ramData = ByteData.sublistView(ram);
  late final spData = ByteData.sublistView(sp);
  final pif = Uint8List(64);
  Uint8List rom = Uint8List(0);
  final vi = Uint32List(14), pi = Uint32List(13), ai = Uint32List(6);
  final ri = Uint32List(8), rdram = Uint32List(10), si = Uint32List(7);
  final spRegs = Uint32List(8), dp = Uint32List(8), mi = Uint32List(4);
  final tlb = List.generate(32, (_) => List<int>.filled(4, 0));
  final held = List.generate(4, (_) => <String>{});
  Sram? sram;
  int scanline = 0, spPc = 0;
  int audioCycles = 0;
  void Function()? onTask;
  void Function(int, int)? onDp;
  void Function(AudioBuffer)? onAudio;
  bool get interruptPending => (mi[2] & mi[3]) != 0;
  void interrupt(int mask) => mi[2] |= mask;

  void writeTlb(int index, List<int> cp) {
    tlb[index].setAll(0, [cp[10], cp[2], cp[3], cp[5]]);
  }

  void readTlb(int index, List<int> cp) {
    final e = tlb[index];
    cp[10] = e[0];
    cp[2] = e[1];
    cp[3] = e[2];
    cp[5] = e[3];
  }

  int probeTlb(int addr) {
    for (var i = 0; i < 32; i++) {
      final e = tlb[i], mask = e[3] | 0x1fff;
      if ((addr & ~mask) == (e[0] & ~mask) &&
          ((e[1] & e[2] & 1) != 0 || (addr & 255) == (e[0] & 255))) {
        return i;
      }
    }
    return 0x80000000;
  }

  int physical(int address, {bool write = false}) {
    final a = address & 0xffffffff;
    if (a >= 0x80000000 && a < 0xc0000000) return a & 0x1fffffff;
    // User KUSEG is mapped; physical debugger access uses ram directly.
    for (final e in tlb) {
      final mask = e[3] | 0x1fff;
      if ((a & ~mask) != (e[0] & ~mask)) continue;
      final page = (mask + 1) ~/ 2;
      final lo = (a & page) != 0 ? e[2] : e[1];
      if ((lo & 2) == 0 || (write && (lo & 4) == 0)) break;
      return (((lo >> 6) << 12) & ~(page - 1)) | (a & (page - 1));
    }
    // Existing small test ROMs address low physical RAM directly.
    if (a < ram.length) return a;
    if (a >= 0x04000000 && a < 0x20000000) return a;
    throw N64AddressFault(a, write);
  }

  Uint32List? registers(int a) => switch (a & 0xfff00000) {
        0x03f00000 => rdram,
        0x04000000 => spRegs,
        0x04100000 => dp,
        0x04300000 => mi,
        0x04400000 => vi,
        0x04500000 => ai,
        0x04600000 => pi,
        0x04700000 => ri,
        0x04800000 => si,
        _ => null,
      };
  int registerIndex(int a) => (a & 0xffff) ~/ 4;
  int read8(int address) {
    final a = physical(address);
    if (a < ram.length) return ram[a];
    if (a >= 0x04000000 && a < 0x04002000) return sp[a - 0x04000000];
    if (a >= 0x1fc007c0 && a < 0x1fc00800) return pif[a - 0x1fc007c0];
    if (a >= 0x10000000 && a - 0x10000000 < rom.length) {
      return rom[a - 0x10000000];
    }
    if ((a & ~3) == 0x04080000) return (spPc >> ((3 - (a & 3)) * 8)) & 255;
    final regs = registers(a), index = registerIndex(a);
    if (regs != null && index < regs.length) {
      var value = regs[index];
      if (regs == vi && index == 4) value = scanline * 2;
      if (regs == spRegs && index == 7) {
        value = spRegs[7];
        spRegs[7] = 1;
      }
      return (value >> ((3 - (a & 3)) * 8)) & 255;
    }
    throw UnsupportedError('N64 bus read 0x${a.toRadixString(16)}');
  }

  int read(int address, int size) {
    final a = physical(address);
    if (a + size <= ram.length) {
      if (size == 4) return ramData.getUint32(a);
      if (size == 2) return ramData.getUint16(a);
      if (size == 1) return ram[a];
    }
    if (size == 4 && a == 0x04080000) return spPc;
    if (size == 4 && (a & 3) == 0 && a >= 0x04040000) {
      final regs = registers(a), index = registerIndex(a);
      if (regs != null && index < regs.length) {
        if (regs == vi && index == 4) return scanline * 2;
        if (regs == spRegs && index == 7) {
          final old = spRegs[7];
          spRegs[7] = 1;
          return old;
        }
        return regs[index];
      }
    }
    var v = 0;
    for (var i = 0; i < size; i++) {
      v = (v << 8) | read8(address + i);
    }
    return v;
  }

  int ramRead(int address, int size) {
    final a = address & 0x7fffff;
    if (size == 4) return ramData.getUint32(a);
    if (size == 2) return ramData.getUint16(a);
    if (size == 1) return ram[a];
    throw ArgumentError('RAM access size $size');
  }

  void ramWrite(int address, int value, int size) {
    final a = address & 0x7fffff;
    if (size == 4) {
      ramData.setUint32(a, value);
      return;
    }
    if (size == 2) {
      ramData.setUint16(a, value);
      return;
    }
    if (size == 1) {
      ram[a] = value;
      return;
    }
    throw ArgumentError('RAM access size $size');
  }

  void write8(int address, int value) {
    final a = physical(address, write: true);
    if (a < ram.length) {
      ram[a] = value;
      return;
    }
    if (a >= 0x04000000 && a < 0x04002000) {
      sp[a - 0x04000000] = value;
      return;
    }
    if (a >= 0x1fc007c0 && a < 0x1fc00800) {
      pif[a - 0x1fc007c0] = value;
      return;
    }
    final regs = registers(a);
    if (regs != null) {
      final base = address & ~3, shift = (3 - (a & 3)) * 8;
      write(base, (read(base, 4) & ~(255 << shift)) | ((value & 255) << shift),
          4);
      return;
    }
    throw UnsupportedError('N64 bus byte write 0x${a.toRadixString(16)}');
  }

  void write(int address, int value, int size) {
    final a = physical(address, write: true);
    if (a + size <= ram.length) {
      ramWrite(a, value, size);
      return;
    }
    if (a >= 0x04000000 && a + size <= 0x04002000) {
      for (var i = 0; i < size; i++) {
        sp[a - 0x04000000 + i] = value >> ((size - i - 1) * 8);
      }
      return;
    }
    if (size == 4 && a % 4 == 0) {
      if (a == 0x04080000) {
        spPc = value & 0xffc;
        return;
      }
      final regs = registers(a), index = registerIndex(a);
      if (regs != null && index < regs.length) {
        if (regs == mi) {
          if (index == 0) {
            mi[0] = value & 0x7f;
            if ((value & 0x800) != 0) mi[2] &= ~32;
          }
          if (index == 3) {
            for (var i = 0; i < 6; i++) {
              if ((value & (1 << (i * 2))) != 0) mi[3] &= ~(1 << i);
              if ((value & (2 << (i * 2))) != 0) mi[3] |= 1 << i;
            }
          }
          return;
        }
        if (regs == vi && index == 4) {
          mi[2] &= ~8;
          return;
        }
        if (regs == pi && index == 4) {
          if ((value & 2) != 0) mi[2] &= ~16;
          pi[4] = 0;
          return;
        }
        if (regs == si && index == 6) {
          mi[2] &= ~2;
          si[6] = 0;
          return;
        }
        if (regs == ai && index == 3) {
          mi[2] &= ~4;
          return;
        }
        if (regs == spRegs && index == 7) {
          spRegs[7] = 0;
          return;
        }
        if (regs == spRegs && index == 4) {
          var status = spRegs[4];
          if ((value & 1) != 0) status &= ~1;
          if ((value & 2) != 0) status |= 1;
          if ((value & 4) != 0) status &= ~2;
          if ((value & 8) != 0) mi[2] &= ~1;
          if ((value & 16) != 0) mi[2] |= 1;
          for (var i = 0; i < 10; i++) {
            final bit = i < 2 ? 5 + i : 7 + i - 2;
            if ((value & (1 << (5 + i * 2))) != 0) status &= ~(1 << bit);
            if ((value & (2 << (5 + i * 2))) != 0) status |= 1 << bit;
          }
          spRegs[4] = status;
          if ((status & 1) == 0 && onTask != null) {
            onTask!();
            spRegs[4] |= 0x203; // HALT, BROKE, SIG2: task complete.
            if ((spRegs[4] & 0x40) != 0) interrupt(1);
          }
          return;
        }
        if (regs == dp && index == 3) {
          for (var i = 0; i < 3; i++) {
            if ((value & (1 << (i * 2))) != 0) dp[3] &= ~(1 << i);
            if ((value & (2 << (i * 2))) != 0) dp[3] |= 1 << i;
          }
          return;
        }
        regs[index] = value;
        if (regs == spRegs && (index == 2 || index == 3)) {
          _spDma(value, index == 2);
        }
        if (regs == pi && (index == 2 || index == 3)) _piDma(value, index == 3);
        if (regs == si && (index == 1 || index == 4)) {
          final dram = si[0] & 0x7fffff;
          if (dram + 64 > ram.length) throw StateError('SI DMA outside RDRAM');
          if (index == 4) {
            pif.setRange(0, 64, ram, dram);
            _pifCommands();
          } else {
            _pifCommands(); // A repeated SI read polls the cached controller command again.
            ram.setRange(dram, dram + 64, pif);
          }
          si[6] = 0x1000;
          interrupt(2);
        }
        if (regs == dp && index == 0) dp[2] = value;
        if (regs == dp && index == 1) {
          onDp?.call(dp[2], value);
          dp[2] = value;
        }
        if (regs == ai && index == 1 && value != 0) _audio(value);
        return;
      }
    }
    for (var i = 0; i < size; i++) {
      write8(address + i, value >> ((size - i - 1) * 8));
    }
  }

  void _spDma(int value, bool intoSp) {
    final length = ((value & 0xfff) | 7) + 1, count = ((value >> 12) & 255) + 1;
    final skip = (value >> 20) & 0xfff;
    var mem = spRegs[0] & 0x1ff8, dram = spRegs[1] & 0x7ffff8;
    final bank = mem & 0x1000;
    for (var row = 0; row < count; row++) {
      for (var i = 0; i < length; i++) {
        final target = bank | ((mem + i) & 0xfff);
        if (dram + i >= ram.length) throw StateError('SP DMA outside RDRAM');
        if (intoSp) {
          sp[target] = ram[dram + i];
        } else {
          ram[dram + i] = sp[target];
        }
      }
      mem = bank | ((mem + length) & 0xfff);
      dram += length + skip;
    }
    spRegs[0] = mem;
    spRegs[1] = dram - skip;
  }

  void _piDma(int value, bool intoRam) {
    final length = (value & 0xffffff) + 1, dram = pi[0] & 0x7ffffe;
    final cart = pi[1] & 0x1ffffffe;
    if (dram + length > ram.length) throw StateError('PI DMA outside RDRAM');
    if (cart >= 0x10000000 &&
        intoRam &&
        cart - 0x10000000 + length <= rom.length) {
      ram.setRange(dram, dram + length, rom, cart - 0x10000000);
    } else {
      throw UnsupportedError(
          'PI DMA cartridge address 0x${cart.toRadixString(16)}');
    }
    pi[0] = dram + length;
    pi[1] = cart + length;
    pi[4] = 0;
    interrupt(16);
  }

  void _audio(int length) {
    final start = ai[0] & 0x7ffff8, bytes = length & 0x3fff8;
    if (start + bytes > ram.length) throw StateError('AI DMA outside RDRAM');
    final rate = (48681812 ~/ (ai[4] + 1)).clamp(8000, 96000);
    final samples = Float32List(bytes ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = ramRead(start + i * 2, 2).toSigned(16) / 32768;
    }
    onAudio?.call(AudioBuffer(rate, 2, samples));
    ai[3] |= 0x40000000;
    audioCycles += (bytes ~/ 4 * 93750000) ~/ rate;
  }

  void tick(int clocks) {
    if (audioCycles > 0) {
      audioCycles -= clocks;
      if (audioCycles <= 0) {
        ai[1] = 0;
        ai[3] = 0;
        interrupt(4);
      }
    }
  }

  void _pifCommands() {
    if ((pif[63] & 0x30) != 0) {
      pif[63] = 0x80;
      return;
    }
    var channel = 0, pos = 0;
    while (pos < 63) {
      final tx = pif[pos];
      if (tx == 0xfe) break;
      if (tx == 0xff || tx == 0xfd) {
        pos++;
        continue;
      }
      if (tx == 0) {
        channel++;
        pos++;
        continue;
      }
      if (pos + 2 >= 63) break;
      final rx = pif[pos + 1] & 63, send = tx & 63;
      final response = pos + 2 + send;
      if (send == 0 || response + rx > 63) break;
      final command = pif[pos + 2];
      bool connected = false;
      if (channel < 4 && channel == 0) {
        connected = true;
        if ((command == 0 || command == 255) && rx >= 3) {
          pif[response] = 5;
          pif[response + 1] = 0;
          pif[response + 2] = 0;
        } else if (command == 1 && rx >= 4) {
          final keys = held[channel];
          var bits = 0;
          const buttons = {
            'A': 0x8000,
            'B': 0x4000,
            'Z': 0x2000,
            'start': 0x1000,
            'L': 0x20,
            'R': 0x10,
            'C-up': 8,
            'C-down': 4,
            'C-left': 2,
            'C-right': 1
          };
          for (final e in buttons.entries) {
            if (keys.contains(e.key)) bits |= e.value;
          }
          pif[response] = bits >> 8;
          pif[response + 1] = bits;
          pif[response + 2] = (keys.contains('right') ? 80 : 0) -
              (keys.contains('left') ? 80 : 0);
          pif[response + 3] =
              (keys.contains('up') ? 80 : 0) - (keys.contains('down') ? 80 : 0);
        }
      } else if (channel == 4 && sram != null) {
        connected = true;
        if ((command == 0 || command == 255) && rx >= 3) {
          pif[response] = 0;
          pif[response + 1] = 0x80;
          pif[response + 2] = 0;
        } else if (command == 4 && rx >= 8 && send >= 2) {
          final offset = pif[pos + 3] * 8;
          for (var i = 0; i < 8; i++) {
            pif[response + i] = sram!.read8(offset + i);
          }
        } else if (command == 5 && send >= 10 && rx >= 1) {
          final offset = pif[pos + 3] * 8;
          for (var i = 0; i < 8; i++) {
            sram!.write8(offset + i, pif[pos + 4 + i]);
          }
          pif[response] = 0;
        }
      }
      if (!connected) pif[pos + 1] |= 0x80;
      pos = response + rx;
      channel++;
    }
    pif[63] = 0;
  }

  void pad(int id, PadButton key, bool down) {
    if (id < 0 || id >= 4) return;
    if (down) {
      held[id].add(key.name);
    } else {
      held[id].remove(key.name);
    }
  }

  void reset() {
    ram.fillRange(0, ram.length, 0);
    sp.fillRange(0, sp.length, 0);
    pif.fillRange(0, 64, 0);
    for (final regs in [vi, pi, ai, ri, rdram, si, spRegs, dp, mi]) {
      regs.fillRange(0, regs.length, 0);
    }
    for (final e in tlb) {
      e.fillRange(0, 4, 0);
    }
    for (final keys in held) {
      keys.clear();
    }
    scanline = 0;
    spPc = 0;
    audioCycles = 0;
    mi[1] = 0x02020102;
    spRegs[4] = 1;
  }

  /// VI raw framebuffer scanout, without filtering or interlacing.
  ImageBuffer image() {
    final mode = vi[0] & 3;
    final stride = vi[2] & 0xfff;
    final hStart = (vi[9] >> 16) & 0x3ff;
    final hEnd = vi[9] & 0x3ff;
    final vStart = (vi[10] >> 16) & 0x3ff;
    final vEnd = vi[10] & 0x3ff;
    final width = ((hEnd - hStart) * (vi[12] & 0xfff)) ~/ 1024;
    final height = ((vEnd - vStart) * (vi[13] & 0xfff)) ~/ 2048;
    if (mode < 2 ||
        stride == 0 ||
        width <= 0 ||
        height <= 0 ||
        width > 640 ||
        height > 576) {
      return ImageBuffer(320, 240, Uint8List(320 * 240 * 4));
    }
    final output = Uint8List(width * height * 4);
    final origin = vi[1] & 0xffffff;
    final size = mode == 2 ? 2 : 4;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final source = origin + (y * stride + x) * size;
        final target = (y * width + x) * 4;
        if (x >= stride || source + size > ram.length) continue;
        if (size == 2) {
          final color = (ram[source] << 8) | ram[source + 1];
          for (var c = 0; c < 3; c++) {
            final v = (color >> (11 - c * 5)) & 31;
            output[target + c] = (v << 3) | (v >> 2);
          }
        } else {
          output.setRange(target, target + 3, ram, source);
        }
        output[target + 3] = 255;
      }
    }
    return ImageBuffer(width, height, output);
  }
}

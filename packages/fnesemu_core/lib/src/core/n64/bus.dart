import 'dart:math';
import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../pad_button.dart';
import '../../sram.dart';
import '../../state.dart';
import '../../types.dart';
import '../../util/int.dart';

/// a TLB exception: refill when no entry matches, modified when a valid
/// entry is not writable, invalid otherwise
class N64AddressFault implements Exception {
  final int address;
  final bool write;
  final bool refill;
  final bool modified;
  const N64AddressFault(this.address, this.write,
      {this.refill = false, this.modified = false});
}

/// RDRAM and RCP register bus with synchronous bounded DMA transfers.
class N64Bus {
  final Uint8List ram;

  N64Bus({Uint8List? ram}) : ram = ram ?? Uint8List(0x800000);
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
  // cartridge backup ram (SRAM games). the first 512 bytes of [sram] are the
  // EEPROM, the 32KiB after them hold this SRAM so that it is persisted too
  final cartSram = Uint8List(0x8000);
  static const sramOffset = 512;
  int _sramRead(int i) =>
      sram != null ? sram!.read8(sramOffset + i) : cartSram[i];
  void _sramWrite(int i, int v) {
    if (sram != null) {
      sram!.write8(sramOffset + i, v);
    } else {
      cartSram[i] = v;
    }
  }

  int scanline = 0, spPc = 0;
  // SP DMA addresses written last
  final _spNext = Uint32List(2);
  int audioCycles = 0;
  void Function()? onTask;
  void Function(int, int)? onDp;
  void Function(AudioBuffer)? onAudio;
  bool get interruptPending => (mi[2] & mi[3]) != 0;

  List<List<int>> get _registerFiles =>
      [vi, pi, ai, ri, rdram, si, spRegs, dp, mi, _spNext];

  /// Saves memory, registers and backup data; the ROM is not part of it.
  void saveState(StateWriter w) {
    w.section('bus');
    w.bytes(ram);
    w.bytes(sp);
    w.bytes(pif);
    _registerFiles.forEach(w.ints);
    for (final entry in tlb) {
      w.ints(entry);
    }
    for (final keys in held) {
      w.int32(keys.length);
      keys.forEach(w.string);
    }
    w.bytes(sram?.data ?? const <int>[]);
    w.bytes(cartSram);
    w.int64(scanline);
    w.int64(spPc);
    w.int64(audioCycles);
  }

  void loadState(StateReader s) {
    s.section('bus');
    s.bytesInto(ram);
    s.bytesInto(sp);
    s.bytesInto(pif);
    for (final file in _registerFiles) {
      s.intsInto(file);
    }
    for (final entry in tlb) {
      s.intsInto(entry);
    }
    for (final keys in held) {
      keys
        ..clear()
        ..addAll([for (var n = s.int32(); n > 0; n--) s.string()]);
    }
    final backup = s.bytes();
    if (sram case final sram?) {
      if (backup.length != sram.data.length) {
        throw const StateMismatch('different backup memory size');
      }
      sram.data.setAll(0, backup);
    }
    s.bytesInto(cartSram);
    scanline = s.int64();
    spPc = s.int64();
    audioCycles = s.int64();
  }
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
          ((e[1] & e[2].mask1) != 0 || addr.mask8 == e[0].mask8)) {
        return i;
      }
    }
    return 0x80000000;
  }

  int physical(int address, {bool write = false}) {
    final a = address.mask32;
    if (a >= 0x80000000 && a < 0xc0000000) return a & 0x1fffffff;
    // the other segments are mapped by the TLB
    for (final e in tlb) {
      final mask = e[3] | 0x1fff;
      if ((a & ~mask) != (e[0] & ~mask)) continue;
      final page = (mask + 1) ~/ 2;
      final lo = (a & page) != 0 ? e[2] : e[1];
      if (!lo.bit1) throw N64AddressFault(a, write);
      if (write && !lo.bit2) throw N64AddressFault(a, write, modified: true);
      return lo.shr6.shl12 & ~(page - 1) | a & (page - 1);
    }
    throw N64AddressFault(a, write, refill: true);
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
  int registerIndex(int a) => a.mask16 ~/ 4;
  int read8(int address) {
    final a = physical(address);
    if (a < ram.length) return ram[a];
    if (a >= 0x04000000 && a < 0x04002000) return sp[a - 0x04000000];
    if (a >= 0x1fc007c0 && a < 0x1fc00800) return pif[a - 0x1fc007c0];
    if (a >= 0x10000000 && a - 0x10000000 < rom.length) {
      return rom[a - 0x10000000];
    }
    if (a >= 0x08000000 && a - 0x08000000 < cartSram.length) {
      return _sramRead(a - 0x08000000);
    }
    // 64DD registers / IPL rom: not connected (games probe for the drive).
    // the open PI bus returns the low 16 bits of each halfword's address
    if (a >= 0x05000000 && a < 0x08000000) {
      final half = a & 0xfffe;
      return a.isEven ? half.shr8 : half.mask8;
    }
    // RDRAM address space beyond the installed memory (games probe its size)
    if (a >= ram.length && a < 0x03f00000) return 0;
    if (a & ~3 == 0x04080000) return spPc.shr((3 - a.mask2) * 8).mask8;
    final regs = registers(a), index = registerIndex(a);
    if (regs != null && index < regs.length) {
      var value = regs[index];
      if (regs == vi && index == 4) value = scanline * 2;
      // PI_STATUS bit 3: the PI interrupt is pending
      if (regs == pi && index == 4) value = (mi[2] & 16) != 0 ? 8 : 0;
      if (regs == spRegs && index == 7) {
        value = spRegs[7];
        spRegs[7] = 1;
      }
      return value.shr((3 - a.mask2) * 8).mask8;
    }
    throw UnsupportedError('N64 bus read 0x${a.hex}');
  }

  // Instruction fetches overwhelmingly use direct-mapped RDRAM. Keep the
  // mapped and device paths in read() so TLB faults and MMIO stay unchanged.
  @pragma('vm:prefer-inline')
  int fetch(int address) {
    final a = address.mask32;
    if (a >= 0x80000000 && a < 0xc0000000) {
      final physicalAddress = a & 0x1fffffff;
      if (physicalAddress + 4 <= ram.length) {
        return ramData.getUint32(physicalAddress);
      }
    }
    return read(address, 4);
  }

  int read(int address, int size) {
    final a = physical(address);
    if (a + size <= ram.length) {
      if (size == 4) return ramData.getUint32(a);
      if (size == 2) return ramData.getUint16(a);
      if (size == 1) return ram[a];
    }
    if (size == 4 && a == 0x04080000) return spPc;
    if (size == 4 && a.mask2 == 0 && a >= 0x04040000) {
      final regs = registers(a), index = registerIndex(a);
      if (regs != null && index < regs.length) {
        if (regs == vi && index == 4) return scanline * 2;
        if (regs == pi && index == 4) return (mi[2] & 16) != 0 ? 8 : 0;
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
      v = v.shl8 | read8(address + i);
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
    if (a >= 0x08000000 && a - 0x08000000 < cartSram.length) {
      _sramWrite(a - 0x08000000, value);
      return;
    }
    if (a >= 0x05000000 && a < 0x08000000) return; // 64DD: not connected
    if (a >= ram.length && a < 0x03f00000) return; // beyond installed RDRAM
    final regs = registers(a);
    if (regs != null) {
      final base = address & ~3, shift = (3 - a.mask2) * 8;
      write(base, read(base, 4) & ~(255 << shift) | value.mask8.shl(shift), 4);
      return;
    }
    throw UnsupportedError('N64 bus byte write 0x${a.hex}');
  }

  void write(int address, int value, int size) {
    final a = physical(address, write: true);
    if (a + size <= ram.length) {
      ramWrite(a, value, size);
      return;
    }
    if (a >= 0x04000000 && a + size <= 0x04002000) {
      for (var i = 0; i < size; i++) {
        sp[a - 0x04000000 + i] = value.shr((size - i - 1) * 8);
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
            mi[0] = value.mask7;
            if (value.bit11) mi[2] &= ~32;
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
          if (value.bit1) mi[2] &= ~16;
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
          if (value.bit0) status &= ~1;
          if (value.bit1) status |= 1;
          if (value.bit2) status &= ~2;
          if (value.bit3) mi[2] &= ~1;
          if (value.bit4) mi[2] |= 1;
          for (var i = 0; i < 10; i++) {
            final bit = i < 2 ? 5 + i : 7 + i - 2;
            if ((value & (1 << (5 + i * 2))) != 0) status &= ~(1 << bit);
            if ((value & (2 << (5 + i * 2))) != 0) status |= 1 << bit;
          }
          spRegs[4] = status;
          if (!status.bit0 && onTask != null) {
            onTask!();
            spRegs[4] |= 0x203; // HALT, BROKE, SIG2: task complete.
            if (spRegs[4].bit6) interrupt(1);
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
        // the SP DMA starts from the written addresses, while the registers
        // read the current addresses, which only a DMA changes
        if (regs == spRegs && index < 2) {
          _spNext[index] = value;
          return;
        }
        regs[index] = value;
        if (regs == spRegs && (index == 2 || index == 3)) {
          _spDma(value, index == 2);
        }
        if (regs == pi) {
          // bit 0 of the addresses is fixed to 0, the lengths read as 0x7f
          if (index == 0) pi[0] = value & 0xfffffe;
          if (index == 1) pi[1] = value & 0xfffffffe;
          if (index == 2 || index == 3) {
            _piDma(value, index == 3);
            pi[2] = pi[3] = 0x7f;
          }
        }
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
      write8(address + i, value.shr((size - i - 1) * 8));
    }
  }

  void _spDma(int value, bool intoSp) {
    final length = (value.mask12 | 7) + 1, count = value.shr12.mask8 + 1;
    // RAM is accessed in 8 bytes, so the skip ignores its low 3 bits
    final skip = value.shr20.mask12 & ~7;
    var mem = _spNext[0] & 0x1ff8, dram = _spNext[1] & 0x7ffff8;
    final bank = mem & 0x1000;
    for (var row = 0; row < count; row++) {
      for (var i = 0; i < length; i++) {
        final target = bank | (mem + i).mask12;
        if (dram + i >= ram.length) throw StateError('SP DMA outside RDRAM');
        if (intoSp) {
          sp[target] = ram[dram + i];
        } else {
          ram[dram + i] = sp[target];
        }
      }
      mem = bank | (mem + length).mask12;
      dram += length + skip;
    }
    spRegs[0] = mem;
    spRegs[1] = dram - skip;
    // the length counts down past 0 and the count reaches 0
    spRegs[2] = spRegs[3] = skip.shl20 | 0xff8;
  }

  void _piDma(int value, bool intoRam) {
    final length = value.mask24 + 1, dram = pi[0] & 0x7ffffe;
    final cart = pi[1] & 0x1ffffffe;
    if (dram + length > ram.length) throw StateError('PI DMA outside RDRAM');
    if (cart >= 0x10000000 &&
        intoRam &&
        cart - 0x10000000 + length <= rom.length) {
      _piRomDma(dram, cart, length);
      interrupt(16);
      return;
    } else if (cart >= 0x08000000 &&
        cart - 0x08000000 + length <= cartSram.length) {
      // cartridge SRAM (32KiB, domain 2)
      final offset = cart - 0x08000000;
      for (var i = 0; i < length; i++) {
        if (intoRam) {
          ram[dram + i] = _sramRead(offset + i);
        } else {
          _sramWrite(offset + i, ram[dram + i]);
        }
      }
    } else if (cart >= 0x05000000 && cart < 0x10000000) {
      // 64DD / unconnected cartridge domains read as zero
      if (intoRam) ram.fillRange(dram, dram + length, 0);
    } else {
      throw UnsupportedError('PI DMA cartridge address 0x${cart.hex}');
    }
    pi[0] = dram + length;
    pi[1] = cart + length;
    pi[4] = 0;
    interrupt(16);
  }

  // ROM to RAM in blocks of up to 128 bytes, which do not cross a 2KiB RAM
  // page. The first block counts its length from the 8-byte aligned RAM
  // address, so a misaligned destination loses as many bytes at its end, and
  // the RAM address is rounded up to 8 bytes after it. The PI bus reads
  // halfwords, so the later blocks of odd length write one more byte.
  void _piRomDma(int dram, int cart, int length) {
    void copy(int to, int from, int n) {
      final end = min(n, rom.length - from);
      // setRange is slow for wasm_allocated arrays.
      if (end > 0) ram.setBytes(to, rom, from, end);
    }

    var rom0 = cart - 0x10000000;
    final misalign = dram & 7;
    final fill = min(length, min(128 - misalign, 0x800 - dram.mask11));
    if (fill > misalign) copy(dram, rom0, fill - misalign);
    rom0 += fill;
    var rest = length - fill;
    var to = (dram - misalign + fill + 7) & ~7;
    var odd = fill.isOdd;

    while (rest > 0) {
      final block = min(rest, min(128, 0x800 - to.mask11));
      final n = min((block + 1) & ~1, ram.length - to);
      copy(to, rom0, n);
      to += block.isOdd ? block + 1 : block;
      rom0 += block;
      rest -= block;
      odd = block.isOdd;
    }

    pi[0] = to & 0xfffffe;
    pi[1] = (0x10000000 + rom0 + (odd ? 1 : 0)) & 0xfffffffe;
    pi[4] = 0;
  }

  void _audio(int length) {
    final start = ai[0] & 0x7ffff8, bytes = length & 0x3fff8;
    if (start + bytes > ram.length) throw StateError('AI DMA outside RDRAM');
    final rate = (48681812 ~/ (ai[4] + 1)).clamp(8000, 96000);
    final samples = Float32List(bytes ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = ramRead(start + i * 2, 2).rel16 / 32768;
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
      final rx = pif[pos + 1].mask6, send = tx.mask6;
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
            'Start': 0x1000,
            'D-up': 0x800,
            'D-down': 0x400,
            'D-left': 0x200,
            'D-right': 0x100,
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
          pif[response] = bits.shr8;
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
    // the entries point to an unmapped segment, so that no address matches
    // them until software writes the TLB
    for (var i = 0; i < tlb.length; i++) {
      tlb[i].fillRange(0, 4, 0);
      tlb[i][0] = 0x80000000 + i * 0x2000;
    }
    for (final keys in held) {
      keys.clear();
    }
    scanline = 0;
    spPc = 0;
    _spNext.fillRange(0, 2, 0);
    audioCycles = 0;
    mi[1] = 0x02020102;
    spRegs[4] = 1;
    pi[2] = pi[3] = 0x7f;
  }

  /// VI raw framebuffer scanout, without filtering or interlacing.
  ImageBuffer image() {
    final mode = vi[0].mask2;
    final stride = vi[2].mask12;
    final hStart = vi[9].shr16.mask10;
    final hEnd = vi[9].mask10;
    final vStart = vi[10].shr16.mask10;
    final vEnd = vi[10].mask10;
    final width = (hEnd - hStart) * vi[12].mask12 ~/ 1024;
    final height = (vEnd - vStart) * vi[13].mask12 ~/ 2048;
    if (mode < 2 ||
        stride == 0 ||
        width <= 0 ||
        height <= 0 ||
        width > 640 ||
        height > 576) {
      return ImageBuffer(320, 240, Uint32List(320 * 240));
    }
    final output = Uint32List(width * height);
    final origin = vi[1].mask24;
    final size = mode == 2 ? 2 : 4;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final source = origin + (y * stride + x) * size;
        if (x >= stride || source + size > ram.length) continue;
        var abgr = 0xff000000;
        if (size == 2) {
          final color = ram[source].shl8 | ram[source + 1];
          for (var c = 0; c < 3; c++) {
            final v = color.shr(11 - c * 5).mask5;
            abgr |= (v.shl3 | v.shr2) << (c * 8);
          }
        } else {
          abgr |= ram[source] | ram[source + 1] << 8 | ram[source + 2] << 16;
        }
        output[y * width + x] = abgr;
      }
    }
    return ImageBuffer(width, height, output);
  }
}

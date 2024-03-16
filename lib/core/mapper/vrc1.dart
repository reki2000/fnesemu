// Project imports:
import 'dart:typed_data';

import '../../util.dart';
import 'mapper.dart';
import 'mirror.dart';

// https://www.nesdev.org/wiki/MMC3
class MapperVrc1 extends Mapper {
  // ppu 2 x 4k banks (0000-0fff, 1000-1fff)
  final List<int> _chrBank = [0, 1];

  // high bit (bit4) for chr bank. 0:0000-0fff, 1:1000-1fff
  int _chrBit0 = 0;
  int _chrBit1 = 0;

  // cpu 4 x 8k banks (8000-9fff, a000-bfff, c000-dfff, e000-ffff)
  final List<int> _prgBank = [0, 1, 2, 3];

  @override
  void setRom(List<Uint8List> chrRom8k, List<Uint8List> prgRom16k,
      Uint8List sramLoaded) {
    loadRom(chrRom8k, 4, prgRom16k, 8);
  }

  @override
  void init() {
    _prgBank[3] = prgRoms.length - 1;
  }

  @override
  void write(int addr, int data) {
    final reg = addr & 0xf000;

    switch (reg) {
      case 0x8000:
        final bank = (data & 0x0f);
        _prgBank[0] = bank;
        break;
      case 0xa000:
        final bank = (data & 0x0f);
        _prgBank[1] = bank;
        break;
      case 0xc000:
        final bank = (data & 0x0f);
        _prgBank[2] = bank;
        break;

      case 0x9000:
        mirror(bit0(data) ? Mirror.horizontal : Mirror.vertical);
        _chrBit0 = bit1(data) ? 0x10 : 0;
        _chrBit1 = bit2(data) ? 0x10 : 0;
        _chrBank[0] = (_chrBank[0] & 0x0f) | _chrBit0;
        _chrBank[1] = (_chrBank[1] & 0x0f) | _chrBit1;
        break;

      case 0xe000:
        final bank = (data & 0x0f);
        _chrBank[0] = bank | _chrBit0;
        break;

      case 0xf000:
        final bank = (data & 0x0f);
        _chrBank[1] = bank | _chrBit1;
        break;
    }
  }

  @override
  int read(int addr) {
    final bank = (addr >> 13) & 0x03;
    final offset = addr & 0x1fff;

    return prgRoms[_prgBank[bank]][offset];
  }

  @override
  int readVram(int addr) {
    final bank = addr >> 12;
    final offset = addr & 0x0fff;

    return chrRoms[_chrBank[bank]][offset];
  }

  @override
  String dump() {
    final chrBanks =
        range(0, 2).map((i) => hex8(_chrBank[i])).toList().join(" ");

    final prgBanks =
        range(0, 4).map((i) => hex8(_prgBank[i])).toList().join(" ");

    return "rom: "
        "chr: $chrBanks prg: $prgBanks "
        "\n";
  }
}

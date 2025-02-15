// Dart imports:

import '../../../util/util.dart';
import 'mapper.dart';

// https://www.nesdev.org/wiki/INES_Mapper_206
class MapperNamco118 extends Mapper {
  // extension point for mapper088
  int chrRomA16 = 0x00;

  // bank register
  int _r = 0;

  // ppu 2 x 2k banks + 4 x 1k banks (0000-0fff, 1000-1fff)
  final _chrBanks = [0, 0, 0, 0, 0, 0, 0, 0];

  // cpu 4 x 8k banks (8000-9fff, a000-bfff, c000-dfff, e000-ffff)
  final _prgBanks = [0, 0, 0, 0];

  @override
  int get chrRomSizeK => 1;
  @override
  int get prgRomSizeK => 8;

  @override
  void init() {
    _prgBanks[2] = prgRoms.length - 2;
    _prgBanks[3] = prgRoms.length - 1;
  }

  @override
  void write(int addr, int data) {
    final reg = addr & 0xe000;
    final isOdd = bit0(addr);

    switch (reg) {
      case 0x8000:
        if (isOdd) {
          switch (_r) {
            case 0:
              final bank = data & 0x3e;
              _chrBanks[0] = bank;
              _chrBanks[1] = bank + 1;
              break;
            case 1:
              final bank = data & 0x3e;
              _chrBanks[2] = bank;
              _chrBanks[3] = bank + 1;
              break;
            case 2:
            case 3:
            case 4:
            case 5:
              final bank = data & 0x3f | chrRomA16;
              _chrBanks[_r + 2] = bank;
              break;
            case 6:
              _prgBanks[0] = data & 0x0f;
              break;
            case 7:
              _prgBanks[1] = data & 0x0f;
              break;
          }
        } else {
          _r = data & 0x07;
        }
        break;
    }
  }

  @override
  int read(int addr) {
    final bank = (addr >> 13) & 0x03; // 0-3
    final offset = addr & 0x1fff;

    return prgRoms[_prgBanks[bank]][offset];
  }

  @override
  int readVram(int addr) {
    final bank = (addr >> 10) & 0x07;
    final offset = addr & 0x03ff;

    return chrRoms[_chrBanks[bank]][offset];
  }

  @override
  void writeVram(int addr, int data) {
    final bank = (addr >> 10) & 0x07;
    final offset = addr & 0x03ff;

    chrRoms[_chrBanks[bank]][offset] = data;
  }

  @override
  String dump() {
    final chrBanks =
        range(0, 8).map((i) => hex8(_chrBanks[i])).toList().join(" ");

    final prgBanks =
        range(0, 4).map((i) => hex8(_prgBanks[i])).toList().join(" ");

    return "rom: "
        "chr: $chrBanks prg: $prgBanks "
        "\n";
  }
}

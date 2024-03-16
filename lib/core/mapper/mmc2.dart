// Dart imports:
import 'dart:typed_data';

// Project imports:
import '../../util.dart';
import 'mapper.dart';
import 'mirror.dart';

// https://www.nesdev.org/wiki/NROM
class MapperMMC2 extends Mapper {
  final _ram = Uint8List(0x2000);

  final _prgBanks = [0, 0, 0, 0];
  final _chrBanks = [0, 0, 0, 0]; // 0,1: 0xFD  2,3: 0xFE
  final _latch = [0, 0]; // latch = fd: 0,   fe: 2

  @override
  void setRom(List<Uint8List> chrRom8k, List<Uint8List> prgRom16k,
      Uint8List sramLoaded) {
    loadRom(chrRom8k, 4, prgRom16k, 8);
  }

  @override
  void init() {
    _prgBanks[1] = prgRoms.length - 3;
    _prgBanks[2] = prgRoms.length - 2;
    _prgBanks[3] = prgRoms.length - 1;
  }

  @override
  void write(int addr, int data) {
    final bank = addr & 0xf000;
    switch (bank) {
      case 0x6000:
      case 0x7000:
        _ram[addr - 0x6000] = data;
        break;

      case 0xa000:
        _prgBanks[0] = data & 0x0f;
        break;

      case 0xb000:
        _chrBanks[0] = data & 0x1f;
        break;
      case 0xc000:
        _chrBanks[2] = data & 0x1f;
        break;

      case 0xd000:
        _chrBanks[1] = data & 0x1f;
        break;
      case 0xe000:
        _chrBanks[3] = data & 0x1f;
        break;

      case 0xf000:
        mirror(bit0(data) ? Mirror.horizontal : Mirror.vertical);
        break;
    }
  }

  @override
  int read(int addr) {
    final offset = addr & 0x1fff;

    if (addr & 0xe000 == 0x6000) {
      return _ram[offset];
    }

    final bank = (addr - 0x8000) >> 13; // 0-3
    return prgRoms[_prgBanks[bank]][offset];
  }

  @override
  int readVram(int addr) {
    if (addr == 0x0FD8) {
      _latch[0] = 0;
    } else if (addr == 0x0fe8) {
      _latch[0] = 2;
    } else if (addr & 0x1ff8 == 0x1fd8) {
      _latch[1] = 0;
    } else if (addr & 0x1ff8 == 0x1fe8) {
      _latch[1] = 2;
    }

    final bank = (addr >> 12) & 1;

    return chrRoms[_chrBanks[bank + _latch[bank]]][addr & 0x0fff];
  }

  @override
  String dump() {
    final chrBanks =
        range(0, 4).map((i) => hex8(_chrBanks[i])).toList().join(" ");
    final prgBanks =
        range(0, 4).map((i) => hex8(_prgBanks[i])).toList().join(" ");

    return "rom: "
        "chr: $chrBanks prg: $prgBanks "
        "\n";
  }
}

import 'package:fnesemu/util/int.dart';
// Dart imports:
import 'dart:typed_data';

/// per-BG register group (BG1-4 share the same register shapes).
class BgRegs {
  int tilemapAddr = 0; // word address of the 32x32-tile tilemap base
  bool wideX = false; // tilemap horizontally doubled (64 tiles wide)
  bool wideY = false; // tilemap vertically doubled (64 tiles tall)
  int charBase = 0; // word address of the character (tile graphics) data
  bool bigChar = false; // 16x16 tiles instead of 8x8 (BGMODE bit)
  int hofs = 0; // 10-bit horizontal scroll
  int vofs = 0; // 10-bit vertical scroll
}

/// SNES PPU: VRAM/CGRAM/OAM plus the $2100-$213F register file.
///
/// milestone 3 scope: BG modes 0, 1 and 3 render (the common 2bpp/4bpp/8bpp
/// tile cases) plus OBJ (sprites). Modes 2/4/5/6/7 (offset-per-tile, hi-res,
/// rotation) are not rendered yet - those scanlines fall back to backdrop
/// color, to be picked up alongside DMA/HDMA in the next milestone.
/// Windowing and color math registers are stored but not yet applied.
class Ppu {
  static const width = 256;
  static const height = 224;

  final buffer = Uint32List(width * height);

  // ------------------------------------------------------------- memory
  final vram = Uint8List(0x10000); // 64KB, byte-addressed (word reg * 2)
  final cgram = Uint8List(512); // 256 entries x 2 bytes, BGR555 in low 15 bits
  final oam = Uint8List(544); // 512-byte sprite table + 32-byte high table

  Ppu() {
    reset();
  }

  void reset() {
    buffer.fillRange(0, buffer.length, 0xff000000);
    brightness = 0;
    forcedBlank = true;
    bgMode = 0;
    bg3Priority = false;
    for (final bg in bgs) {
      bg.tilemapAddr = 0;
      bg.wideX = false;
      bg.wideY = false;
      bg.charBase = 0;
      bg.bigChar = false;
      bg.hofs = 0;
      bg.vofs = 0;
    }
    _bgOfsLatch = 0;
    vramAddr = 0;
    vramIncHigh = false;
    vramIncAmount = 1;
    _vramReadBuf = 0;
    cgramAddr = 0;
    cgramLatchHigh = false;
    _cgramLowByte = 0;
    oamAddr = 0;
    oamLatchHigh = false;
    _oamLowByte = 0;
    mainScreenEnable = 0;
    subScreenEnable = 0;
    objBase = 0;
    objGap = 0;
    objSizeSel = 0;
    rangeOver = false;
    timeOver = false;
  }

  // ------------------------------------------------------ $2100 INIDISP
  int brightness = 0; // 0-15
  bool forcedBlank = true;

  // ------------------------------------------------------ $2101 OBSEL
  int objSizeSel = 0; // 0-7, see _objSizeTable in ppu_render.dart
  int objGap = 0; // "name select", 0-3
  int objBase = 0; // "name base", 0-7 (word addr = base << 13)

  // ------------------------------------------------- $2102/2103 OAMADD
  int oamAddr = 0; // 9-bit word address into the 272-word OAM table
  bool oamLatchHigh = false;
  int _oamLowByte = 0;

  // ----------------------------------------------------------- $2104 OAMDATA
  // simplification: treats the whole 272-word table (low + high) uniformly
  // as low-byte-then-high-byte buffered writes. real hardware has a subtler
  // per-byte-parity rule specifically for the high table; not modeled here.
  void _oamWrite(int val) {
    if (!oamLatchHigh) {
      _oamLowByte = val;
      oamLatchHigh = true;
    } else {
      final byteAddr = (oamAddr * 2).mask16;
      if (byteAddr < oam.length) oam[byteAddr] = _oamLowByte;
      if (byteAddr + 1 < oam.length) oam[byteAddr + 1] = val;
      oamAddr = (oamAddr + 1) & 0x1ff;
      oamLatchHigh = false;
    }
  }

  int _oamRead() {
    final byteAddr = (oamAddr * 2).mask16;
    final v = byteAddr < oam.length ? oam[byteAddr] : 0;
    final hi = byteAddr + 1 < oam.length ? oam[byteAddr + 1] : 0;
    final result = oamLatchHigh ? hi : v;
    if (oamLatchHigh) oamAddr = (oamAddr + 1) & 0x1ff;
    oamLatchHigh = !oamLatchHigh;
    return result;
  }

  // ------------------------------------------------------- $2105 BGMODE
  int bgMode = 0;
  bool bg3Priority = false;

  // ------------------------------------------------- $2107-210A BGxSC
  // ------------------------------------------------- $210B/210C BGxNBA
  final bgs = List.generate(4, (_) => BgRegs());

  // --------------------------------------------- $210D-2114 BGxH/VOFS
  int _bgOfsLatch = 0; // shared "Prev" latch across all 8 scroll regs

  void _writeHofs(BgRegs bg, int val) {
    bg.hofs = (val << 8) | (_bgOfsLatch & ~7) | ((bg.hofs >> 8) & 7);
    bg.hofs &= 0x3ff;
    _bgOfsLatch = val;
  }

  void _writeVofs(BgRegs bg, int val) {
    bg.vofs = ((val << 8) | _bgOfsLatch) & 0x3ff;
    _bgOfsLatch = val;
  }

  // --------------------------------------------------- $2115-2117 VMAIN/ADD
  int vramAddr = 0; // word address, 0-0x7fff
  bool vramIncHigh = false; // increment after high-byte access
  int vramIncAmount = 1;
  int _vramReadBuf = 0;

  void _refreshVramReadBuf() {
    final a = (vramAddr & 0x7fff) * 2;
    _vramReadBuf = vram[a] | vram[a + 1].shl8;
  }

  // ----------------------------------------------------- $2118/2119 VMDATA
  void _vramWrite(int hi, int val) {
    final a = (vramAddr & 0x7fff) * 2;
    if (hi == 0) {
      vram[a] = val;
    } else {
      vram[a + 1] = val;
    }
    if (hi == (vramIncHigh ? 1 : 0)) {
      vramAddr = (vramAddr + vramIncAmount) & 0x7fff;
    }
  }

  // --------------------------------------------------- $2121/2122 CGRAM
  int cgramAddr = 0; // 0-255 (color index)
  bool cgramLatchHigh = false;
  int _cgramLowByte = 0;

  void _cgramWrite(int val) {
    final base = cgramAddr * 2;
    if (!cgramLatchHigh) {
      _cgramLowByte = val;
      cgramLatchHigh = true;
    } else {
      cgram[base] = _cgramLowByte;
      cgram[base + 1] = val & 0x7f;
      cgramAddr = (cgramAddr + 1) & 0xff;
      cgramLatchHigh = false;
    }
  }

  int _cgramRead() {
    final base = cgramAddr * 2;
    final result = !cgramLatchHigh ? cgram[base] : cgram[base + 1];
    if (cgramLatchHigh) cgramAddr = (cgramAddr + 1) & 0xff;
    cgramLatchHigh = !cgramLatchHigh;
    return result;
  }

  // ----------------------------------------------- $212C/212D TM/TS
  int mainScreenEnable = 0; // bit0-3 BG1-4, bit4 OBJ
  int subScreenEnable = 0;

  // -------------------------------------------------------- $213E/213F
  bool rangeOver = false; // >32 sprites on a scanline
  bool timeOver = false; // >34 tiles on a scanline

  // raw scratch for registers not yet modeled (windows, color math, mode7,
  // mosaic): stored so reads return the last-written value, but ignored by
  // the renderer for now.
  final _scratch = Uint8List(0x40);

  // -------------------------------------------------------------- ports
  /// handles a CPU write to a PPU register in $2100-$213F.
  void write(int addr, int val) {
    val &= 0xff;
    switch (addr) {
      case 0x2100: // INIDISP
        brightness = val & 0x0f;
        forcedBlank = val.bit7;
        break;
      case 0x2101: // OBSEL
        objSizeSel = val.shr5 & 0x07;
        objGap = val.shr3 & 0x03;
        objBase = val & 0x07;
        break;
      case 0x2102:
        oamAddr = (oamAddr & 0x100) | val;
        oamLatchHigh = false;
        break;
      case 0x2103:
        oamAddr = (oamAddr & 0xff) | ((val & 1).shl8);
        oamLatchHigh = false;
        break;
      case 0x2104:
        _oamWrite(val);
        break;
      case 0x2105: // BGMODE
        bgMode = val & 0x07;
        bg3Priority = val.bit3;
        bgs[0].bigChar = val.bit4;
        bgs[1].bigChar = val.bit5;
        bgs[2].bigChar = val.bit6;
        bgs[3].bigChar = val.bit7;
        break;
      case 0x2107:
      case 0x2108:
      case 0x2109:
      case 0x210a:
        {
          final bg = bgs[addr - 0x2107];
          bg.tilemapAddr = (val.shr2 & 0x3f).shl10;
          bg.wideX = val.bit0;
          bg.wideY = val.bit1;
        }
        break;
      case 0x210b: // BG12NBA
        bgs[0].charBase = (val & 0x0f).shl12;
        bgs[1].charBase = (val.shr4 & 0x0f).shl12;
        break;
      case 0x210c: // BG34NBA
        bgs[2].charBase = (val & 0x0f).shl12;
        bgs[3].charBase = (val.shr4 & 0x0f).shl12;
        break;
      case 0x210d:
        _writeHofs(bgs[0], val);
        break;
      case 0x210e:
        _writeVofs(bgs[0], val);
        break;
      case 0x210f:
        _writeHofs(bgs[1], val);
        break;
      case 0x2110:
        _writeVofs(bgs[1], val);
        break;
      case 0x2111:
        _writeHofs(bgs[2], val);
        break;
      case 0x2112:
        _writeVofs(bgs[2], val);
        break;
      case 0x2113:
        _writeHofs(bgs[3], val);
        break;
      case 0x2114:
        _writeVofs(bgs[3], val);
        break;
      case 0x2115: // VMAIN
        vramIncHigh = val.bit7;
        vramIncAmount = const [1, 32, 128, 128][val & 0x03];
        break;
      case 0x2116: // VMADDL
        vramAddr = (vramAddr & 0x7f00) | val;
        _refreshVramReadBuf();
        break;
      case 0x2117: // VMADDH
        vramAddr = (vramAddr & 0x00ff) | ((val & 0x7f).shl8);
        _refreshVramReadBuf();
        break;
      case 0x2118: // VMDATAL
        _vramWrite(0, val);
        break;
      case 0x2119: // VMDATAH
        _vramWrite(1, val);
        break;
      case 0x2121: // CGADD
        cgramAddr = val;
        cgramLatchHigh = false;
        break;
      case 0x2122: // CGDATA
        _cgramWrite(val);
        break;
      case 0x212c: // TM
        mainScreenEnable = val & 0x1f;
        break;
      case 0x212d: // TS
        subScreenEnable = val & 0x1f;
        break;
      default:
        // windows, color math, mosaic, mode7 matrix: stored, not applied yet
        if (addr >= 0x2100 && addr < 0x2140) {
          _scratch[(addr - 0x2100) & 0x3f] = val;
        }
    }
  }

  /// handles a CPU read from a PPU register in $2100-$213F.
  int read(int addr) {
    switch (addr) {
      case 0x2138: // OAMDATAREAD
        return _oamRead();
      case 0x2139: // VMDATALREAD
        {
          final v = _vramReadBuf & 0xff;
          if (!vramIncHigh) {
            vramAddr = (vramAddr + vramIncAmount) & 0x7fff;
            _refreshVramReadBuf();
          }
          return v;
        }
      case 0x213a: // VMDATAHREAD
        {
          final v = _vramReadBuf.shr8 & 0xff;
          if (vramIncHigh) {
            vramAddr = (vramAddr + vramIncAmount) & 0x7fff;
            _refreshVramReadBuf();
          }
          return v;
        }
      case 0x213b: // CGDATAREAD
        return _cgramRead();
      case 0x213e: // STAT77
        return (rangeOver ? 0x40 : 0) | (timeOver ? 0x80 : 0) | 0x01;
      case 0x213f: // STAT78: version=1, NTSC
        return 0x01;
      default:
        return 0; // open bus / write-only registers
    }
  }
}

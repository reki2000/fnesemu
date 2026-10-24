import '../../util/int.dart';
import 'bus.dart';
import 'ppu.dart';

/// GBC VRAM DMA (HDMA1-HDMA5 at FF51-FF55). Copies 16-byte blocks from ROM,
/// RAM or the cartridge into the VRAM bank selected by VBK.
class Hdma {
  final Bus _bus;

  int _source = 0; // FF51-FF52, lower 4 bits ignored
  int _dest = 0; // FF53-FF54, offset in the VRAM bank, lower 4 bits ignored
  int _blocksLeft = 0;
  bool _active = false; // HBlank transfer in progress

  Hdma(this._bus);

  void reset() {
    _source = 0;
    _dest = 0;
    _blocksLeft = 0;
    _active = false;
  }

  /// FF55: bit 7 is 0 while a transfer is active, the rest is blocks left - 1
  int read() => _active ? (_blocksLeft - 1).mask7 : 0xff;

  void write(int addr, int data) {
    switch (addr) {
      case 0xff51:
        _source = (data << 8) | (_source & 0xff);
      case 0xff52:
        _source = (_source & 0xff00) | (data & 0xf0);
      case 0xff53:
        _dest = ((data & 0x1f) << 8) | (_dest & 0xff);
      case 0xff54:
        _dest = (_dest & 0x1f00) | (data & 0xf0);
      case 0xff55:
        _start(data);
    }
  }

  void _start(int data) {
    // clearing bit 7 during an HBlank transfer stops it
    if (_active && !data.bit7) {
      _active = false;
      return;
    }

    _blocksLeft = data.mask7 + 1;
    if (data.bit7) {
      _active = true;
      return;
    }

    // general purpose transfer: the whole block is copied at once. The CPU
    // halt that hardware applies during the copy is not modeled.
    while (_blocksLeft > 0) {
      _copyBlock();
      _blocksLeft--;
    }
  }

  /// called by the PPU when a visible line enters HBlank
  void onHBlank() {
    if (!_active) {
      return;
    }
    _copyBlock();
    if (--_blocksLeft == 0) {
      _active = false;
    }
  }

  void _copyBlock() {
    final ppu = _bus.ppu;
    final bankBase = ppu.vramBank * Ppu.vramBankSize;
    for (int i = 0; i < 16; i++) {
      ppu.vram[bankBase + _dest + i] = _bus.read((_source + i).mask16);
    }
    _source = (_source + 16).mask16;
    _dest = (_dest + 16) & 0x1ff0; // the destination wraps within the bank
  }
}

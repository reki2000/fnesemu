import 'dart:typed_data';
import '../../../util/int.dart';

/// LC89510 decoder, circular sector buffer and host/DMA transfer interface.
class CdCdc {
  final ram = Uint8List(0x4000);
  final header = Uint8List(4);
  final void Function() interrupt;
  final void Function(int destination, int address, int value) dmaWrite;
  CdCdc(this.interrupt, this.dmaWrite);

  int register = 0, destination = 0, dmaAddress = 0;
  int _ifstat = 0xff, _ifctrl = 0, _ctrl0 = 0, _ctrl1 = 0;
  int _count = 0, _source = 0, _write = 0, _pointer = 0;
  bool _transfer = false, _ended = false;
  int _stat3 = 0x80;
  bool get dataReady => _transfer && (destination == 2 || destination == 3);
  bool get transferEnd => _ended;

  void reset() {
    register = destination = dmaAddress = 0;
    _ifstat = 0xff;
    _ifctrl = _ctrl0 = _ctrl1 = _count = _source = _write = _pointer = 0;
    _transfer = _ended = false;
    _stat3 = 0x80;
    _dmaBytes = _dmaCycles = 0;
    header.fillRange(0, 4, 0);
  }

  int readRegister() {
    final index = register;
    if (index != 0) register = (register + 1).mask4;
    switch (index) {
      case 0:
        return 0xff;
      case 1:
        return _ifstat;
      case 2:
        return _count.mask8;
      case 3:
        return _count.shr8.mask4;
      case 4 || 5 || 6 || 7:
        return header[index - 4];
      case 8:
        return _pointer.mask8;
      case 9:
        return _pointer.shr8;
      case 10:
        return _write.mask8;
      case 11:
        return _write.shr8;
      case 12:
        return _ctrl0 & 0x80;
      case 13:
        return 0;
      case 14:
        return _ctrl1 & 0x0c;
      case 15:
        _ifstat |= 0x20;
        final value = _stat3;
        _stat3 = 0x80;
        return value;
      default:
        return 0;
    }
  }

  void writeRegister(int data) {
    data &= 0xff;
    final index = register;
    if (index != 0) register = (register + 1).mask4;
    switch (index) {
      case 1:
        _ifctrl = data;
        if (!data.bit1) {
          _transfer = false;
          _ifstat |= 0x0a;
        }
      case 2:
        _count = (_count & 0xf00) | data;
      case 3:
        _count = _count.mask8 | data.mask4.shl8;
      case 4:
        _source = (_source & 0xff00) | data;
      case 5:
        _source = _source.mask8 | data.shl8;
      case 6:
        if (_ifctrl.bit1) {
          _transfer = true;
          _ended = false;
          _dmaBytes = _dmaCycles = 0;
          _ifstat &= ~0x0a;
        }
      case 7:
        _ifstat |= 0x40;
      case 8:
        _write = (_write & 0xff00) | data;
      case 9:
        _write = _write.mask8 | data.shl8;
      case 10:
        _ctrl0 = data;
        if (!data.bit7) _ifstat |= 0x20;
      case 11:
        _ctrl1 = data;
      case 12:
        _pointer = (_pointer & 0xff00) | data;
      case 13:
        _pointer = _pointer.mask8 | data.shl8;
      case 15:
        reset();
    }
  }

  void decode(Uint8List sector) {
    if (!_ctrl0.bit7 || sector.length < 2352) return;
    header.setRange(0, 4, sector, 12);
    _stat3 = 0;
    if (_ctrl0.bit2) {
      _pointer = (_pointer + 2352).mask14;
      _write = (_write + 2352).mask14;
      for (int i = 0; i < 2352; i++) {
        // Normal decode stores header + data, omitting the 12-byte sync.
        ram[(_pointer + i).mask14] = sector[(i + 12) % 2352];
      }
    }
    _ifstat &= ~0x20;
    if (_ifctrl.bit5) interrupt();
  }

  int _readByte() {
    final value = ram[_source.mask14];
    _source = (_source + 1).mask16;
    _count--;
    if (_count < 0) {
      _count = 0xffff;
      _transfer = false;
      _ended = true;
      _ifstat = (_ifstat | 0x0a) & ~0x40;
      if (_ifctrl.bit6) interrupt();
    }
    return value;
  }

  int readHost(int cpuDestination) {
    if (!dataReady || destination != cpuDestination) return 0xffff;
    final high = _readByte();
    final low = _transfer ? _readByte() : 0;
    return high.shl8 | low;
  }

  void tick(int cycles) {
    if (!_transfer || destination < 4 || destination == 6) return;
    // DMA consumes one word per eight sub-CPU clocks.
    _dmaCycles += cycles;
    int budget = _dmaCycles ~/ 8;
    _dmaCycles %= 8;
    while (_transfer && budget-- > 0) {
      final offset = (dmaAddress << (destination == 4 ? 2 : 3)) + _dmaBytes;
      final high = _readByte();
      dmaWrite(destination, offset, high);
      final low = _transfer ? _readByte() : 0;
      dmaWrite(destination, offset + 1, low);
      _dmaBytes += 2;
      if (_dmaBytes >= (destination == 4 ? 4 : 8)) {
        dmaAddress = (dmaAddress + 1).mask16;
        _dmaBytes = 0;
      }
    }
  }

  int _dmaBytes = 0, _dmaCycles = 0;
}

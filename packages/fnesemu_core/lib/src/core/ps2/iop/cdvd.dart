import 'dart:collection';

import '../../../cdrom_drive.dart';

/// The CDVD drive controller registers as seen by the IOP (0x1f402000..).
///
/// Only the handshake the BIOS polls is modelled: N command status, the S
/// command interface with a result FIFO (configuration and clock reads answer
/// with plausible data), and an empty tray. Register
/// meanings are from memory and unverified. Disc reads are not implemented.
class Cdvd {
  static const base = 0x1f402000, end = 0x1f402030;

  static const _nStatus = 0x1f402005, _error = 0x1f402006;
  static const _discType = 0x1f40200f;
  static const _sCommand = 0x1f402016, _sStatus = 0x1f402017;
  static const _sResult = 0x1f402018;

  static const noDisc = 0x00;
  static const _ready = 0x40;
  static const _sResultEmpty = 0x40;

  /// the inserted disc, or null. Sector reads are not implemented yet, so the
  /// tray still reports empty.
  CdromDrive? drive;

  /// the disc type byte; 0 reports an empty tray
  int discType = noDisc;

  final _results = ListQueue<int>();
  int _lastCommand = 0;
  int _tick = 0;

  static bool handles(int address) => address >= base && address < end;

  void reset() {
    _results.clear();
    _lastCommand = 0;
  }

  int read(int address) {
    switch (address) {
      case _nStatus:
        return _ready;
      case _error:
        return 0;
      case _discType:
        return discType;
      case _sStatus:
        return _results.isEmpty ? _sResultEmpty : 0;
      case _sResult:
        return _results.isEmpty ? 0 : _results.removeFirst();
      case _sCommand:
        return _lastCommand;
    }
    return 0;
  }

  void write(int address, int value) {
    if (address == _sCommand) {
      _lastCommand = value & 0xff;
      _results
        ..clear()
        ..add(0); // every S command answers with a zero status byte
      switch (_lastCommand) {
        case 0x41: // read configuration block: 15 more bytes
          _results.addAll(List.filled(15, 0));
        case 0x08: // read clock: second, minute, hour, pad, day, month, year
          final second = (_tick++ ~/ 3) % 60;
          _results.addAll([
            second ~/ 10 << 4 | second % 10,
            0x00,
            0x12,
            0x00,
            0x01,
            0x01,
            0x24
          ]);
      }
    }
  }
}

import 'dart:typed_data';

/// An 8MB memory card on SIO2.
///
/// The card holds 16384 pages of 512 data bytes and 16 spare (ECC) bytes,
/// erased in blocks of 16 pages. A command is 0x81, the command byte and
/// its parameters; the reply has one byte for every byte sent. Short
/// replies end with 0x2b and the terminator byte. The layouts follow the
/// ps2tek memory card page and the buffer checks of the open PS2 SDK card
/// drivers.
///
/// The MagicGate authentication (command 0xf0 and its subcommands) is
/// answered with acknowledgements and zero data. The card drivers only
/// check the replies of the mechacon, which accepts any data here.
class Ps2MemoryCard {
  static const pageSize = 512, spareSize = 16, pagesPerBlock = 16;
  static const pages = 16384;
  static const pageBytes = pageSize + spareSize;
  static const size = pages * pageBytes;

  /// card flags of the spec reply: ECC, bad block support
  static const _flags = 0x2b;

  /// the subcommands of 0xf0 that send 8 bytes to the card
  static const _authWrites = {0x06, 0x07, 0x0b};

  int Function(int address) read8;
  void Function(int address, int value) write8;

  int _terminator = 0x55;
  int _page = 0, _offset = 0;

  Ps2MemoryCard(this.read8, this.write8);

  /// a card on its own memory, erased (unformatted)
  factory Ps2MemoryCard.blank() {
    final data = blankImage();
    return Ps2MemoryCard((a) => data[a], (a, v) => data[a] = v);
  }

  static Uint8List blankImage() => Uint8List(size)..fillRange(0, size, 0xff);

  void reset() {
    _terminator = 0x55;
    _page = _offset = 0;
  }

  /// The reply to the bytes [sent], [length] bytes long, or null when the
  /// card does not take the command.
  List<int>? transfer(List<int> sent, int length) {
    int at(int i) => i < sent.length ? sent[i] : 0;
    final reply = List<int>.filled(length, 0xff);
    void ack(int index) {
      if (index >= 0 && index + 1 < length) {
        reply[index] = 0x2b;
        reply[index + 1] = _terminator;
      }
    }

    final command = at(1);
    switch (command) {
      case 0x11: // probe
      case 0x12:
      case 0x81: // end of a read or write
      case 0xbf:
      case 0xf3: // reset the authentication
      case 0xf7: // select the authentication keys
        ack(length - 2);
      case 0x21: // set the erase, write or read page
      case 0x22:
      case 0x23:
        _page = (at(2) | at(3) << 8 | at(4) << 16 | at(5) << 24) % pages;
        _offset = 0;
        ack(length - 2);
      case 0x26: // spec: page size, block size, page count, checksum
        final spec = [
          pageSize & 0xff,
          pageSize >> 8,
          pagesPerBlock,
          0,
          pages & 0xff,
          (pages >> 8) & 0xff,
          0,
          0,
        ];
        reply[2] = _flags;
        for (var i = 0; i < spec.length && 3 + i < length; i++) {
          reply[3 + i] = spec[i];
        }
        if (length > 12) {
          reply[11] = spec.fold(0, (a, b) => a ^ b);
          reply[12] = _terminator;
        }
      case 0x27: // set the terminator
        _terminator = at(2);
        ack(length - 2);
      case 0x28: // get the terminator
        if (length >= 5) {
          reply[2] = 0x2b;
          reply[3] = _terminator;
          reply[4] = 0x55;
        }
      case 0x42: // write data
        final n = at(2);
        for (var i = 0; i < n && 3 + i < length; i++) {
          _write(at(3 + i));
        }
        ack(2);
        reply[length - 1] = _terminator;
      case 0x43: // read data, then a checksum
        final n = at(2);
        var sum = 0;
        for (var i = 0; i < n && 4 + i < length; i++) {
          final v = _read();
          reply[4 + i] = v;
          sum ^= v;
        }
        ack(2);
        if (4 + n < length) reply[4 + n] = sum;
        reply[length - 1] = _terminator;
      case 0x82: // erase the block of the erase page
        final first = _page - _page % pagesPerBlock;
        for (var a = first * pageBytes;
            a < (first + pagesPerBlock) * pageBytes;
            a++) {
          write8(a, 0xff);
        }
        ack(length - 2);
      case 0xf0: // authentication
        if (length >= 14) {
          if (_authWrites.contains(at(2))) {
            ack(12);
          } else {
            reply[3] = 0x2b;
            for (var i = 4; i < 12; i++) {
              reply[i] = 0;
            }
            reply[12] = 0;
            reply[13] = _terminator;
          }
        } else {
          ack(length - 2);
        }
      default:
        return null;
    }
    return reply;
  }

  // reads and writes go through the page and its spare area in order
  int _read() {
    final v = read8(_page * pageBytes + _offset);
    _advance();
    return v;
  }

  void _write(int value) {
    write8(_page * pageBytes + _offset, value);
    _advance();
  }

  void _advance() {
    if (++_offset == pageBytes) {
      _offset = 0;
      _page = (_page + 1) % pages;
    }
  }
}

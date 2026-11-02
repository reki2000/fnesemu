import 'dart:collection';
import 'dart:typed_data';

import '../dmac.dart';
import '../quad_fifo.dart';
import '../state.dart';
import 'idct.dart';
import 'vlc.dart';

/// The bitstream ran out before a command step finished.
class _Underflow implements Exception {
  const _Underflow();
}

/// The image processing unit: an MPEG-1/MPEG-2 decoder with registers at
/// 0x10002000 and FIFOs at 0x10007000.
///
/// The registers and the command options follow the ps2tek IPU pages. The
/// decoding follows ISO/IEC 13818-2 (MPEG-2) and ISO/IEC 11172-2 (MPEG-1).
/// The result layouts follow how the open PS2 SDK MPEG library uses them:
/// VDEC returns the code length in bits 16.. and the value in bits 0..15,
/// BDEC writes the luminance as a 16x16 raster of 16-bit values followed by
/// the two 8x8 chrominance blocks, and a CSC macroblock holds 256 luminance
/// bytes and 64 bytes of each chrominance.
///
/// A command runs as soon as its data is in the input FIFO, which pulls from
/// DMA channel 4 as needed; a command that runs out of data waits and is
/// retried when more arrives. The output FIFO feeds DMA channel 3.
///
/// Unverified: the colour conversion uses the ITU-R BT.601 studio range,
/// the alpha thresholds compare each colour channel, the RGB16 dither
/// matrix, the order of the quantiser matrices (zigzag, as in the
/// bitstream) and the VQ colour table (little-endian halfwords).
class Ipu {
  static bool handlesRegister(int address) =>
      address >= 0x10002000 && address < 0x10002040;
  static bool handlesFifo(int address) =>
      address >= 0x10007000 && address < 0x10007020;

  /// raised when a command finishes
  void Function()? onInterrupt;

  /// asks DMA to fill the input FIFO and to drain the output FIFO
  void Function()? onDma;

  late final DmaEndpoint toIpu = _IpuInput(this);
  late final DmaEndpoint fromIpu = _IpuOutput(this);

  // ---- control state ----

  int _idp = 0, _cbp = 0;
  bool _alternateScan = false, _intraVlc1 = false, _nonlinearQ = false;
  bool _mpeg1 = false, _ecd = false, _scd = false;
  int _pictureType = 0;

  bool _busy = false, _running = false;
  int _command = 0, _option = 0, _result = 0;

  /// no command ran since the FIFO was cleared: IPU_CMD shows the stream
  bool _idle = true;

  // ---- input: whole quadwords; [_bit] counts from the buffer start ----

  Uint8List _in = Uint8List(4096);
  int _inLen = 0, _bit = 0;

  /// where the running step started; the step returns there when the data
  /// runs out, so the buffer keeps the data from there
  int _stepBit = 0;

  /// quadwords that the running command needs in the buffer
  int _wantQuads = 0;

  // ---- output ----

  final _out = ListQueue<int>(); // 64-bit halves, low first
  final _pending = <int>[];
  final _inFifo = QuadFifo();
  int _readHigh = 0;

  // ---- decoder state ----

  final _dc = Int32List(3);
  final _intraQ = Uint8List(64), _nonIntraQ = Uint8List(64);
  final _vq = Uint16List(16);
  int _th0 = 0, _th1 = 0;
  final _block = Int32List(64);
  final _mb = Int16List(384);
  final _idct = Idct();

  // macroblocks left in a CSC or PACK command, and the quantiser scale code
  // of an IDEC command
  int _left = 0, _qsc = 0;

  void saveState(StateWriter w) {
    w.section('ipu');
    w.ints([
      _idp, _cbp, _pictureType, _command, _option, _result, _inLen, _bit, //
      _stepBit, _wantQuads, _readHigh, _th0, _th1, _left, _qsc,
    ]);
    for (final b in [
      _alternateScan, _intraVlc1, _nonlinearQ, _mpeg1, _ecd, //
      _scd, _busy, _running, _idle, _skipPending
    ]) {
      w.boolean(b);
    }
    w.bytes(_in.sublist(0, _inLen));
    w.ints(_out.toList());
    w.ints(_pending);
    _inFifo.saveState(w);
    for (final list in [_dc, _intraQ, _nonIntraQ, _vq, _block, _mb]) {
      w.typed(list);
    }
  }

  void loadState(StateReader s) {
    s.section('ipu');
    final v = s.fields(15, 'ipu');
    _idp = v[0];
    _cbp = v[1];
    _pictureType = v[2];
    _command = v[3];
    _option = v[4];
    _result = v[5];
    _inLen = v[6];
    _bit = v[7];
    _stepBit = v[8];
    _wantQuads = v[9];
    _readHigh = v[10];
    _th0 = v[11];
    _th1 = v[12];
    _left = v[13];
    _qsc = v[14];
    _alternateScan = s.boolean();
    _intraVlc1 = s.boolean();
    _nonlinearQ = s.boolean();
    _mpeg1 = s.boolean();
    _ecd = s.boolean();
    _scd = s.boolean();
    _busy = s.boolean();
    _running = s.boolean();
    _idle = s.boolean();
    _skipPending = s.boolean();
    final input = s.bytes();
    _in = Uint8List(input.length > 4096 ? input.length : 4096)
      ..setAll(0, input);
    _out
      ..clear()
      ..addAll(s.ints());
    _pending
      ..clear()
      ..addAll(s.ints());
    _inFifo.loadState(s);
    for (final list in [_dc, _intraQ, _nonIntraQ, _vq, _block, _mb]) {
      s.typed(list);
    }
  }

  void reset() {
    _clearInput();
    _out.clear();
    _pending.clear();
    _busy = _ecd = _scd = false;
    _cbp = _result = 0;
    _idle = true;
  }

  void _clearInput() {
    _inLen = 0;
    _bit = 0;
    _wantQuads = 0;
  }

  // ---- registers ----

  int read(int address, int size) {
    service();
    switch (address & 0xff) {
      case 0x00:
        final busy = _busy ? 1 << 63 : 0;
        if (_idle && !_busy && _available >= 32) return _peekRaw(32);
        return size == 8 ? _result | busy : _result;
      case 0x04:
        return _busy ? 0x80000000 : 0;
      case 0x10:
        return _ctrl;
      case 0x20:
        return (_bit & 0x7f) | _ifc << 8 | _fp << 16;
      case 0x30:
        _fill(32);
        final ready = _available >= 32;
        final top = _peekRaw(32);
        return size == 8 && !ready ? top | 1 << 63 : top;
      case 0x34:
        return _available >= 32 ? 0 : 0x80000000;
    }
    return 0;
  }

  void write(int address, int size, int value) {
    switch (address & 0xff) {
      case 0x00:
        _startCommand(value & 0xffffffff);
      case 0x10:
        if (value & 0x40000000 != 0) {
          // a reset during a command raises the interrupt (ps2tek)
          final wasBusy = _busy;
          reset();
          if (wasBusy) onInterrupt?.call();
        }
        _idp = (value >> 16) & 3;
        _alternateScan = value & (1 << 20) != 0;
        _intraVlc1 = value & (1 << 21) != 0;
        _nonlinearQ = value & (1 << 22) != 0;
        _mpeg1 = value & (1 << 23) != 0;
        _pictureType = (value >> 24) & 7;
    }
  }

  int get _ctrl =>
      _ifc |
      (_outQuads > 8 ? 8 : _outQuads) << 4 |
      _cbp << 8 |
      (_ecd ? 1 << 14 : 0) |
      (_scd ? 1 << 15 : 0) |
      _idp << 16 |
      (_alternateScan ? 1 << 20 : 0) |
      (_intraVlc1 ? 1 << 21 : 0) |
      (_nonlinearQ ? 1 << 22 : 0) |
      (_mpeg1 ? 1 << 23 : 0) |
      _pictureType << 24 |
      (_busy ? 1 << 31 : 0);

  int get _quads => (_inLen >> 4) - (_bit >> 7);
  int get _fp => _quads <= 0 ? 0 : (_quads > 2 ? 2 : _quads);
  int get _ifc {
    final n = _quads - _fp;
    return n <= 0 ? 0 : (n > 8 ? 8 : n);
  }

  int get _outQuads => _out.length >> 1;

  // ---- FIFOs ----

  /// the CPU reads the output FIFO at 0x10007000 and writes the input FIFO
  /// at 0x10007010
  int readFifo(int address, int size) {
    if (address & 8 != 0) return _readHigh;
    if (_out.isEmpty) {
      _readHigh = 0;
      return 0;
    }
    final low = _out.removeFirst();
    _readHigh = _out.removeFirst();
    return low;
  }

  void writeFifo(int address, int size, int value) {
    if (address < 0x10007010) return;
    if (_inFifo.write(address, size, value)) {
      _put(_inFifo.low, _inFifo.high);
      service();
    }
  }

  void _put(int low, int high) {
    if (_inLen + 16 > _in.length) {
      _compact();
      if (_inLen + 16 > _in.length) {
        _in = Uint8List(_in.length * 2)..setRange(0, _inLen, _in);
      }
    }
    final b = _in;
    for (var i = 0; i < 8; i++) {
      b[_inLen + i] = (low >> (8 * i)) & 0xff;
      b[_inLen + 8 + i] = (high >> (8 * i)) & 0xff;
    }
    _inLen += 16;
  }

  /// drops the consumed quadwords
  void _compact() {
    final from = _running && _stepBit < _bit ? _stepBit : _bit;
    final drop = (from >> 7) << 4;
    if (drop == 0 || drop > _inLen) return;
    _in.setRange(0, _inLen - drop, _in, drop);
    _inLen -= drop;
    _bit -= drop * 8;
    _stepBit -= drop * 8;
  }

  bool get _canPut => _quads < (_wantQuads > 10 ? _wantQuads : 10);

  // ---- bit reader ----

  int get _available => _inLen * 8 - _bit;

  /// asks DMA for data until [bits] bits are in the buffer
  void _fill(int bits) {
    if (_available >= bits) return;
    _wantQuads = ((_bit + bits + 127) >> 7) - (_bit >> 7);
    onDma?.call();
    _wantQuads = 0;
  }

  void _need(int bits) {
    _fill(bits);
    if (_available < bits) throw const _Underflow();
  }

  /// the next [n] (up to 32) bits; bits past the data read as 0
  int _peekRaw(int n) {
    final byte = _bit >> 3;
    var v = 0;
    for (var i = 0; i < 5; i++) {
      final at = byte + i;
      v = v << 8 | (at < _inLen ? _in[at] : 0);
    }
    return (v >> (40 - (_bit & 7) - n)) & ((1 << n) - 1);
  }

  int _peek(int n) {
    _need(n);
    return _peekRaw(n);
  }

  int _bits(int n) {
    if (n == 0) return 0;
    final v = _peek(n);
    _bit += n;
    return v;
  }

  void _skip(int n) {
    _need(n);
    _bit += n;
  }

  /// the entry of the next code of [table], or 0 when no code matches
  int _vlc(Vlc table) {
    _fill(table.bits);
    final entry = table.lookup(_peekRaw(table.bits));
    final length = Vlc.lengthOf(entry);
    if (length == 0) {
      if (_available < table.bits) throw const _Underflow();
      return 0;
    }
    _skip(length);
    return entry;
  }

  // ---- commands ----

  void _startCommand(int value) {
    _command = value >>> 28;
    _option = value & 0x0fffffff;
    _busy = true;
    _ecd = _scd = false;
    _idle = false;
    _left = _option & 0x7ff;
    _qsc = (_option >> 16) & 0x1f;
    if (_command == 1 || _command == 2) _skipPending = true;
    service();
  }

  // IDEC and BDEC skip FB bits before their first step
  bool _skipPending = false;

  /// runs the command as far as the data allows
  void service() {
    if (!_busy || _running) {
      if (!_busy && _outQuads > 0) onDma?.call();
      return;
    }
    _running = true;
    try {
      while (_busy) {
        _stepBit = _bit;
        final dc0 = _dc[0], dc1 = _dc[1], dc2 = _dc[2];
        final skip = _skipPending;
        try {
          final done = _step();
          _out.addAll(_pending);
          _pending.clear();
          if (done) {
            _busy = false;
            onInterrupt?.call();
          }
        } on _Underflow {
          _bit = _stepBit;
          _dc[0] = dc0;
          _dc[1] = dc1;
          _dc[2] = dc2;
          _skipPending = skip;
          _pending.clear();
          break;
        }
      }
    } finally {
      _running = false;
    }
    if (_outQuads > 0) onDma?.call();
  }

  /// One step of the command: a whole command, or one macroblock of IDEC,
  /// CSC and PACK. Returns true when the command is done.
  bool _step() {
    final fb = _option & 0x3f;
    switch (_command) {
      case 0: // BCLR
        _clearInput();
        _bit = _option & 0x7f;
        _idle = true;
        return true;
      case 1:
        return _idec();
      case 2:
        _bdec();
        return true;
      case 3: // VDEC
        _skip(fb);
        _vdec();
        return true;
      case 4: // FDEC
        _skip(fb);
        _result = _peek(32);
        return true;
      case 5: // SETIQ
        _skip(fb);
        final matrix = _option & (1 << 27) != 0 ? _nonIntraQ : _intraQ;
        for (var i = 0; i < 64; i++) {
          matrix[_zigzag[i]] = _bits(8);
        }
        return true;
      case 6: // SETVQ
        for (var i = 0; i < 16; i++) {
          final low = _bits(8);
          _vq[i] = low | _bits(8) << 8;
        }
        return true;
      case 7:
        return _csc();
      case 8:
        return _pack();
      case 9: // SETTH
        _th0 = _option & 0x1ff;
        _th1 = (_option >> 16) & 0x1ff;
        return true;
    }
    return true;
  }

  void _vdec() {
    final table = (_option >> 26) & 3;
    final vlc = switch (table) {
      0 => mbaiTable,
      1 => mbTypeTables[(_pictureType - 1).clamp(0, 3)],
      2 => motionCodeTable,
      _ => dmVectorTable,
    };
    final entry = _vlc(vlc);
    if (entry == 0) {
      _ecd = true;
      _result = 0;
      return;
    }
    _result = Vlc.lengthOf(entry) << 16 | (Vlc.aOf(entry) & 0xffff);
  }

  // ---- macroblocks ----

  static const _zigzag = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, //
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
  ];
  static const _alternate = [
    0, 8, 16, 24, 1, 9, 2, 10, 17, 25, 32, 40, 48, 56, 57, 49, //
    41, 33, 26, 18, 3, 11, 4, 12, 19, 27, 34, 42, 50, 58, 35, 43,
    51, 59, 20, 28, 5, 13, 6, 14, 21, 29, 36, 44, 52, 60, 37, 45,
    53, 61, 22, 30, 7, 15, 23, 31, 38, 46, 54, 62, 39, 47, 55, 63,
  ];
  static const _nonlinear = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 18, 20, 22, //
    24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 96, 104, 112,
  ];

  void _resetDc() => _dc.fillRange(0, 3, 1 << (7 + (_mpeg1 ? 0 : _idp)));

  /// BDEC: one macroblock as 16-bit values
  void _bdec() {
    if (_skipPending) {
      _skip(_option & 0x3f);
      _skipPending = false;
    }
    if (_option & (1 << 26) != 0) _resetDc();
    final intra = _option & (1 << 27) != 0;
    var cbp = 0x3f;
    if (!intra) {
      final entry = _vlc(cbpTable);
      if (entry == 0) {
        _ecd = true;
        return;
      }
      cbp = Vlc.aOf(entry);
    }
    _cbp = cbp;
    _decodeMacroblock(intra, cbp, _qsc, false);
    final mb = _mb;
    for (var i = 0; i < 384; i += 4) {
      _pending.add((mb[i] & 0xffff) |
          (mb[i + 1] & 0xffff) << 16 |
          (mb[i + 2] & 0xffff) << 32 |
          (mb[i + 3] & 0xffff) << 48);
    }
  }

  /// Decodes the coded blocks of a macroblock into [_mb]: the luminance as
  /// a 16x16 raster, then Cb and Cr. With [fieldDct] the luminance blocks
  /// hold the two fields and are interleaved into frame lines.
  void _decodeMacroblock(bool intra, int cbp, int qsc, bool fieldDct) {
    final mb = _mb;
    for (var b = 0; b < 6; b++) {
      final block = _block;
      if (cbp & (32 >> b) == 0) {
        block.fillRange(0, 64, 0);
      } else {
        _decodeBlock(b, intra, qsc);
        _idct.transform(block);
      }
      if (b < 4) {
        final x0 = (b & 1) * 8;
        for (var y = 0; y < 8; y++) {
          final row = fieldDct ? (b >> 1) + y * 2 : (b >> 1) * 8 + y;
          for (var x = 0; x < 8; x++) {
            mb[row * 16 + x0 + x] = block[y * 8 + x];
          }
        }
      } else {
        final base = b == 4 ? 256 : 320;
        for (var i = 0; i < 64; i++) {
          mb[base + i] = block[i];
        }
      }
    }
  }

  /// decodes and dequantises block [b] into [_block] (row-major)
  void _decodeBlock(int b, bool intra, int qsc) {
    final f = _block..fillRange(0, 64, 0);
    final scan = _alternateScan && !_mpeg1 ? _alternate : _zigzag;
    final matrix = intra ? _intraQ : _nonIntraQ;
    final qscale = _nonlinearQ && !_mpeg1 ? _nonlinear[qsc] : qsc * 2;
    var i = 0;
    var sum = 0;
    if (intra) {
      final c = b < 4 ? 0 : b - 3;
      final entry = _vlc(c == 0 ? dcSizeLuma : dcSizeChroma);
      if (entry == 0) {
        _ecd = true;
        return;
      }
      final size = Vlc.aOf(entry);
      var diff = 0;
      if (size > 0) {
        diff = _bits(size);
        if (diff < 1 << (size - 1)) diff -= (1 << size) - 1;
      }
      _dc[c] += diff;
      final dc = _dc[c] * (_mpeg1 ? 8 : 8 >> _idp);
      f[0] = dc;
      sum = dc;
      i = 1;
    }
    final table = intra && _intraVlc1 && !_mpeg1 ? dctTable1 : dctTable0;
    var first = !intra;
    while (true) {
      final entry = _vlc(first ? dctTable0First : table);
      first = false;
      if (entry == 0) {
        _ecd = true;
        break;
      }
      final b = Vlc.bOf(entry);
      if (b == dctEnd) break;
      int run, level;
      if (b == dctEscape) {
        run = _bits(6);
        if (_mpeg1) {
          level = _bits(8);
          if (level == 0) {
            level = _bits(8);
          } else if (level == 0x80) {
            level = _bits(8) - 256;
          } else if (level > 0x80) {
            level -= 256;
          }
        } else {
          level = _bits(12);
          if (level >= 0x800) level -= 0x1000;
        }
      } else {
        run = b;
        level = Vlc.aOf(entry);
      }
      i += run;
      if (i > 63) {
        _ecd = true;
        break;
      }
      final pos = scan[i++];
      var v = intra
          ? (2 * level * matrix[pos] * qscale) ~/ 32
          : ((2 * level + (level > 0 ? 1 : -1)) * matrix[pos] * qscale) ~/ 32;
      if (_mpeg1 && v & 1 == 0 && v != 0) v -= v > 0 ? 1 : -1;
      v = v < -2048 ? -2048 : (v > 2047 ? 2047 : v);
      f[pos] = v;
      sum += v;
    }
    // MPEG-2 mismatch control
    if (!_mpeg1 && sum & 1 == 0) f[63] ^= 1;
  }

  // ---- IDEC ----

  /// One macroblock of an I-picture slice, converted to RGB. Returns true
  /// at the end of the slice.
  bool _idec() {
    if (_skipPending) {
      _skip(_option & 0x3f);
      _resetDc();
      _skipPending = false;
    }
    // macroblock_address_increment with stuffing and escapes
    while (true) {
      final entry = _vlc(mbaiTable);
      if (entry == 0) {
        _ecd = true;
        return true;
      }
      final v = Vlc.aOf(entry);
      if (v < 0x22) break;
    }
    final type = _vlc(mbTypeTables[0]);
    if (type == 0) {
      _ecd = true;
      return true;
    }
    final fieldDct = _option & (1 << 24) != 0 && _bits(1) == 1;
    var qsc = _qsc;
    if (Vlc.aOf(type) & mbQuant != 0) qsc = _bits(5);
    _decodeMacroblock(true, 0x3f, qsc, fieldDct);
    _cbp = 0x3f;
    final mb = _mb;
    for (var i = 0; i < 384; i++) {
      final v = mb[i];
      mb[i] = v < 0 ? 0 : (v > 255 ? 255 : v);
    }
    _convert(_mb,
        rgb16: _option & (1 << 27) != 0,
        dither: _option & (1 << 26) != 0,
        signed: _option & (1 << 25) != 0);
    // the slice ends at the next start code: 23 zero bits
    final ended = _peek(23) == 0;
    if (ended) _scd = true;
    _qsc = qsc;
    return ended;
  }

  // ---- CSC and PACK ----

  bool _csc() {
    if (_left == 0) return true;
    final mb = _mb;
    for (var i = 0; i < 384; i++) {
      mb[i] = _bits(8);
    }
    _convert(mb,
        rgb16: _option & (1 << 27) != 0, dither: _option & (1 << 26) != 0);
    _left--;
    return _left == 0;
  }

  static const _dither = [
    -4, 0, -3, 1, 2, -2, 3, -1, -3, 1, -4, 0, 3, -1, 2, -2, //
  ];

  final _bytes = <int>[];

  /// converts a macroblock of 8-bit Y, Cb and Cr to RGB32 or RGB16
  void _convert(Int16List mb,
      {required bool rgb16, bool dither = false, bool signed = false}) {
    final out = _bytes..clear();
    for (var y = 0; y < 16; y++) {
      for (var x = 0; x < 16; x++) {
        final c = (y >> 1) * 8 + (x >> 1);
        final l = (mb[y * 16 + x] - 16) * 76309; // 1.164 << 16
        final cb = mb[256 + c] - 128, cr = mb[320 + c] - 128;
        var r = (l + 104597 * cr + 0x8000) >> 16;
        var g = (l - 25675 * cb - 53279 * cr + 0x8000) >> 16;
        var b = (l + 132201 * cb + 0x8000) >> 16;
        r = r < 0 ? 0 : (r > 255 ? 255 : r);
        g = g < 0 ? 0 : (g > 255 ? 255 : g);
        b = b < 0 ? 0 : (b > 255 ? 255 : b);
        final alpha = r < _th0 && g < _th0 && b < _th0
            ? 0
            : (r < _th1 && g < _th1 && b < _th1 ? 0x40 : 0x80);
        if (signed) {
          r = (r - 128) & 0xff;
          g = (g - 128) & 0xff;
          b = (b - 128) & 0xff;
        }
        if (rgb16) {
          out.addAll(_rgb16(
              r, g, b, alpha, dither ? _dither[(y & 3) * 4 + (x & 3)] : 0));
        } else {
          out.addAll([r, g, b, alpha]);
        }
      }
    }
    _emit(out);
  }

  static List<int> _rgb16(int r, int g, int b, int alpha, int d) {
    int c(int v) {
      final w = v + d;
      return (w < 0 ? 0 : (w > 255 ? 255 : w)) >> 3;
    }

    final v = c(r) | c(g) << 5 | c(b) << 10 | (alpha != 0 ? 0x8000 : 0);
    return [v & 0xff, v >> 8];
  }

  /// PACK: a macroblock of RGB32 to RGB16 or to 4-bit indices of the VQ
  /// colour table
  bool _pack() {
    if (_left == 0) return true;
    final rgb16 = _option & (1 << 27) != 0;
    final dither = _option & (1 << 26) != 0;
    final out = _bytes..clear();
    var pending = -1;
    for (var p = 0; p < 256; p++) {
      final r = _bits(8), g = _bits(8), b = _bits(8), a = _bits(8);
      if (rgb16) {
        final d = dither ? _dither[((p >> 4) & 3) * 4 + (p & 3)] : 0;
        out.addAll(_rgb16(r, g, b, a, d));
      } else {
        final index = _nearest(r, g, b);
        if (pending < 0) {
          pending = index;
        } else {
          out.add(pending | index << 4);
          pending = -1;
        }
      }
    }
    _emit(out);
    _left--;
    return _left == 0;
  }

  int _nearest(int r, int g, int b) {
    var best = 0, bestDistance = 1 << 30;
    for (var i = 0; i < 16; i++) {
      final c = _vq[i];
      final dr = (c & 0x1f) * 8 - r;
      final dg = ((c >> 5) & 0x1f) * 8 - g;
      final db = ((c >> 10) & 0x1f) * 8 - b;
      final d = dr * dr + dg * dg + db * db;
      if (d < bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    return best;
  }

  /// queues bytes (a multiple of 16) for the output FIFO
  void _emit(List<int> bytes) {
    for (var i = 0; i < bytes.length; i += 8) {
      var v = 0;
      for (var k = 7; k >= 0; k--) {
        v = v << 8 | bytes[i + k];
      }
      _pending.add(v);
    }
  }

  // ---- DMA ----

  bool get _hasOutput => _out.isNotEmpty;

  void _get(Int64List quad) {
    quad[0] = _out.removeFirst();
    quad[1] = _out.removeFirst();
  }
}

class _IpuInput extends DmaEndpoint {
  final Ipu ipu;
  _IpuInput(this.ipu);

  @override
  bool get canPut => ipu._canPut;

  @override
  void put(int low, int high) => ipu._put(low, high);
}

class _IpuOutput extends DmaEndpoint {
  final Ipu ipu;
  _IpuOutput(this.ipu);

  @override
  bool get hasData => ipu._hasOutput;

  @override
  void get(Int64List out) => ipu._get(out);
}

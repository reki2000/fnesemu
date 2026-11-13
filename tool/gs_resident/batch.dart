import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs_memory.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs_raster.dart';

const _commandWords = 160;
const _operation = 146;
const _start = 147;
const _end = 148;

typedef ResidentBatch = ({
  Uint8List commands,
  Uint8List auxiliary,
  int draws,
  int drawDispatches,
  int uploads,
  int paletteLoads,
  int width,
  int height,
});

Uint8List residentCheckpoint(Gs gs) {
  final memory = gs.mem.bytes;
  final clut = gs.raster.residentClut.buffer.asUint8List();
  return Uint8List(memory.length + clut.length)
    ..setAll(0, memory)
    ..setAll(memory.length, clut);
}

class GsResidentBatchEncoder implements GsResidentSink {
  GsResidentBatchEncoder(this.gs) : _mem = gs.mem {
    final aux = List<int>.filled(64 * 4, 0, growable: true);
    final tables = <GsLayout, int>{};
    for (var psm = 0; psm < 64; psm++) {
      final layout = _mem.layout(psm);
      final offset = tables.putIfAbsent(layout, () {
        final start = aux.length;
        aux.addAll(layout.table);
        return start;
      });
      aux.setAll(
          psm * 4, [offset, layout.xBits, layout.yBits, layout.unitShift]);
    }
    _layouts = Uint32List.fromList(aux);
    _appendAux(_layouts);
  }

  @override
  ImageBuffer? completedImage;

  @override
  void vblank(int field) {}

  @override
  void copyLocal(int bitbltbuf, int trxpos, int trxreg) =>
      throw UnsupportedError('resident GS transfer 2');

  @override
  void beginDownload(int psm, int base, int bufferWidth, int x, int y,
          int width, int height) =>
      throw UnsupportedError('resident GS transfer 1');

  final Gs gs;
  final GsMemory _mem;
  late final Uint32List _layouts;
  final _commands = BytesBuilder(copy: false);
  final _auxiliary = BytesBuilder(copy: false);
  final _palette = <int, (int, int, int)>{};
  var _auxiliaryWords = 0;
  Uint32List? _upload, _uploadData;
  var _uploadPosition = 0;
  var _draws = 0, _dispatches = 0, _uploads = 0, _paletteLoads = 0;

  void _add(Uint32List command) => _commands.add(command.buffer.asUint8List());

  void _appendAux(Uint32List words) {
    _auxiliary.add(words.buffer.asUint8List());
    _auxiliaryWords += words.length;
  }

  void _flushUpload() {
    final command = _upload;
    if (command == null) return;
    final data = _uploadData!;
    if (_uploadPosition != data.length) {
      throw UnsupportedError('partial GS transfer');
    }
    command[_start] = _auxiliaryWords;
    _appendAux(data);
    _add(command);
    _upload = null;
    _uploadData = null;
    _uploadPosition = 0;
    _uploads++;
  }

  @override
  void beginUpload(
      int psm, int base, int bufferWidth, int x, int y, int width, int height) {
    _flushUpload();
    _flushPalette();
    if (width == 0 || height == 0) return;
    final layout = _mem.layout(psm);
    final pages = layout.pagesInRow(bufferWidth);
    final right = x + width, bottom = y + height;
    final lastX = (right - 1) >> layout.xBits;
    final lastPage = ((bottom - 1) >> layout.yBits) * pages + lastX;
    if (!GsPsm.isValid(psm) ||
        right > 2048 ||
        bottom > 2048 ||
        lastX >= pages ||
        base + (lastPage + 1) * 32 > GsMemory.size ~/ 256) {
      throw UnsupportedError('aliased GS transfer');
    }
    final bits = GsPsm.pixelBits(psm), pixels = width * height;
    _upload = Uint32List(_commandWords)
      ..[_operation] = 1
      ..[_end] = pixels
      ..[149] = bits
      ..setAll(112, [x, y, width, height, psm, base, pages]);
    _uploadData = Uint32List((pixels * bits + 31) ~/ 32);
  }

  @override
  bool uploadWord(int word) {
    final data = _uploadData;
    if (data == null || _uploadPosition >= data.length) {
      throw UnsupportedError('GS transfer data outside a transfer');
    }
    data[_uploadPosition++] = word;
    return _uploadPosition == data.length;
  }

  @override
  void loadClut(int entry, int psm, int index) {
    _flushUpload();
    final shift = _mem.layout(psm).unitShift;
    final bit = (index & ((1 << shift) - 1)) * (32 >> shift);
    final mask = (1 << GsPsm.pixelBits(psm)) - 1;
    _palette[entry] = ((index >> shift) & 0xfffff, bit, mask);
  }

  void _flushPalette() {
    if (_palette.isEmpty) return;
    final command = Uint32List(_commandWords)
      ..[_operation] = 2
      ..[_start] = _auxiliaryWords
      ..[_end] = _palette.length;
    final payload = Uint32List(_palette.length * 4);
    var at = 0;
    for (final MapEntry(key: entry, value: (word, shift, mask))
        in _palette.entries) {
      payload[at++] = entry;
      payload[at++] = word;
      payload[at++] = shift;
      payload[at++] = mask;
    }
    _appendAux(payload);
    _add(command);
    _palette.clear();
    _paletteLoads++;
  }

  @override
  void draw(GsHostDraw? draw, String unsupported) {
    _draws++;
    if (draw == null) {
      if (unsupported != 'no_raster_effect') {
        throw UnsupportedError('draw $_draws ($unsupported)');
      }
      return;
    }
    _flushUpload();
    _flushPalette();
    final state = draw.buildResidentState();
    final rowEnds = draw.residentRowEnds;
    if (rowEnds == null || rowEnds.length == 1) {
      state[_end] = draw.height;
      _add(state);
      _dispatches++;
      return;
    }
    var first = 0;
    for (final last in rowEnds) {
      _add(Uint32List.fromList(state)
        ..[_start] = first
        ..[_end] = last);
      _dispatches++;
      first = last;
    }
  }

  ResidentBatch finish(int display) {
    _flushUpload();
    _flushPalette();
    if (gs.pmode & 2 == 0 || gs.smode2 & 3 != 3 || gs.display2 >> 27 & 3 != 0) {
      throw UnsupportedError('GS display mode');
    }
    final width =
        ((gs.display2 >> 32 & 0xfff) + 1) ~/ ((gs.display2 >> 23 & 15) + 1);
    final height = ((gs.display2 >> 44 & 0x7ff) + 1).clamp(1, 480);
    _add(Uint32List(_commandWords)
      ..[_operation] = 3
      ..setAll(112, [
        display >> 32 & 0x7ff,
        display >> 43 & 0x7ff,
        width,
        height,
        display >> 15 & 0x1f,
        (display & 0x1ff) * 32,
        display >> 9 & 0x3f,
      ]));
    final batch = (
      commands: _commands.takeBytes(),
      auxiliary: _auxiliary.takeBytes(),
      draws: _draws,
      drawDispatches: _dispatches,
      uploads: _uploads,
      paletteLoads: _paletteLoads,
      width: width,
      height: height,
    );
    _draws = _dispatches = _uploads = _paletteLoads = _auxiliaryWords = 0;
    _appendAux(_layouts);
    return batch;
  }
}

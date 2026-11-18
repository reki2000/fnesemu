import 'dart:convert';
import 'dart:typed_data';

import 'package:fnesemu_core/src/util/iso9660.dart';
import 'package:test/test.dart';

/// writes a directory record of [name] at [at] of [sector], returns its length
int _record(Uint8List sector, int at, String name, int lba, int size,
    {bool directory = false}) {
  final length = 33 + name.length + (name.length.isEven ? 1 : 0);
  sector[at] = length;
  ByteData.sublistView(sector)
    ..setUint32(at + 2, lba, Endian.little)
    ..setUint32(at + 10, size, Endian.little);
  sector[at + 25] = directory ? 2 : 0;
  sector[at + 32] = name.length;
  sector.setRange(at + 33, at + 33 + name.length, ascii.encode(name));
  return length;
}

/// a volume of [blocks] blocks whose root directory is at [rootLba]
Map<int, Uint8List> _volume(int blocks, int rootLba) {
  final pvd = Uint8List(2048)..[0] = 1;
  pvd.setRange(1, 6, ascii.encode('CD001'));
  ByteData.sublistView(pvd).setUint32(80, blocks, Endian.little);
  _record(pvd, 156, '\x00', rootLba, 2048, directory: true);
  return {16: pvd};
}

Iso9660 _iso(Map<int, Uint8List> sectors) =>
    Iso9660((lba) async => sectors[lba] ?? Uint8List(2048));

void main() {
  test('finds a file in a directory', () async {
    final sectors = _volume(40, 20);
    final root = sectors[20] = Uint8List(2048);
    var at = _record(root, 0, '\x00', 20, 2048, directory: true);
    at += _record(root, at, '\x01', 20, 2048, directory: true);
    _record(root, at, 'GAME', 21, 2048, directory: true);
    final game = sectors[21] = Uint8List(2048);
    _record(game, 0, 'BOOT.BIN;1', 30, 5);

    final file = await _iso(sectors).find('game/boot.bin');
    expect((file?.lba, file?.size), (30, 5));
  });

  test('a root directory outside the volume is no file system', () async {
    // a later session addresses its blocks from the start of the disc
    final sectors = _volume(40, 11720);
    sectors[11720] = Uint8List(2048);
    _record(sectors[11720]!, 0, 'SYSTEM.CNF;1', 11730, 5);
    final iso = _iso(sectors);
    expect(await iso.root, isNull);
    expect(await iso.findRootFile('SYSTEM.CNF'), isNull);
  });

  test('a record cut by the end of a sector ends the directory', () async {
    final sectors = _volume(40, 20);
    final root = sectors[20] = Uint8List(2048);
    final length = _record(root, 0, 'A;1', 30, 5);
    _record(root, length, 'B;1', 31, 5);
    // B is stretched to 2040, where a record does not fit in the sector
    root[length] = 2040 - length;
    root[2040] = 40;
    final iso = _iso(sectors);
    final entries = await iso.list((await iso.root)!);
    expect(entries.map((entry) => entry.name), ['A', 'B']);
  });

  test('a name longer than its record ends the directory', () async {
    final sectors = _volume(40, 20);
    final root = sectors[20] = Uint8List(2048);
    final length = _record(root, 0, 'A;1', 30, 5);
    _record(root, length, 'B;1', 31, 5);
    root[length + 32] = 200;
    final iso = _iso(sectors);
    final entries = await iso.list((await iso.root)!);
    expect(entries.map((entry) => entry.name), ['A']);
  });

  test('a file outside the volume is left out', () async {
    final sectors = _volume(40, 20);
    final root = sectors[20] = Uint8List(2048);
    final length = _record(root, 0, 'FAR;1', 39, 4096);
    _record(root, length, 'NEAR;1', 39, 2048);
    final iso = _iso(sectors);
    final entries = await iso.list((await iso.root)!);
    expect(entries.map((entry) => entry.name), ['NEAR']);
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/seven_zip.dart';

import 'seven_zip_fixtures.dart';

// the contents of the fixtures, as the generator wrote them
Uint8List _random(int n) {
  final out = Uint8List(n);
  var x = 1;
  for (var i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    out[i] = (x >> 16) & 0xff;
  }
  return out;
}

Uint8List _pattern(int n) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (i * 7 + (i >> 9)) & 0xff]);

Future<SevenZip> _open(Uint8List bytes) => SevenZip.open(
    bytes.length,
    (offset, length) async =>
        Uint8List.sublistView(bytes, offset, offset + length));

void main() {
  final expected = {
    'a.txt': utf8.encode('hello 7z\n'),
    'dir/c.txt': utf8.encode('second file\n' * 10),
    'random.bin': _random(4000),
    'empty.txt': Uint8List(0),
  };

  for (final MapEntry(key: method, value: fixture)
      in sevenZipFixtures.entries) {
    test('reads the entries packed with $method', () async {
      final zip = await _open(base64.decode(fixture));
      final files = {
        for (final e in zip.entries)
          if (!e.isDirectory) e.name: e
      };
      expect(zip.entries.where((e) => e.isDirectory).map((e) => e.name),
          contains('emptydir'));
      final want = {
        ...expected,
        if (method != 'copy') 'pattern.bin': _pattern(3 * 1024 * 1024 + 5),
      };
      expect(files.keys.toSet(), want.keys.toSet());
      for (final MapEntry(:key, :value) in want.entries) {
        expect(files[key]!.size, value.length, reason: key);
        expect(await zip.read(files[key]!), value, reason: key);
      }
    });
  }

  test('rejects a file that is not a 7z archive', () async {
    expect(_open(Uint8List(64)), throwsA(isA<SevenZipException>()));
  });

  test('detects a corrupt entry by its CRC', () async {
    final bytes = base64.decode(sevenZipFixtures['copy']!);
    final zip = await _open(bytes);
    final entry = zip.entries.firstWhere((e) => e.name == 'a.txt');
    // the copied content starts after the 32-byte start header
    final at = _indexOf(bytes, utf8.encode('hello 7z'));
    bytes[at] ^= 1;
    expect(zip.read(entry), throwsA(isA<SevenZipException>()));
  });

  test('knows the 7z extension', () {
    expect(isSevenZip('bench.7Z'), isTrue);
    expect(isSevenZip('bench.zip'), isFalse);
  });
}

int _indexOf(List<int> data, List<int> needle) {
  for (var i = 0; i + needle.length <= data.length; i++) {
    var j = 0;
    while (j < needle.length && data[i + j] == needle[j]) {
      j++;
    }
    if (j == needle.length) return i;
  }
  return -1;
}

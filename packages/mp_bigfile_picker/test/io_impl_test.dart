import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp_bigfile_picker/io.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mp_bigfile_picker');
    await Directory('${dir.path}/sub/deep').create(recursive: true);
    await File('${dir.path}/a.bin')
        .writeAsBytes(Uint8List.fromList(List.generate(1000, (i) => i & 0xff)));
    await File('${dir.path}/sub/b.txt').writeAsString('b');
    await File('${dir.path}/sub/deep/c.txt').writeAsString('c');
  });

  tearDown(() => dir.delete(recursive: true));

  test('walk lists the files recursively with relative paths', () async {
    final d = IoDirectory(dir.path);
    expect((await d.walk().toList())..sort(),
        ['a.bin', 'sub/b.txt', 'sub/deep/c.txt']);
    expect(d.restoreKey, dir.path);
  });

  test('read at any offset, and less at the end', () async {
    final f = IoDirectory(dir.path).open('a.bin');
    expect(f.name, 'a.bin');
    expect(await f.length(), 1000);
    final results = await Future.wait([f.read(300, 4), f.read(998, 10)]);
    expect(results[0], [300 & 0xff, 301 & 0xff, 302 & 0xff, 303 & 0xff]);
    expect(results[1], [998 & 0xff, 999 & 0xff]);
    await f.close();
    // opened again after close
    expect(await f.read(0, 2), [0, 1]);
    await f.close();
  });
}

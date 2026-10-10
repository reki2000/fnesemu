// compares two disc images sector by sector (e.g. a .cue and the .chd made
// from it by chdman): dart run tool/compare_images.dart <image> <image>
import 'dart:io';
import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';

class _LocalFile extends DiscFile {
  final File file;
  @override
  final String path;

  _LocalFile(this.file, this.path);

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> read(int offset, int length) async {
    final f = await file.open();
    try {
      await f.setPosition(offset);
      return await f.read(length);
    } finally {
      await f.close();
    }
  }
}

Future<DiscImage> _open(String path) async {
  final dir = File(path).parent;
  final files = [
    for (final e in dir.listSync())
      if (e is File) _LocalFile(e, e.uri.pathSegments.last)
  ];
  final main = files.firstWhere((f) => f.path == File(path).uri.pathSegments.last);
  return (await DiscImage.parse(files, main)).$1;
}

Future<void> main(List<String> args) async {
  final a = await _open(args[0]), b = await _open(args[1]);
  print('a: ${a.toc.tracks}');
  print('b: ${b.toc.tracks}');
  if (a.totalSectors != b.totalSectors) {
    print('total sectors differ: ${a.totalSectors} ${b.totalSectors}');
  }
  final total = a.totalSectors < b.totalSectors ? a.totalSectors : b.totalSectors;
  final sw = Stopwatch()..start();
  var differ = 0;
  const chunk = 75;
  for (int lba = 0; lba < total; lba += chunk) {
    final n = lba + chunk <= total ? chunk : total - lba;
    final sa = await a.readSectors(lba, n);
    final sb = await b.readSectors(lba, n);
    for (int i = 0; i < n; i++) {
      var same = sa[i].length == sb[i].length;
      for (int k = 0; same && k < sa[i].length; k++) {
        same = sa[i][k] == sb[i][k];
      }
      if (!same && differ++ < 10) print('sector ${lba + i} differs');
    }
  }
  print('$total sectors, $differ differ (${sw.elapsedMilliseconds} ms)');
}

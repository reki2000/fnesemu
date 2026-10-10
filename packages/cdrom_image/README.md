# cdrom_image

CD-ROM disc images (.cue / .iso / .bin) on a virtual file system, in pure
Dart without dependencies. It parses the image, and gives the TOC and the raw
sectors by LBA, whatever the format.

Supported: .cue sheets (multiple track files, audio/data tracks, `INDEX
00/01`, `PREGAP`, `POSTGAP`, `MODE1/2048`), and single .iso/.bin files (2048
or 2352 bytes per sector).

## API

- `DiscFile` (`filesystem_api.dart`): a file given by the caller: `path`
  (relative to its directory, separated by `/`), `length()` and
  `read(offset, length)`. Each call holds its own resources; there is no
  open or close. A directory is an `Iterable<DiscFile>`.
- `DiscImage` (`image_api.dart`): `toc` (`DiscToc`, `DiscTrack`),
  `totalSectors`, and `readSectors(lba, count)`.
- `DiscImage.parse(files, file)`: parses `file`, finding the files a .cue
  refers to in `files`. Returns the image and the referenced files (empty
  for an .iso/.bin). Throws `DiscParseException` for an invalid description
  or a missing file.
- `DiscFolder(files)`: one index for parsing many images of a directory.
  `parse(path)` returns the referenced and missing files without reading
  the tracks, and `parseSource(folder.source(path))` reads the image.
- `DiscFileKind.of(name)`: whether a file name can be a disc image.
- `memory.dart`: files on memory, for tests.

## Usage

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';
import 'package:cdrom_image/memory.dart';

Future<void> main() async {
  final directory = MemoryDirectory.of({
    'disc.cue': Uint8List.fromList(utf8.encode('''
FILE "track.bin" BINARY
  TRACK 01 MODE1/2048
    INDEX 01 00:00:00
''')),
    'track.bin': Uint8List(2048 * 2),
  });
  final (image, referenced) = await DiscImage.parse(
      directory.files.values, directory.files['disc.cue']!);
  print(referenced.map((file) => file.path)); // (track.bin)
  print(image.toc.tracks); // [track 1 data lba:0 sectors:2]
  final sectors = await image.readSectors(0, 2);
  print(sectors.first.length); // 2352
}
```

To read other storage, extend `DiscFile`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';

class LocalDiscFile extends DiscFile {
  final File file;
  @override
  final String path;

  LocalDiscFile(this.file, this.path);

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> read(int offset, int length) async {
    final handle = await file.open(); // a handle per read: reads may overlap
    try {
      await handle.setPosition(offset);
      return await handle.read(length);
    } finally {
      await handle.close();
    }
  }
}
```

## Details

- A .cue file's references are relative to the .cue file; the case is
  ignored, `\` is taken as `/`, and a path out of the directory is missing.
- LBAs start at 0, without the 150 sectors of the lead-in.
- `readSectors` returns 2352-byte sectors, for a range inside
  `totalSectors`. 2048-byte data is expanded to mode 1 sectors (EDC/ECC are
  left zero); gaps and short reads are filled with zero.
- Storage errors of `length()` and `read()` are passed to the caller.

## Tests

```sh
dart test
```

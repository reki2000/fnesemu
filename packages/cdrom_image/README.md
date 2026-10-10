# cdrom_image

Parses disc-image formats and provides a common interface for reading CD-ROM
sectors. The parser resolves track files, sector layouts, and gaps; callers
read by logical block address (LBA) through `DiscImage`, regardless of the
underlying image format.

Currently supports CUE sheets and standalone ISO/BIN images. CUE parsing
handles multiple binary track files, audio/data tracks, `INDEX 00/01`,
`PREGAP`, and `POSTGAP`. Additional formats can use the same sector-reading
interface.

## APIs

- `filesystem_api.dart`: `DiscFile` (relative path, length, byte reads) and
  `DiscDirectory` (recursive file enumeration). Each operation manages its
  own resources; there is no explicit open or close.
- `image_api.dart`: `DiscImage`, `DiscToc`, and `DiscTrack`. This contract
  exposes TOC information and raw sectors by LBA, independent of storage
  and image format.
- `cdrom_image.dart`: both APIs and parsing entry points. Use
  `DiscImage.parse(directory, file)` returns `(DiscImage, List<DiscFile>)`. The factory
  delegates to the parser implementation outside the API files.

## Usage

This example uses the in-memory file system supplied by `memory.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';
import 'package:cdrom_image/memory.dart';

Future<void> main() async {
  final directory = MemoryDirectory.of({
    'disc.cue': Uint8List.fromList(
      utf8.encode('''
FILE "track.bin" BINARY
  TRACK 01 MODE1/2048
    INDEX 01 00:00:00
'''),
    ),
    'track.bin': Uint8List(2048 * 2),
  });
  final file = (await directory.walk().toList()).singleWhere(
    (file) => file.path == 'disc.cue',
  );
  final (image, referencedFiles) = await DiscImage.parse(directory, file);
  print(referencedFiles.map((file) => file.path)); // (track.bin)
  print(image.toc.tracks);
  final sectors = await image.readSectors(0, 2);
  print(sectors.first.length); // 2352
}
```

## Implementing the virtual file API

Extend `DiscFile` and `DiscDirectory` to provide your storage backend:

| Member | Contract |
|---|---|
| `DiscFile.path` | File path relative to its directory, using `/`, e.g. `tracks/track.bin`. |
| `length()` | Total length in bytes; manages its own resources. |
| `read(offset, length)` | Read at an absolute byte offset; return fewer bytes at EOF and release resources on success or failure. |
| `DiscDirectory.walk()` | Yield files recursively in unspecified order, without opening their contents. |

No explicit `open()` or `close()` is needed. Each operation owns its resources.
Here is a local-filesystem implementation using a fresh handle for each read,
so concurrent reads do not share a seek position:

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
    final handle = await file.open();
    try {
      await handle.setPosition(offset);
      return await handle.read(length);
    } finally {
      await handle.close();
    }
  }
}

class LocalDiscDirectory extends DiscDirectory {
  final Directory directory;

  LocalDiscDirectory(String path) : directory = Directory(path).absolute;

  @override
  Stream<DiscFile> walk() async* {
    final root = directory.path;
    final prefix = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is File) {
        final path = entry.path
            .substring(prefix.length)
            .replaceAll(Platform.pathSeparator, '/');
        yield LocalDiscFile(entry, path);
      }
    }
  }
}
```

Use `LocalDiscDirectory('/path/to/discs')` in place of `MemoryDirectory` in
the usage example above. The directory supplies bytes and paths; it does
not need to parse CUE sheets or calculate sector offsets. The same interfaces
can wrap other storage backends. The package itself remains pure Dart with
no runtime dependencies; `memory.dart` supplies in-memory implementations.

`DiscImage.parse(directory, file)` indexes paths and returns the image and
its distinct referenced files. The list excludes the description file and is
empty for standalone images. References are collected during parsing without
reading the description a second time.
For batch parsing, `DiscFolder(files)` lets callers reuse one index:
`folder.parse(path)` reports referenced and missing files, and
`parseSource(folder.source(path))` reads the image. CUE references
are resolved relative to the CUE, ignoring case and normalizing path
separators; paths outside the directory are rejected.

## Parse errors

The async factory completes with `DiscParseException` for missing referenced
files or invalid image descriptions. Its fields identify the description and,
when applicable, the missing reference:

```dart
try {
  final (image, referencedFiles) = await DiscImage.parse(directory, file);
  // Use image.readSectors(...) and referencedFiles.
} on DiscParseException catch (error) {
  print(error.imagePath);
  print(error.referencedPath); // e.g. 'tracks/missing.bin', or null
  print(error.message);
}
```

Storage errors from `length()`, `read()`, or `walk()` propagate to the caller.

## Sector reads

LBAs start at zero, excluding the 150-sector lead-in. The TOC provides each
track's number, audio/data type, starting LBA, and sector count.

`readSectors` returns 2352-byte sectors. Cooked data is expanded to Mode 1,
with EDC/ECC left zero; gaps and short reads are zero-filled. Call it only for
ranges inside `image.totalSectors`. No resource cleanup is required afterward.

## Tests

From this directory:

```sh
dart pub get
dart test
```

Tests use in-memory files.

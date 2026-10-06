# mp_bigfile_picker

Picks a directory or files, and reads the files at any offset without copying
them. For large files such as disc images.

```dart
import 'package:mp_bigfile_picker/mp_bigfile_picker.dart';

// a directory
final dir = await pickDirectory();            // null if canceled
await for (final path in dir!.walk()) { ... } // 'sub/a.bin'
final file = dir.open('sub/a.bin');
final bytes = await file.read(2352 * 16, 2352);
await file.close();

// files
final files = await pickFiles(extensions: ['cue', 'bin'], multiple: true);
final head = await files!.first.read(0, 16);

// after a restart. the keys are null on the web
final again = await restoreDirectory(dir.restoreKey!);
final file2 = await restoreFile(files.first.restoreKey!);
```

| platform | pick | read | restore |
|---|---|---|---|
| Android | Storage Access Framework (`ACTION_OPEN_DOCUMENT_TREE`, `ACTION_OPEN_DOCUMENT`) | `pread` on the document's file descriptor (FFI) | persisted uri permission |
| iOS | `UIDocumentPickerViewController` (not a copy) | dart:io in the security scope | bookmark |
| macOS | `NSOpenPanel` | dart:io in the security scope | security scoped bookmark |
| Linux, Windows | `file_picker` | dart:io | path |
| web | `<input type=file>` (`webkitdirectory`) | `Blob.slice` | not supported |

- `package:mp_bigfile_picker/io.dart` has the dart:io implementation only, with
  no dependency on Flutter, for command line tools.
- `package:mp_bigfile_picker/web.dart` has the browser `File` reader, for the
  files picked by other ways.
- A sandboxed macOS app needs the entitlements
  `com.apple.security.files.user-selected.read-only` and
  `com.apple.security.files.bookmarks.app-scope`.
- On Android, `extensions` of `pickFiles` is not used, as the picker filters
  only by mime types.
- On Android, the documents must be seekable: local storage and SD cards are,
  but some cloud providers give pipes, which fail with `UnsupportedError`.
- `PickedDirectory.open` accepts only the paths found by `walk` on Android.
- The files in a `PickedDirectory` have no restore key: restore the directory.

# mp_bigfile_picker_example

Tries mp_bigfile_picker on each platform.

- The folder button picks a directory and lists the files below it.
- The file button picks files.
- Tapping a file reads its head, its tail and 256 random 2352-byte sectors,
  with the time per read.
- The directory or the files are restored at the next start by their restore
  keys.

```sh
flutter run -d <device>   # android, ios, linux, macos, windows, chrome
```

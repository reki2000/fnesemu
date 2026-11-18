import 'dart:math';
import 'dart:typed_data';

import '../../cdrom.dart';
import '../../util/iso9660.dart';

/// One node of the directory tree of a mounted disc. Children are in
/// record order; the `.` and `..` records are not nodes, [parent] links
/// take their place.
class PspDiscNode {
  final Iso9660Entry entry;
  final PspDiscNode? parent;
  final children = <PspDiscNode>[];

  PspDiscNode(this.entry, this.parent);

  bool get isDirectory => entry.isDirectory;
}

/// A disc in the drive the app gave the core, read as an ISO 9660 file
/// system. Mounting parses the whole directory tree; afterwards paths
/// resolve and file data reads run synchronously on the drive, the way
/// the kernel's file calls need them. A data read returns null while
/// the drive has not loaded one of its sectors yet; the kernel then
/// suspends the reading thread and retries as time passes.
class PspDisc {
  final CdromDrive drive;

  /// The drive LBA of the first sector of the file system.
  final int baseLba;

  final PspDiscNode root;

  /// The boot executable read at mount time: the unencrypted boot file
  /// when present, else the encrypted one.
  Uint8List? bootBytes;

  PspDisc._(this.drive, this.baseLba, this.root);

  /// Parses the file system of the disc in [drive], or returns null
  /// when the drive holds no ISO 9660 volume.
  static Future<PspDisc?> mount(CdromDrive drive) async {
    final base = drive.firstDataLba;
    if (base == null) return null;
    final iso = Iso9660(
        (lba) async => userData(await drive.readWhenReady(base + lba)));
    final rootEntry = await iso.root;
    if (rootEntry == null) return null;
    final root = PspDiscNode(rootEntry, null);
    Future<void> walk(PspDiscNode node) async {
      for (final entry in await iso.list(node.entry)) {
        if (entry.name == '.' || entry.name == '..') continue;
        final child = PspDiscNode(entry, node);
        node.children.add(child);
        if (entry.isDirectory) await walk(child);
      }
    }

    await walk(root);
    final disc = PspDisc._(drive, base, root);
    final boot = disc.lookup('PSP_GAME/SYSDIR/BOOT.BIN') ??
        disc.lookup('PSP_GAME/SYSDIR/EBOOT.BIN');
    if (boot != null) {
      disc.bootBytes = await iso
          .readFile((lba: boot.entry.lba, size: boot.entry.size));
    }
    return disc;
  }

  /// The node at [path], a `/`-separated path from the root whose
  /// components match case-insensitively, or null.
  PspDiscNode? lookup(String path) {
    var node = root;
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        node = node.parent ?? node;
        continue;
      }
      PspDiscNode? next;
      for (final child in node.children) {
        if (child.entry.name.toUpperCase() == part.toUpperCase()) {
          next = child;
          break;
        }
      }
      if (next == null) return null;
      node = next;
    }
    return node;
  }

  /// Up to [length] bytes of [entry] starting at [offset], or null
  /// while the drive has not loaded one of the needed sectors.
  Uint8List? readBytes(Iso9660Entry entry, int offset, int length) {
    if (offset < 0) offset = 0;
    if (offset >= entry.size || length <= 0) return Uint8List(0);
    final out = Uint8List(min(offset + length, entry.size) - offset);
    var done = 0;
    while (done < out.length) {
      final at = offset + done;
      final raw = drive.read(baseLba + entry.lba + at ~/ 2048);
      if (raw == null) return null;
      final user = userData(raw);
      if (user.isEmpty) return null;
      final from = at % 2048;
      final take = min(2048 - from, out.length - done);
      out.setRange(done, done + take, user, from);
      done += take;
    }
    return out;
  }
}

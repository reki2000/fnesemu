import 'dart:convert';
import 'dart:typed_data';

import '../../core.dart';
import '../../sram.dart';

/// One file or directory on the memory stick. Names are matched case
/// insensitively, as on the formatted stick, and keep the spelling
/// they were created with. [modified] counts seconds since the stick
/// epoch (2024-01-01 UTC) on the emulated clock.
class PspMsNode {
  String name;
  final bool isDirectory;
  final List<int> content = [];
  int modified = 0;
  final Map<String, PspMsNode> children = {};
  PspMsNode? parent;

  PspMsNode(this.name, this.isDirectory);

  int get size => isDirectory ? 0 : content.length;

  /// The path of this node relative to the stick root, '/'-joined.
  String get path {
    final parts = <String>[];
    PspMsNode? node = this;
    while (node != null && node.parent != null) {
      parts.add(node.name);
      node = node.parent;
    }
    return parts.reversed.join('/');
  }
}

/// The memory stick: a small writable file tree the kernel serves on
/// the ms0: device. The tree is persisted through the shared sram
/// storage under `psp/sram/memorystick` as one serialized image, so
/// saved data survives restarts the way a memory card image does in
/// the other cores. Without attached storage the stick is volatile.
///
/// The image is a 'MSFS' version 1 header (entry count as u32) and
/// one record per node in path order: the path length as u16, the
/// path in UTF-8, a type byte (0 directory, 1 file), the modification
/// stamp as u32 and, for files, the size as u32 and the bytes. An
/// image that does not parse is treated as an empty stick.
class PspMemStick {
  final PspMsNode root = PspMsNode('', true);

  Sram? _sram;

  /// Emulated seconds since the stick epoch; the kernel wires this
  /// to its clock so file stamps advance with emulated time.
  int Function() clock = () => 0;

  int get _now => clock();

  /// Binds the stick to the shared persistent storage and loads the
  /// tree saved there, if any. Attaching the same storage twice is a
  /// no-op.
  void attach(Sram sram) {
    if (identical(_sram, sram)) return;
    _sram = sram;
    sram.init(
        StorageKey.of('psp', StorageKey.sram, 'memorystick'), Uint8List(0));
    _parse(sram.data);
  }

  /// Writes the serialized tree into the attached storage, byte by
  /// byte through the storage interface so the host notices the
  /// change and flushes it. Does nothing without attached storage.
  void flush() {
    final sram = _sram;
    if (sram == null) return;
    final image = _serialize();
    final data = sram.data;
    if (data.length < image.length) {
      data.addAll(List.filled(image.length - data.length, 0));
    } else if (data.length > image.length) {
      data.length = image.length;
    }
    for (var i = 0; i < image.length; i++) {
      if (data[i] != image[i]) sram.write8(i, image[i]);
    }
  }

  /// Finds the node a root-relative path names, resolving '.' and
  /// '..' along the way, or null when any component is missing.
  PspMsNode? lookup(String rel) {
    var node = root;
    for (final part in rel.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        node = node.parent ?? node;
        continue;
      }
      if (!node.isDirectory) return null;
      final child = node.children[part.toLowerCase()];
      if (child == null) return null;
      node = child;
    }
    return node;
  }

  /// Creates the directory a root-relative path names. The parent
  /// must exist; returns the new node, or null on failure.
  PspMsNode? mkdir(String rel) {
    final (parent, name) = _parentOf(rel);
    if (parent == null || name.isEmpty) return null;
    if (parent.children.containsKey(name.toLowerCase())) return null;
    final node = PspMsNode(name, true)
      ..parent = parent
      ..modified = _now;
    parent.children[name.toLowerCase()] = node;
    return node;
  }

  /// Creates an empty file at a root-relative path whose parent
  /// directory exists; returns the new node, or null on failure.
  PspMsNode? createFile(String rel) {
    final (parent, name) = _parentOf(rel);
    if (parent == null || name.isEmpty) return null;
    if (parent.children.containsKey(name.toLowerCase())) return null;
    final node = PspMsNode(name, false)
      ..parent = parent
      ..modified = _now;
    parent.children[name.toLowerCase()] = node;
    return node;
  }

  /// Removes a file or an empty directory. The root and non-empty
  /// directories cannot be removed.
  bool remove(PspMsNode node) {
    final parent = node.parent;
    if (parent == null) return false;
    if (node.isDirectory && node.children.isNotEmpty) return false;
    parent.children.remove(node.name.toLowerCase());
    node.parent = null;
    return true;
  }

  /// Moves a node to a new root-relative path, replacing a file that
  /// already sits there. A directory cannot move into itself.
  bool rename(PspMsNode node, String rel) {
    if (node.parent == null) return false;
    final (parent, name) = _parentOf(rel);
    if (parent == null || name.isEmpty) return false;
    for (PspMsNode? p = parent; p != null; p = p.parent) {
      if (identical(p, node)) return false;
    }
    final existing = parent.children[name.toLowerCase()];
    if (existing != null && !identical(existing, node)) {
      if (existing.isDirectory) return false;
      remove(existing);
    }
    node.parent?.children.remove(node.name.toLowerCase());
    node.name = name;
    node.parent = parent;
    node.modified = _now;
    parent.children[name.toLowerCase()] = node;
    return true;
  }

  /// The parent directory and final component of a root-relative
  /// path; the parent is null when the path does not resolve.
  (PspMsNode?, String) _parentOf(String rel) {
    final parts =
        rel.split('/').where((part) => part.isNotEmpty && part != '.').toList();
    if (parts.isEmpty) return (null, '');
    var node = root;
    for (var i = 0; i < parts.length - 1; i++) {
      if (parts[i] == '..') {
        node = node.parent ?? node;
        continue;
      }
      if (!node.isDirectory) return (null, '');
      final child = node.children[parts[i].toLowerCase()];
      if (child == null) return (null, '');
      node = child;
    }
    return (node, parts.last);
  }

  Uint8List _serialize() {
    final nodes = <PspMsNode>[];
    void walk(PspMsNode node) {
      for (final child in node.children.values) {
        nodes.add(child);
        if (child.isDirectory) walk(child);
      }
    }

    walk(root);
    nodes.sort((a, b) => a.path.compareTo(b.path));
    final out = BytesBuilder();
    out.add([0x4d, 0x53, 0x46, 0x53, 1]); // 'MSFS', version 1
    void u32(int value) => out.add([
          value & 0xff,
          (value >> 8) & 0xff,
          (value >> 16) & 0xff,
          (value >> 24) & 0xff
        ]);
    u32(nodes.length);
    for (final node in nodes) {
      final path = utf8.encode(node.path);
      out.add([path.length & 0xff, (path.length >> 8) & 0xff]);
      out.add(path);
      out.addByte(node.isDirectory ? 0 : 1);
      u32(node.modified);
      if (!node.isDirectory) {
        u32(node.content.length);
        out.add(node.content);
      }
    }
    return out.toBytes();
  }

  void _parse(List<int> data) {
    root.children.clear();
    if (data.length < 9) return;
    if (data[0] != 0x4d ||
        data[1] != 0x53 ||
        data[2] != 0x46 ||
        data[3] != 0x53) {
      return;
    }
    if (data[4] != 1) return;
    var at = 5;
    int u32() =>
        data[at] | data[at + 1] << 8 | data[at + 2] << 16 | data[at + 3] << 24;
    final count = u32();
    at += 4;
    try {
      for (var i = 0; i < count; i++) {
        final length = data[at] | data[at + 1] << 8;
        at += 2;
        final path = utf8.decode(data.sublist(at, at + length));
        at += length;
        final isDirectory = data[at++] == 0;
        final modified = u32();
        at += 4;
        final node = isDirectory ? mkdir(path) : createFile(path);
        if (node == null) return;
        node.modified = modified;
        if (!isDirectory) {
          final size = u32();
          at += 4;
          node.content.addAll(data.sublist(at, at + size));
          at += size;
        }
      }
    } catch (_) {
      // A truncated or corrupt image leaves the stick partially
      // loaded; start empty instead of trusting any of it.
      root.children.clear();
    }
  }

  /// The calendar fields of a modification stamp, for status calls.
  static (int, int, int, int, int, int) dateOf(int stamp) {
    final time = DateTime.fromMillisecondsSinceEpoch(
        1704067200000 + stamp * 1000,
        isUtc: true);
    return (
      time.year,
      time.month,
      time.day,
      time.hour,
      time.minute,
      time.second
    );
  }
}

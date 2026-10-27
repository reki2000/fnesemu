import 'dart:typed_data';

import '../../util/uint8list.dart';

/// A loadable segment of an ELF32 executable.
class ElfSegment {
  /// virtual address the segment is loaded at
  final int address;

  /// bytes taken from the file; the rest up to [memorySize] is zero
  final Uint8List data;
  final int memorySize;

  const ElfSegment(this.address, this.data, this.memorySize);
}

/// A little-endian 32-bit MIPS executable, as the EE runs it.
class Elf {
  static const _machineMips = 8;
  static const _typeExecutable = 2;
  static const _segmentLoad = 1;

  final int entry;
  final List<ElfSegment> segments;

  const Elf(this.entry, this.segments);

  /// Throws a [FormatException] when [body] is not an executable ELF32 for
  /// MIPS or when a segment lies outside the file.
  factory Elf.parse(Uint8List body) {
    if (body.length < 52 ||
        body[0] != 0x7f ||
        body[1] != 0x45 ||
        body[2] != 0x4c ||
        body[3] != 0x46) {
      throw const FormatException('not an ELF file');
    }
    if (body[4] != 1 || body[5] != 1) {
      throw const FormatException('not a 32-bit little-endian ELF file');
    }
    if (body.getUint16LE(16) != _typeExecutable ||
        body.getUint16LE(18) != _machineMips) {
      throw const FormatException('not a MIPS executable');
    }
    final entry = body.getUint32LE(24);
    final tableOffset = body.getUint32LE(28);
    final entrySize = body.getUint16LE(42);
    final count = body.getUint16LE(44);
    if (entrySize < 32 || tableOffset + count * entrySize > body.length) {
      throw const FormatException('program header table is out of range');
    }
    final segments = <ElfSegment>[];
    for (var i = 0; i < count; i++) {
      final header = tableOffset + i * entrySize;
      if (body.getUint32LE(header) != _segmentLoad) continue;
      final offset = body.getUint32LE(header + 4);
      final address = body.getUint32LE(header + 8);
      final fileSize = body.getUint32LE(header + 16);
      final memorySize = body.getUint32LE(header + 20);
      if (offset + fileSize > body.length || fileSize > memorySize) {
        throw const FormatException('segment is out of range');
      }
      segments.add(ElfSegment(
          address, body.sublist(offset, offset + fileSize), memorySize));
    }
    return Elf(entry, segments);
  }
}

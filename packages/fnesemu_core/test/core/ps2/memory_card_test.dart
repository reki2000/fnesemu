import 'package:fnesemu_core/src/core/ps2/iop/memory_card.dart';
import 'package:fnesemu_core/src/core/ps2/iop/sio2.dart';
import 'package:test/test.dart';

List<int> _send(Ps2MemoryCard card, List<int> bytes, [int? length]) =>
    card.transfer(bytes, length ?? bytes.length)!;

void main() {
  test('the spec reply carries the geometry and its checksum', () {
    final card = Ps2MemoryCard.blank();
    final reply = _send(card, [0x81, 0x26, ...List.filled(11, 0)]);
    expect(reply.sublist(2), [0x2b, 0, 2, 0x10, 0, 0, 0x40, 0, 0, 0x52, 0x55]);
  });

  test('a page is written, read back and erased', () {
    final card = Ps2MemoryCard.blank();
    expect(_send(card, [0x81, 0x27, 0x5a, 0, 0]).sublist(3), [0x2b, 0x5a]);

    final data = List.generate(128, (i) => i ^ 0x3c);
    expect(_send(card, [0x81, 0x22, 0x21, 0, 0, 0, 0x21, 0, 0]).sublist(7),
        [0x2b, 0x5a]);
    final write = _send(card, [0x81, 0x42, 128, ...data, 0, 0]);
    expect([write[2], write[3], write.last], [0x2b, 0x5a, 0x5a]);

    _send(card, [0x81, 0x23, 0x21, 0, 0, 0, 0x21, 0, 0]);
    final read = _send(card, [0x81, 0x43, 128], 134);
    expect(read.sublist(4, 132), data);
    expect(read[132], data.fold<int>(0, (a, b) => a ^ b));
    expect(read[133], 0x5a);

    // page 0x21 is in block 2, which the erase clears
    _send(card, [0x81, 0x21, 0x20, 0, 0, 0, 0x20, 0, 0]);
    _send(card, [0x81, 0x82, 0, 0]);
    _send(card, [0x81, 0x23, 0x21, 0, 0, 0, 0x21, 0, 0]);
    expect(_send(card, [0x81, 0x43, 128], 134).sublist(4, 132),
        List.filled(128, 0xff));
  });

  test('the ECC of a chunk follows the bit and byte parities', () {
    expect(Ps2MemoryCard.ecc(List.filled(128, 0)), [0x77, 0x7f, 0x7f]);
    expect(Ps2MemoryCard.ecc(List.filled(128, 0xff)), [0x77, 0x7f, 0x7f]);
    // one set bit 0 in byte 5 flips the masks with bit 0 and the indices
    final one = List.filled(128, 0)..[5] = 1;
    expect(Ps2MemoryCard.ecc(one), [0x77 ^ 0x07, 0x7f ^ (~5 & 0x7f), 0x7f ^ 5]);
  });

  test('a formatted card holds the superblock and an empty root', () {
    final image = Ps2MemoryCard.formattedImage();
    expect(String.fromCharCodes(image.sublist(0, 28)),
        'Sony PS2 Memory Card Format ');
    expect(image.sublist(0x30, 0x3c),
        [0, 0x20, 0, 0, 41, 0, 0, 0, 0xc7, 0x1f, 0, 0]);
    expect(image.sublist(512, 515), Ps2MemoryCard.ecc(image.sublist(0, 128)));
    // the indirect FAT cluster 8 points at the FAT clusters 9 to 40
    final ifc = 16 * Ps2MemoryCard.pageBytes;
    expect(image.sublist(ifc, ifc + 8), [9, 0, 0, 0, 10, 0, 0, 0]);
    // the first FAT entry marks the root cluster as the end of its chain
    final fat = 18 * Ps2MemoryCard.pageBytes;
    expect(image.sublist(fat, fat + 8),
        [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f]);
    final root = 82 * Ps2MemoryCard.pageBytes;
    expect(
        [image[root], image[root + 1], image[root + 0x40]], [0x27, 0x84, 0x2e]);
    // the backup blocks stay erased
    expect(image[1022 * 16 * Ps2MemoryCard.pageBytes], 0xff);
  });

  test('the authentication commands are acknowledged', () {
    final card = Ps2MemoryCard.blank();
    final read = _send(card, [0x81, 0xf0, 0x01], 14);
    expect([read[3], read[12], read[13]], [0x2b, 0, 0x55]);
    final write = _send(card, [0x81, 0xf0, 0x06], 14);
    expect(write.sublist(12), [0x2b, 0x55]);
    expect(_send(card, [0x81, 0xf3, 0, 0, 0]).sublist(3), [0x2b, 0x55]);
  });

  test('DMA blocks hold one command each', () {
    final sio2 = Sio2()..card = Ps2MemoryCard.blank();
    // two commands to port 2: a probe and a get terminator
    sio2.write(Sio2.base, 4, (4 << 18) | (4 << 8) | 2);
    sio2.write(Sio2.base + 4, 4, (5 << 18) | (5 << 8) | 2);
    sio2.sendBlock([0x81, 0x11, 0, 0, 9, 9, 9, 9]);
    sio2.sendBlock([0x81, 0x28, 0, 0, 0, 9, 9, 9]);
    sio2.write(Sio2.base + 0x68, 4, 1);
    expect(sio2.replies, [
      [0xff, 0xff, 0x2b, 0x55],
      [0xff, 0xff, 0x2b, 0x55, 0x55],
    ]);
    expect(sio2.read(Sio2.base + 0x6c, 4), 0x1100);
  });
}

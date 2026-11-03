import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/maple_controller.dart';
import 'package:fnesemu_core/src/core/dc/memory_card.dart';
import 'package:fnesemu_core/src/core/dc/memory_card_timer.dart';
import 'package:fnesemu_core/src/core/dc/storage.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const base = 0xa05f6c00;
  late Dc dc;
  late DcMemoryCard memoryCard;
  var selection = 0;
  List<int> transfer(int command, [List<int> data = const [], int unit = 1]) {
    final packet = [command, unit, 0, data.length ~/ 4, ...data];
    final bus = dc.bus;
    bus.write32(0xffa00040, 0x8201);
    bus.ram.setUint32LE(0x10000, 0x80000000 | (packet.length ~/ 4 - 1));
    bus.ram.setUint32LE(0x10004, 0x0c020000);
    for (var i = 0; i < packet.length; i++) {
      bus.ram[0x10008 + (selection == 0 ? i ^ 3 : i)] = packet[i];
    }
    bus.ram.fillRange(0x20000, 0x20400, 0xcc);
    bus.write32(base + 0x14, 1);
    bus.write32(base + 0x18, 1);
    bus.tickMasterClocks(1000000);
    final words = bus.ram[0x20000 + (selection == 0 ? 0 : 3)] + 1;
    return List.generate(
        words * 4, (i) => bus.ram[0x20000 + (selection == 0 ? i ^ 3 : i)]);
  }

  List<int> params(int block, int phase, [List<int> data = const []]) =>
      [0, 0, 0, 2, 0, phase, block >> 8, block & 255, ...data];
  List<int> chunk(int phase) =>
      List.generate(128, (i) => (i + phase * 31) & 255);
  void discover() {
    dc.bus.write32(base + 0x14, 0);
    dc.bus.write32(base + 0x8c, 0x6155407f);
    dc.bus.write32(base + 0xe8, 0);
    dc.bus.write32(base + 4, 0x0c010000);
    transfer(1, [], 32);
    transfer(1);
  }

  setUp(() {
    selection = 0;
    dc = Dc();
    addTearDown(dc.dispose);
    memoryCard = DcMemoryCard();
    dc.attachMemoryCard(0, 0, memoryCard);
    dc.bus.write32(base + 0x8c, 0x6155407f);
    dc.bus.write32(base + 0xe8, 0);
    dc.bus.write32(base + 4, 0x0c010000);
  });

  test(
      'controller discovers children, routes attached addresses and updates AP',
      () {
    expect(transfer(1).take(4), [255, 255, 255, 255]);
    expect(transfer(1, [], 32).take(4), [5, 0, 33, 28]);
    expect(transfer(1).take(20), [
      5,
      0,
      1,
      28,
      0,
      0,
      0,
      14,
      0x7e,
      0x7e,
      0x3f,
      0x40,
      0,
      5,
      0x10,
      0,
      0,
      15,
      65,
      0
    ]);
    expect(transfer(1, [], 2).first, 255);
    dc.attachMemoryCard(0, 1, DcMemoryCard(unit: 2));
    expect(transfer(1, [], 32)[2], 35);
    expect(transfer(1, [], 2)[2], 2);
    dc.attachMemoryCard(0, 0, null);
    expect(transfer(1, [], 32)[2], 34);
    expect(transfer(1).first, 255);
  });






  test('discovery, kill and reset preserve storage and discard partial writes',
      () {
    transfer(1, [], 32);
    expect(transfer(11, params(0, 0)).first, 255);
    final image = Uint8List(DcMemoryCard.size)
      ..fillRange(0, DcMemoryCard.size, 0x5a);
    memoryCard.loadImage(image);
    transfer(1);
    expect(transfer(4).first, 7);
    expect(transfer(1).first, 255);
    expect(transfer(3).first, 255);
    memoryCard.resetDevice();
    transfer(1);
    expect(transfer(11, params(0, 0)).sublist(12), everyElement(0x5a));
    transfer(12, params(7, 0, chunk(0)));
    dc.attachMemoryCard(0, 0, null);
    dc.attachMemoryCard(0, 0, memoryCard);
    transfer(1);
    expect(transfer(12, params(7, 1, chunk(1))).last, 2);
    expect(transfer(11, params(7, 0)).sublist(12), everyElement(0x5a));
    expect(transfer(3).first, 7);
    expect(transfer(11, params(0, 0)).first, 255);
    dc.bus.maple.reset();
    discover();
    expect(transfer(11, params(0, 0)).sublist(12), everyElement(0x5a));
  });

  test('flash and two memory cards persist independently through Core.setSram',
      () {
    final storage = _MemoryStorage();
    dc.attachMemoryCard(0, 1, DcMemoryCard(unit: 2));
    dc.setSram(storage);
    discover();
    transfer(1, [], 2);
    dc.bus.flash.loadImage(Uint8List(0x20000)..[0] = 0x17);
    for (var p = 0; p < 4; p++) {
      transfer(12, params(21, p, chunk(p)));
      transfer(12, params(22, p, List.filled(128, 0x42)), 2);
      expect(dc.bus.flash.exportImage()[0], 0x17);
    }
    expect(transfer(11, params(22, 0), 2).sublist(12), everyElement(0x42));
    final next = Dc();
    addTearDown(next.dispose);
    next.attachMemoryCard(0, 0, DcMemoryCard());
    next.attachMemoryCard(0, 1, DcMemoryCard(unit: 2));
    next.setSram(storage);
    expect(next.bus.flash.exportImage()[0], 0x17);
    final first = next.bus.maple.controllers[0]!.expansions[0]! as DcMemoryCard;
    final second =
        next.bus.maple.controllers[0]!.expansions[1]! as DcMemoryCard;
    expect(first.exportImage().sublist(21 * 512, 22 * 512),
        [for (var p = 0; p < 4; p++) ...chunk(p)]);
    expect(
        second.exportImage().sublist(22 * 512, 23 * 512), everyElement(0x42));
    expect(
        storage.keys,
        containsAll([
          'dc/sram/system_flash',
          'dc/sram/memory_card_0_0',
          'dc/sram/memory_card_0_1'
        ]));
  });











  test('LCD image and core debug layer follow documented byte and bit order',
      () {
    discover();
    final bytes = List.filled(192, 0);
    bytes[0] = 0x81; // First and eighth pixels in the first row.
    bytes[1] = 0x80; // Ninth pixel.
    bytes[5] = 1; // Top-right pixel.
    bytes[6] = 0x40; // Second pixel in the second row.
    bytes[186] = 0x80; // Bottom-left pixel.
    bytes[191] = 1; // Bottom-right pixel.
    transfer(12, [0, 0, 0, 4, 0, 0, 0, 0, ...bytes]);
    final layer = dc.videoLayers.singleWhere((l) => l.name == 'Memory card A1');
    final image = layer.capture(false).image;
    expect((image.width, image.height), (48, 32));
    final black = <int>{0, 7, 8, 47, 49, 31 * 48, 32 * 48 - 1};
    for (var i = 0; i < 48 * 32; i++) {
      expect(image.buffer[i], black.contains(i) ? 0xff000000 : 0xffffffff);
    }
    image.buffer[0] = 0;
    expect(memoryCard.lcd.image().buffer[0], 0xff000000);
    dc.attachMemoryCard(0, 0, null);
    expect(dc.videoLayers.map((l) => l.name), ['Framebuffer']);
  });

}

class _MemoryStorage extends Sram {
  final _saved = <String, Uint8List>{};
  Iterable<String> get keys => _saved.keys;
  @override
  void init(String id, Uint8List initialData) {
    if (this.id.isNotEmpty) _saved[this.id] = Uint8List.fromList(data);
    super.init(id, _saved[id] ?? initialData);
  }
}

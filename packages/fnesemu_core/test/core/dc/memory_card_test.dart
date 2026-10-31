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

  test('ordered write phases commit a block and GetLastError confirms it', () {
    discover();
    for (var phase = 0; phase < 4; phase++) {
      expect(transfer(12, params(17, phase, chunk(phase))), [7, 0, 1, 0]);
      if (phase < 3) expect(memoryCard.exportImage()[17 * 512], 255);
    }
    expect(transfer(13, params(17, 4)), [7, 0, 1, 0]);
    final read = transfer(11, params(17, 0));
    expect(read.take(12), [8, 0, 1, 130, 0, 0, 0, 2, 0, 0, 0, 17]);
    expect(read.sublist(12), [for (var p = 0; p < 4; p++) ...chunk(p)]);
    expect(transfer(13, params(17, 1)), [7, 0, 1, 0]);
    expect(memoryCard.exportImage()[16 * 512], 255);
    expect(memoryCard.exportImage()[18 * 512], 255);
  });

  test('skipped phase discards group and leaves entire block unchanged', () {
    discover();
    transfer(12, params(0, 0, chunk(0)));
    expect(transfer(12, params(0, 2, chunk(2))), [251, 0, 1, 1, 0, 0, 0, 2]);
    expect(memoryCard.exportImage().take(512), everyElement(255));
    expect(transfer(13, params(0, 3)), [251, 0, 1, 1, 0, 0, 0, 2]);
    for (var p = 0; p < 4; p++) {
      expect(transfer(12, params(0, p, chunk(p))).first, 7);
    }
    expect(transfer(13, params(0, 4)).first, 7);
  });

  test('intervening command discards a write group', () {
    discover();
    transfer(12, params(12, 0, chunk(0)));
    expect(transfer(11, params(12, 0)), [251, 0, 1, 1, 0, 0, 0, 2]);
    expect(transfer(11, params(12, 0)).sublist(12), everyElement(255));
  });

  test('partition, block, phase and length errors have documented bits', () {
    discover();
    expect(transfer(11, [0, 0, 0, 2, 1, 0, 0, 0]).last, 1);
    expect(transfer(11, params(256, 0)).last, 4);
    expect(transfer(11, params(255, 1)).last, 2);
    expect(transfer(12, params(0, 0, [1, 2, 3, 4])).last, 16);
    expect(transfer(11, [0, 0, 0, 16, 0, 0, 0, 0]).first, 254);
    expect(transfer(0x7f).first, 253);
    expect(memoryCard.exportImage(), everyElement(255));
  });

  test('changing block mid group cannot partly replace either block', () {
    discover();
    transfer(12, params(0, 0, chunk(0)));
    expect(transfer(12, params(1, 1, chunk(1))).last, 2);
    expect(memoryCard.exportImage().take(1024), everyElement(255));
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

  test('storage packets use the same canonical bytes in MSB31 mode', () {
    selection = 1;
    dc.bus.write32(base + 0xe8, 1);
    transfer(1, [], 32);
    transfer(1);
    for (var phase = 0; phase < 4; phase++) {
      expect(transfer(12, params(255, phase, chunk(phase))).first, 7);
    }
    expect(transfer(11, params(255, 0)).sublist(12),
        [for (var phase = 0; phase < 4; phase++) ...chunk(phase)]);
    expect(dc.bus.ram.getUint32LE(0x20000), 0x82010008);
  });

  test(
      'Memory card attached after setSram uses persistence without changing flash key',
      () {
    final storage = _MemoryStorage();
    dc = Dc()..setSram(storage);
    dc.attachMemoryCard(0, 0, memoryCard);
    final image = Uint8List(DcMemoryCard.size)..[1234] = 0x67;
    memoryCard.loadImage(image);
    expect(dc.bus.flash.exportImage(), everyElement(255));
    final next = Dc()..setSram(storage);
    final restored = DcMemoryCard();
    next.attachMemoryCard(0, 0, restored);
    expect(restored.exportImage()[1234], 0x67);
    expect(next.bus.flash.exportImage(), everyElement(255));
  });

  test('wrong function during write group discards all buffered phases', () {
    discover();
    transfer(12, params(0, 0, chunk(0)));
    final wrong = params(0, 1, chunk(1))..[3] = 16;
    expect(transfer(12, wrong).first, 254);
    expect(transfer(12, params(0, 1, chunk(1))).last, 2);
    expect(transfer(11, params(0, 0)).sublist(12), everyElement(255));
  });

  test('plain Sram regions retain live data across region switches', () {
    final parent = Sram();
    final first = DcStorageRegion(parent), second = DcStorageRegion(parent);
    first.init('first', Uint8List.fromList([1, 2]));
    first.write8(0, 3);
    second.init('second', Uint8List.fromList([4, 5]));
    second.write8(1, 6);
    expect(first.read8(0), 3);
    expect(second.read8(1), 6);
  });

  test('LCD reports its panel and accepts one complete horizontal-1 image', () {
    discover();
    expect(transfer(10, [0, 0, 0, 4, 0, 0, 0, 0]),
        [8, 0, 1, 2, 0, 0, 0, 4, 47, 31, 16, 0]);
    final pixels = List.generate(192, (i) => (i * 7) & 255);
    expect(transfer(12, [0, 0, 0, 4, 0, 0, 0, 0, ...pixels]), [7, 0, 1, 0]);
    final snapshot = memoryCard.lcd.exportPixels();
    expect(snapshot, pixels);
    snapshot[0] = 255;
    expect(memoryCard.lcd.exportPixels()[0], 0);
    expect(transfer(11, [0, 0, 0, 4, 0, 0, 0, 0]).first, 0xfd);
  });

  test('LCD partition, phase, plane, length and contrast errors use FT2 codes',
      () {
    discover();
    final pixels = List.filled(192, 0x69);
    expect(transfer(12, [0, 0, 0, 4, 1, 0, 0, 0, ...pixels]).last, 1);
    expect(transfer(12, [0, 0, 0, 4, 0, 1, 0, 0, ...pixels]).last, 2);
    expect(transfer(12, [0, 0, 0, 4, 0, 0, 0, 1, ...pixels]).last, 4);
    expect(transfer(12, [0, 0, 0, 4, 0, 0, 0, 0]).last, 16);
    expect(transfer(14, [0, 0, 0, 4, 0, 1, 0, 0]), [250, 0, 1, 1, 0, 0, 0, 32]);
    expect(transfer(14, [0, 0, 0, 4, 0, 255, 0, 0]),
        [8, 0, 1, 2, 0, 0, 0, 4, 0, 0, 0, 0]);
    expect(transfer(14, [0, 0, 0, 4, 0, 0, 0, 0]).first, 8);
  });

  test('storage group interruption rejects LCD once before a successful retry',
      () {
    discover();
    transfer(12, params(1, 0, chunk(0)));
    final lcd = [0, 0, 0, 4, 0, 0, 0, 0, ...List.filled(192, 0x42)];
    expect(transfer(12, lcd), [251, 0, 1, 1, 0, 0, 0, 2]);
    expect(transfer(12, lcd).first, 7);
    expect(memoryCard.lcd.exportPixels(), everyElement(0x42));
    expect(transfer(11, params(1, 0)).sublist(12), everyElement(255));
  });

  test('timer calendar read/write uses little-endian year and ignores weekday',
      () {
    discover();
    final time = [0xd0, 7, 2, 28, 23, 59, 59, 255]; // 2000, leap year.
    expect(transfer(12, [0, 0, 0, 8, 0, 0, 0, 0, ...time]), [7, 0, 1, 0]);
    expect(transfer(11, [0, 0, 0, 8, 0, 0, 0, 0]),
        [8, 0, 1, 3, 0, 0, 0, 8, ...time.take(7), 0]);
    dc.bus.write32(base + 0x14, 0);
    dc.bus.tickMasterClocks(200000000);
    expect(transfer(11, [0, 0, 0, 8, 0, 0, 0, 0]).sublist(8),
        [0xd0, 7, 2, 29, 0, 0, 0, 0]);
  });

  test('timer buttons and alarm registers are independent of stored blocks',
      () {
    discover();
    memoryCard.timer.setButton(PadButton.up, true);
    memoryCard.timer.setButton(DcMemoryCardTimer.a, true);
    expect(transfer(9, [0, 0, 0, 8]), [8, 0, 1, 2, 0, 0, 0, 8, 0xee, 0, 0, 0]);
    memoryCard.timer.setButton(PadButton.down, true);
    expect(transfer(9, [0, 0, 0, 8])[8], 0xed);
    expect(transfer(14, [0, 0, 0, 8, 10, 5, 0, 0]).first, 7);
    expect((memoryCard.timer.alarmPeriod, memoryCard.timer.alarmDuty), (10, 5));
    expect(transfer(14, [0, 0, 0, 8, 5, 6, 0, 0]).first, 0xfc);
    expect(transfer(14, [0, 0, 0, 8, 10, 5, 1, 0]).first, 0xfc);
    expect((memoryCard.timer.alarmPeriod, memoryCard.timer.alarmDuty), (10, 5));
    final date = memoryCard.timer.time;
    expect(transfer(3).first, 7);
    expect(memoryCard.timer.time, date);
    expect((memoryCard.timer.alarmPeriod, memoryCard.timer.alarmDuty), (0, 0));
    transfer(1);
    expect(transfer(9, [0, 0, 0, 8])[8], 0xed);
  });

  test('LCD and timer packets also pass through MSB31 host byte order', () {
    selection = 1;
    dc.bus.write32(base + 0xe8, 1);
    transfer(1, [], 32);
    transfer(1);
    final pixels = List.generate(192, (i) => i);
    expect(transfer(12, [0, 0, 0, 4, 0, 0, 0, 0, ...pixels]).first, 7);
    expect(memoryCard.lcd.exportPixels(), pixels);
    expect(transfer(11, [0, 0, 0, 8, 0, 0, 0, 0]).take(8),
        [8, 0, 1, 3, 0, 0, 0, 8]);
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

  test('attachment validation and port D routing', () {
    expect(() => dc.attachMemoryCard(0, 1, memoryCard), throwsArgumentError);
    expect(() => dc.attachMemoryCard(1, 0, memoryCard), throwsStateError);
    expect(() => dc.attachMemoryCard(4, 0, memoryCard), throwsRangeError);
    dc.bus.maple.controllers[3] = DcMapleController();
    dc.attachMemoryCard(3, 1, DcMemoryCard(unit: 2));
    final controller = dc.bus.maple.controllers[3]!;
    expect(controller.exchange(Uint8List.fromList([1, 0xe0, 0xc0, 0]), 3)![2],
        0xe2);
    expect(controller.exchange(Uint8List.fromList([1, 0xc2, 0xc0, 0]), 3)![2],
        0xc2);
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

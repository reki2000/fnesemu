import 'package:fnesemu_core/src/core/dc/dmac.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:test/test.dart';

void main() {
  late DcDmac dma;
  final owner = Object();
  late List<int> normal;
  setUp(() {
    normal = [];
    dma = DcDmac((source, destination, size, resource) {
      normal.add(destination);
      return true;
    });
  });
  test('DTR programs and completes channel 0 with no DMTE interrupt', () {
    expect(
        dma.requestDdt32(owner, 0x0c001000,
            write: true, transfer: (_, __) => true),
        isFalse);
    dma.write(0x40, 0x8201);
    var calls = 0;
    expect(
        dma.requestDdt32(owner, 0x0c001000, write: true,
            transfer: (address, write) {
          expect((address, write), (0x0c001000, true));
          calls++;
          return true;
        }),
        isTrue);
    expect(dma.read(4), 0x0c001000);
    expect(dma.read(8), 1);
    expect(dma.read(12), 0x853c1);
    dma.tickTransferUnits(1);
    expect(calls, 1);
    expect(dma.read(4), 0x0c001020);
    expect(dma.read(8), 0);
    expect(dma.read(12), 0x853c3);
    expect(dma.interruptPending(0), isFalse);
    expect(dma.hasDdtTransfers, isFalse);
  });
  test('memory-read DTR increments SAR and CPU cannot overwrite channel 0', () {
    dma.write(0x40, 0x8001);
    dma.requestDdt32(owner, 0x0c001000, write: false,
        transfer: (address, write) {
      expect(write, isFalse);
      return true;
    });
    for (final offset in [0, 4, 8, 12]) {
      expect(() => dma.write(offset, 0), throwsA(isA<DcUnsupported>()));
    }
    dma.tickTransferUnits(1);
    expect(dma.read(0), 0x0c001020);
    expect(dma.read(12), 0x852c3);
  });
  test(
      'request ownership, withdrawal and CPU reset cannot leave a stale callback',
      () {
    dma.write(0x40, 0x8001);
    dma.requestDdt32(owner, 0x0c001000,
        write: true, transfer: (_, __) => fail('withdrawn transfer ran'));
    expect(
        dma.requestDdt32(Object(), 0x0c002000,
            write: true, transfer: (_, __) => true),
        isFalse);
    dma.cancelDdt(Object());
    expect(dma.ownsDdtRequest(owner), isTrue);
    dma.cancelDdt(owner);
    dma.tickTransferUnits(10);
    expect(dma.read(12) & 2, 0);
    dma.requestDdt32(owner, 0x0c001000,
        write: true, transfer: (_, __) => fail('reset transfer ran'));
    dma.reset();
    dma.write(0x40, 0x8001);
    dma.tickTransferUnits(1);
    expect(dma.hasDdtTransfers, isFalse);
    expect(dma.read(12), 0);
  });
}

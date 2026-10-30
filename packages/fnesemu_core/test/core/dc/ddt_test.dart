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
  test('DME and NMI suspend an accepted DTR without consuming it', () {
    dma.write(0x40, 0x8001);
    var calls = 0;
    dma.requestDdt32(owner, 0x0c001000, write: true, transfer: (_, __) {
      calls++;
      return true;
    });
    dma.write(0x40, 0x8000);
    dma.tickTransferUnits(100);
    expect(calls, 0);
    dma.write(0x40, 0x8001);
    dma.nmi();
    dma.tickTransferUnits(100);
    expect(calls, 0);
    expect(dma.read(0x40) & 2, 2);
    dma.write(0x40, 0x8001);
    dma.tickTransferUnits(1);
    expect(calls, 1);
  });
  test('channel priority arbitrates DDT against normal channel 2', () {
    for (final priority in [0, 2]) {
      dma.reset();
      normal.clear();
      dma.write(0x20, 0x0c000000);
      dma.write(0x24, 0x0c004000);
      dma.write(0x28, 1);
      dma.write(0x2c, 0x5431);
      dma.write(0x40, 0x8001 | (priority << 8));
      var ddtCalls = 0;
      dma.requestDdt32(owner, 0x0c001000, write: true, transfer: (_, __) {
        ddtCalls++;
        return true;
      });
      dma.tickTransferUnits(1);
      expect(ddtCalls, priority == 0 ? 1 : 0);
      expect(normal.length, priority == 0 ? 0 : 1);
      dma.tickTransferUnits(1);
      expect(ddtCalls, 1);
      expect(normal, [0x0c004000]);
    }
  });
  test('failed and misaligned DDT set AE without advancing registers', () {
    dma.write(0x40, 0x8001);
    var accept = false;
    dma.requestDdt32(owner, 0x0c001000,
        write: true, transfer: (_, __) => accept);
    dma.tickTransferUnits(1);
    expect(dma.read(4), 0x0c001000);
    expect(dma.read(8), 1);
    expect(dma.read(0x40) & 4, 4);
    accept = true;
    dma.write(0x40, 0x8001);
    dma.tickTransferUnits(1);
    expect(dma.read(8), 0);
    dma.requestDdt32(owner, 0x0c001001,
        write: true,
        transfer: (_, __) => fail('unaligned transfer reached memory'));
    dma.tickTransferUnits(1);
    expect(dma.read(0x40) & 4, 4);
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

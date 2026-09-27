import 'dart:typed_data';

import 'package:fnesemu/core/pce/component/cpu_6280.dart';
import 'package:fnesemu/core/pce/component/vdc.dart';
import 'package:fnesemu/core/pce/component/vdc_render.dart';
import 'package:fnesemu/core/pce/pce.dart';
import 'package:test/test.dart';

const hardware = 0xff << 13;

Pce machine() => Pce()..reset();

void main() {
  test('VPC selects ST instructions without remapping memory ports', () {
    final pce = machine();
    pce.bus.write(hardware + 0x0e, 1);
    pce.bus.write(hardware, 5);
    expect(pce.vdc.reg, 5);
    expect(pce.vdc2.reg, 0);
    pce.cpu.regs.mprAddress[0] = 0xf8 << 13;
    pce.cpu.regs.pc = 0;
    pce.bus.write(0xf8 << 13, 7);
    pce.cpu.exec6280(0x03);
    expect(pce.vdc2.reg, 7);
    expect(pce.vdc.reg, 5);
    pce.bus.write((0xf8 << 13) + 1, 0x34);
    pce.bus.write((0xf8 << 13) + 2, 0x12);
    pce.cpu.exec6280(0x13);
    pce.cpu.exec6280(0x23);
    expect(pce.vdc2.scrollX, 0x0234);
    expect(pce.vdc.scrollX, 0);
    pce.vdc.status = Vdc.statusBusy;
    expect(pce.bus.read(hardware), Vdc.statusBusy);
  });

  test('plain PCE work RAM mirrors without aliasing CD RAM', () {
    final pce = machine();
    pce.bus.write(0xf9 << 13, 0x12);
    pce.bus.write(0x80 << 13, 0x34);
    for (final bank in [0xf8, 0xf9, 0xfa, 0xfb]) {
      expect(pce.bus.read(bank << 13), 0x12);
    }
    expect(pce.bus.read(0x80 << 13), 0x34);
  });

  test('both VDCs keep sprite and background renderer state independent', () {
    final pce = machine();
    pce.vdc.spriteBufIndex = 5;
    pce.vdc.pattern01 = 0xffff;
    pce.vdc.sprite0[0] = true;
    expect(pce.vdc2.spriteBufIndex, 0);
    expect(pce.vdc2.pattern01, 0);
    expect(pce.vdc2.sprite0[0], isFalse);
  });

  test('two VDC frame completions count as one video frame', () {
    final pce = machine();
    VdcRenderer.frames = 0;
    pce.vdc.scanLine = pce.vdc2.scanLine = 262;
    pce.vdc.exec();
    pce.vdc2.exec();
    expect(VdcRenderer.frames, 1);
  });

  test('VDC ports mirror within their eight-byte register blocks', () {
    final pce = machine();
    pce.bus.write(hardware + 4, 5);
    pce.bus.write(hardware + 0x14, 7);
    expect(pce.vdc.reg, 5);
    expect(pce.vdc2.reg, 7);
  });

  test('both VDCs execute the same scanline on SGX activation', () {
    final pce = machine();
    pce.vpc.enabled = true;
    pce.vdc.scanLine = 24;
    pce.cpu.regs.mprAddress[0] = 0xf8 << 13;
    pce.bus.write(0xf8 << 13, 0xea);
    pce.cpu.regs.pc = 0;
    pce.cpu.clocks = pce.clocksInScanline;
    pce.exec(false);
    expect(pce.vdc2.scanLine, pce.vdc.scanLine);
    expect(pce.vdc2.displayLine, pce.vdc.displayLine);
  });

  test('VDC IRQ enters the PIC and respects IRQ1 masking', () {
    final pce = machine();
    pce.pic.mask = 2;
    pce.vdc.enableVBlank = true;
    pce.vdc.scanLine = 260;
    pce.vdc.exec();
    expect(pce.pic.hold & 2, 2);
    expect(pce.cpu.holdIrq1, isFalse);
    pce.pic.mask = 0;
    expect(pce.cpu.holdIrq1, isTrue);
  });

  test('reading one VDC status preserves the other VDC IRQ', () {
    final pce = machine();
    pce.vpc.enabled = true;
    for (final vdc in [pce.vdc, pce.vdc2]) {
      vdc.enableVBlank = true;
      vdc.scanLine = 260;
      vdc.exec();
    }
    expect(pce.vdc.readReg() & Vdc.statusVBlank, Vdc.statusVBlank);
    expect(pce.cpu.holdIrq1, isTrue);
    expect(pce.pic.hold & 2, 2);
    pce.vdc2.readReg();
    expect(pce.cpu.holdIrq1, isFalse);
    expect(pce.pic.hold & 2, 0);
  });

  test('renderer reset clears per-VDC sprite fetch state', () {
    final pce = machine();
    pce.vdc.spriteBufIndex = 8;
    pce.vdc.displayLine = 200;
    pce.vdc.sprite0.fillRange(0, 32, true);
    pce.vdc.reset();
    expect(pce.vdc.spriteBufIndex, 0);
    expect(pce.vdc.displayLine, 0);
    expect(pce.vdc.sprite0, everyElement(isFalse));
  });

  test('mode 2 preserves a sprite over transparent second-VDC background', () {
    final pce = machine();
    pce.vdc.hSize = pce.vdc2.hSize = 1;
    pce.vdc.indexBuffer = Uint16List.fromList([0x101]);
    pce.vdc2.indexBuffer = Uint16List.fromList([0]);
    pce.vdc.colorTable[0] = 0;
    pce.vdc.colorTable[0x101] = 7;
    pce.vpc.enabled = true;
    pce.vpc.priority1 = 0xb0;
    pce.vpc.render(pce.vdc, pce.vdc2);
    expect(pce.vpc.frameBuffer.single, rgba[7]);
  });

  test('transparent sprite palette entries do not occlude another VDC', () {
    final pce = machine();
    pce.vdc.hSize = pce.vdc2.hSize = 1;
    pce.vdc.indexBuffer = Uint16List.fromList([0x110]);
    pce.vdc2.indexBuffer = Uint16List.fromList([1]);
    pce.vdc.colorTable[1] = 7;
    pce.vdc.colorTable[0x110] = 0;
    pce.vpc.enabled = true;
    pce.vpc.priority1 = 0x70;
    pce.vpc.render(pce.vdc, pce.vdc2);
    expect(pce.vpc.frameBuffer.single, rgba[7]);
  });

  test('second-VDC debug overlay is handled before palette lookup', () {
    final pce = machine();
    pce.vdc.hSize = pce.vdc2.hSize = 1;
    pce.vdc.indexBuffer = Uint16List.fromList([0]);
    pce.vdc2.indexBuffer = Uint16List.fromList([0xffff]);
    pce.vpc.enabled = true;
    pce.vpc.priority1 = 0x20;
    pce.vpc.render(pce.vdc, pce.vdc2);
    expect(pce.vpc.frameBuffer.single, 0xffffffff);
  });
}

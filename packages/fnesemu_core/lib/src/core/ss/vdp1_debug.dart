part of 'vdp1.dart';

extension Vdp1VideoDebug on Vdp1 {
  int debugReadWord(int address) => _r16(address);

  /// Rebuild on independent storage; draw-end notifications stay on the copy.
  Vdp1 debugSnapshot() {
    final copy = Vdp1();
    copy.vram.setAll(0, vram);
    copy.tvmr = tvmr;
    copy.fbcr = fbcr;
    copy.ewdr = ewdr;
    copy.ewlr = ewlr;
    copy.ewrr = ewrr;
    copy._sysClipX = Vdp1.fbWidth - 1;
    copy._sysClipY = Vdp1.fbHeight - 1;
    copy._erase(copy.drawFb);
    copy._draw();
    copy.displayFb.setAll(0, copy.drawFb);
    return copy;
  }

  /// Walk the same jump/call/return command links without executing commands.
  List<(int, int, int, int)> debugCommands() {
    final result = <(int, int, int, int)>[];
    var address = 0, ret = -1, localX = 0, localY = 0;
    final visited = <(int, int)>{};
    for (var i = 0; i < 20000; i++) {
      address &= 0x7ffff;
      if (!visited.add((address, ret))) break;
      final control = _r16(address);
      if (control.bit15) break;
      if (!control.bit14) {
        if (control.mask4 == 10) {
          localX = _r16(address + 12).rel11;
          localY = _r16(address + 14).rel11;
        }
        result.add((address, control, localX, localY));
      }
      final link = _r16(address + 2) << 3;
      switch (control.shr12.mask2) {
        case 0:
          address += 32;
        case 1:
          address = link;
        case 2:
          if (ret < 0) ret = address + 32;
          address = link;
        case 3:
          if (ret >= 0) {
            address = ret;
            ret = -1;
          } else {
            address += 32;
          }
      }
    }
    return result;
  }

  List<DebugOutline> debugSpriteOutlines() => [
        for (final command in debugCommands())
          if (command.$2.mask4 <= 3) _debugSpriteOutline(command),
      ];
  DebugOutline _debugSpriteOutline((int, int, int, int) command) {
    final (addr, control, lx, ly) = command;
    final width = _r16(addr + 10).shr8.mask6 * 8,
        height = _r16(addr + 10).mask8;
    final xa = _r16(addr + 12).rel11 + lx, ya = _r16(addr + 14).rel11 + ly;
    final xb = _r16(addr + 16).rel11 + lx, yb = _r16(addr + 18).rel11 + ly;
    final xc = _r16(addr + 20).rel11 + lx, yc = _r16(addr + 22).rel11 + ly;
    final xd = _r16(addr + 24).rel11 + lx, yd = _r16(addr + 26).rel11 + ly;
    final label = _r16(addr + 8).toRadixString(16).toUpperCase();
    if (control.mask4 == 0) {
      return DebugOutline.rect(xa, ya, width, height, label: label);
    }
    if (control.mask4 == 1) {
      final zoom = control.shr8.mask4;
      if (zoom == 0) {
        return DebugOutline.rect(xa, ya, xc - xa + 1, yc - ya + 1,
            label: label);
      }
      final w = _r16(addr + 16).rel11, h = _r16(addr + 18).rel11;
      final anchorX = (zoom & 3) == 2
          ? w ~/ 2
          : (zoom & 3) == 3
              ? w
              : 0;
      final anchorY = (zoom >> 2) == 2
          ? h ~/ 2
          : (zoom >> 2) == 3
              ? h
              : 0;
      return DebugOutline.rect(xa - anchorX, ya - anchorY, w + 1, h + 1,
          label: label);
    }
    return DebugOutline([
      (xa.toDouble(), ya.toDouble()),
      (xb.toDouble(), yb.toDouble()),
      (xc.toDouble(), yc.toDouble()),
      (xd.toDouble(), yd.toDouble())
    ], label: label);
  }
}

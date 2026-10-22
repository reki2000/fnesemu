import 'dart:io';

import 'package:fnesemu_core/src/core.dart';
import 'package:fnesemu_core/src/core/snes/component/ppu_render.dart';
import 'package:fnesemu_core/src/core/snes/snes.dart';

import 'session.dart';

/// writes the debugger views of [core] into [dir]: bg.png, vram.png,
/// colors.png and sprites.txt (the views a core does not have are skipped),
/// and for snes also the state of the ppu and the dma, the vram and each
/// enabled layer alone
void writeDebugViews(Core core, String dir) {
  savePng(core.renderBg(), "$dir/bg.png");
  savePng(core.renderVram(false, 0), "$dir/vram.png");
  savePng(core.renderColorTable(0), "$dir/colors.png");
  final sprites = core.spriteInfo();
  if (sprites.isNotEmpty) {
    File("$dir/sprites.txt").writeAsStringSync("${sprites.join("\n")}\n");
  }
  if (core is Snes) _writeSnes(core, dir);
}

void _writeSnes(Snes core, String dir) {
  final ppu = core.ppu;
  File("$dir/snes.txt").writeAsStringSync([
    "mode=${ppu.bgMode} blank=${ppu.forcedBlank} "
        "layers=${ppu.mainScreenEnable.toRadixString(16)} "
        "maps=${ppu.bgs.map((bg) => bg.tilemapAddr.toRadixString(16)).join(",")}",
    "BG: ${ppu.bgs.map((bg) => "(${bg.hofs},${bg.vofs}) ${bg.charBase.toRadixString(16)} ${bg.wideX}/${bg.wideY} big=${bg.bigChar}").join(" ")}",
    "HDMA: ${core.dma.hdmaEnableMask.toRadixString(16)} ${core.dma.channels.map((c) => "${c.bbad.toRadixString(16)}:${c.dmap.toRadixString(16)}:${c.a1tAddr.toRadixString(16)}").join(" ")}",
    "windows: ${ppu.w12sel.toRadixString(16)} tmw=${ppu.tmw.toRadixString(16)} ${ppu.w1Left}-${ppu.w1Right} ${ppu.w2Left}-${ppu.w2Right}",
    "OBJ: size=${ppu.objSizeSel} base=${ppu.objBase} gap=${ppu.objGap}",
    for (var i = 0; i < 128; i++)
      if (ppu.oam[i * 4 + 1] < 224 || ppu.oam[i * 4 + 1] >= 0xf0)
        "  $i: x=${ppu.oam[i * 4] | ((ppu.oam[512 + i ~/ 4] >> (i % 4 * 2)) & 1) << 8} y=${ppu.oam[i * 4 + 1]} tile=${ppu.oam[i * 4 + 2].toRadixString(16)} attr=${ppu.oam[i * 4 + 3].toRadixString(16)} large=${(ppu.oam[512 + i ~/ 4] >> (i % 4 * 2 + 1)) & 1}",
    "",
  ].join("\n"));
  File("$dir/vram.bin").writeAsBytesSync(ppu.vram);
  // renders the frame again with one layer at a time
  final enabled = ppu.mainScreenEnable;
  for (var layer = 0; layer < 5; layer++) {
    if (enabled & (1 << layer) == 0) continue;
    ppu.mainScreenEnable = 1 << layer;
    for (var line = 1; line <= 224; line++) {
      ppu.renderScanline(line);
    }
    savePng(core.imageBuffer(), "$dir/layer$layer.png");
  }
  ppu.mainScreenEnable = enabled;
}

import 'package:flutter/material.dart';
import 'package:fnesemu/gui/debug/disasm.dart';

import '../nes_controller.dart';
import 'vram.dart';

class DebugController extends StatelessWidget {
  final NesController controller;

  const DebugController({Key? key, required this.controller}) : super(key: key);

  Widget _button(String text, void Function() func) => Container(
      margin:
          const EdgeInsets.only(top: 5.0, bottom: 5.0, left: 2.0, right: 2.0),
      child: ElevatedButton(child: Text(text), onPressed: func));

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _button("Step", controller.runStep),
      _button("Line", controller.runScanLine),
      _button("Frame", controller.runFrame),
      SizedBox(width: 50, child: TextField(onChanged: (v) {})),
      _button("Disasm", () => pushDisasmPage(context, controller)),
      _button("VRAM", () => pushVramPage(context, controller)),
      _button("Log", () => {}),
    ]);
  }
}

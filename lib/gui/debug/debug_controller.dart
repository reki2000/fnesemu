// Dart imports:
// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../nes_controller.dart';
import 'disasm.dart';
import 'mem.dart';
import 'vdc.dart';
import 'vram.dart';

class DebugController extends StatelessWidget {
  final NesController controller;

  const DebugController({super.key, required this.controller});

  Widget _button(String text, void Function() func) => Container(
      margin:
          const EdgeInsets.only(top: 5.0, bottom: 5.0, left: 2.0, right: 2.0),
      child: TextButton(onPressed: func, child: Text(text)));

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _button("Step", controller.runStep),
      _button("Line", controller.runScanLine),
      _button("Frame", controller.runFrame),
      _button("Rts", controller.runUntilRts),
      SizedBox(
          width: 50,
          child: TextField(onChanged: (v) {
            if (v.length == 4) {
              try {
                final breakPoint = int.parse(v, radix: 16);
                controller.debugOption =
                    controller.debugOption.copyWith(breakPoint: breakPoint);
              } catch (e) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(e.toString())));
              }
            }
          })),
      _button("Disasm", () => pushDisasmPage(context, controller)),
      _button("Mem", () => pushMemPage(context, controller)),
      _button("VRAM", () => pushVramPage(context, controller)),
      _button("VDC", () => pushVdcPage(context, controller)),
      _button("Log", () {
        final currentOn = controller.debugOption.log;
        controller.debugOption =
            controller.debugOption.copyWith(log: !currentOn);
      }),
    ]);
  }
}

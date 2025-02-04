// Dart imports:
// Flutter imports:
import 'package:flutter/material.dart';
import 'package:fnesemu/util/int.dart';

import '../../core/core_controller.dart';
import 'vram.dart';

class DebugController extends StatelessWidget {
  final CoreController controller;

  const DebugController({super.key, required this.controller});

  Widget _button(String text, void Function() func) => Container(
      margin:
          const EdgeInsets.only(top: 5.0, bottom: 5.0, left: 2.0, right: 2.0),
      child: TextButton(onPressed: func, child: Text(text)));

  @override
  Widget build(BuildContext context) {
    final debugger = controller.debugger;
    final debugOption = debugger.opt;

    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _button("Step", controller.runStep),
      _button("Next", () {
        debugOption.breakPoint[0] = debugger.nextPc(debugOption.targetCpuNo);
        controller.run();
      }),
      _button("Line", controller.runScanLine),
      _button("Frame", controller.runFrame),
      SizedBox(
          width: 50,
          child: TextField(onChanged: (v) {
            if (v.length == 4) {
              try {
                final breakPoint = int.parse(v, radix: 16);
                debugOption.breakPoint[0] = breakPoint;
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("breakpoint: ${breakPoint.hex16}")));
              } catch (e) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(e.toString())));
              }
            }
          })),
      _button("Mem", () => debugger.toggleMem()),
      _button("VRAM", () => pushVramPage(context, controller)),
      _button("VDC", () => debugger.toggleVdc()),
      _button("Log", () => debugger.toggleLog()),
    ]);
  }
}

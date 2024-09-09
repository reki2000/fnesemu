// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../../styles.dart';
import '../../util.dart';
import '../nes_controller.dart';

// get 40 lines of disassemble string
_asm(int addr, NesController controller) => range(0, 40)
    .fold(Pair([""], addr), (a, _) {
      final asm = controller.disasm(a.i1);
      return Pair(a.i0..add(asm.i0), a.i1 + asm.i1);
    })
    .i0
    .join("\n");

void pushDisasmPage(BuildContext context, NesController controller) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (BuildContext context) {
      const margin10 = EdgeInsets.all(10.0);
      final node = FocusNode();
      node.requestFocus;

      final addrNotifier = ValueNotifier<int>(0);

      return Scaffold(
          appBar: AppBar(title: const Text('DisAseembler')),
          body: Container(
              margin: margin10,
              alignment: Alignment.topLeft,
              child: Focus(
                focusNode: node,
                child: Column(children: [
                  ValueListenableBuilder<int>(
                      valueListenable: addrNotifier,
                      builder: (context, addr, child) => SelectableText(
                            _asm(addr, controller),
                            style: debugStyle,
                            showCursor: true,
                          )),
                  Row(children: [
                    SizedBox(
                        width: 50,
                        child: TextField(onChanged: (v) {
                          if (v.length == 4) {
                            addrNotifier.value = int.parse(v, radix: 16);
                          }
                        })),
                    ElevatedButton(
                        child: const Text("--"),
                        onPressed: () => addrNotifier.value =
                            (addrNotifier.value - 0x400) & 0xffff),
                    ElevatedButton(
                        child: const Text("-"),
                        onPressed: () => addrNotifier.value =
                            (addrNotifier.value - 0x20) & 0xffff),
                    ElevatedButton(
                        child: const Text("+"),
                        onPressed: () => addrNotifier.value += 0x20),
                    ElevatedButton(
                        child: const Text("++"),
                        onPressed: () => addrNotifier.value += 0x400),
                  ]),
                ]),
              )));
    }),
  );
}

// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../../styles.dart';
import '../../util.dart';
import 'debugger.dart';

// get 40 lines of disassemble string

class DebugDisasm extends StatelessWidget {
  final Debugger debugger;
  final addrNotifier = ValueNotifier<int>(0);

  DebugDisasm({super.key, required this.debugger}) {
    addrNotifier.value = debugger.debugOption.disasmAddress;
  }

  final margin10 = const EdgeInsets.all(10.0);
  final node = FocusNode();

  _asm(int addr) => range(0, 50)
      .fold(Pair([""], addr), (a, _) {
        final asm = debugger.disasm(a.i1);
        return Pair(a.i0..add(asm.i0), a.i1 + asm.i1);
      })
      .i0
      .join("\n");

  @override
  Widget build(BuildContext context) {
    node.requestFocus;
    return Container(
        margin: margin10,
        alignment: Alignment.topLeft,
        child: Focus(
          focusNode: node,
          child: Column(children: [
            Row(children: [
              SizedBox(
                  width: 50,
                  child: TextField(onChanged: (v) {
                    if (v.length == 4) {
                      addrNotifier.value = int.parse(v, radix: 16);
                    }
                  })),
              TextButton(
                  child: const Text("--"),
                  onPressed: () => addrNotifier.value =
                      (addrNotifier.value - 0x400) & 0xffff),
              TextButton(
                  child: const Text("-"),
                  onPressed: () => addrNotifier.value =
                      (addrNotifier.value - 0x20) & 0xffff),
              TextButton(
                  child: const Text("+"),
                  onPressed: () => addrNotifier.value += 0x20),
              TextButton(
                  child: const Text("++"),
                  onPressed: () => addrNotifier.value += 0x400),
            ]),
            ValueListenableBuilder<int>(
                valueListenable: addrNotifier,
                builder: (context, addr, child) => SelectableText(
                      _asm(addr),
                      style: debugStyle,
                      showCursor: true,
                    )),
          ]),
        ));
  }
}

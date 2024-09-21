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

  List<Pair<int, String>> _asm(int addr, int lines) {
    final result = List<Pair<int, String>>.empty(growable: true);

    for (int i = 0; i < lines; i++) {
      final asm = debugger.disasm(addr);
      result.add(Pair(addr, asm.i0));
      addr += asm.i1;
    }

    return result;
  }

  // To show backward lines correctly, we need to start from earlier address and succesding to the current address
  List<Pair<int, String>> _backward(int addr, int lines) {
    final result = List.filled(lines, Pair(0, ""), growable: true);

    var current = addr - lines * 6;
    while (current < addr) {
      final asm = debugger.disasm(current);
      result.add(Pair(current, asm.i0));
      current += asm.i1;
    }

    return result.sublist(result.length - lines);
  }

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
                      (_backward(addr, 5)..addAll(_asm(addr, 40)))
                          .map((s) => (s.i0 == addr ? "=>" : "  ") + s.i1)
                          .join("\n"),
                      style: debugStyle,
                      showCursor: true,
                    )),
          ]),
        ));
  }
}

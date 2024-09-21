import 'package:flutter/material.dart';

import 'debugger.dart';
import 'disasm.dart';
import 'vdc.dart';

class DebugPane extends StatelessWidget {
  final Debugger debugger;

  const DebugPane({super.key, required this.debugger});

  @override
  Widget build(BuildContext context) => StreamBuilder(
      stream: debugger.debugStream,
      builder: (context, snapshot) {
        if (snapshot.data?.showDebugView ?? false) {
          return Row(children: [
            if (snapshot.data?.showDisasm ?? false)
              DebugDisasm(debugger: debugger),
            if (snapshot.data?.showVdc ?? false) DebugVdc(debugger: debugger),
          ]);
        } else {
          return Container();
        }
      });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/debugger.dart';
import '../../styles.dart';
import 'disasm.dart';
import 'mem.dart';
import 'vdc.dart';

class DebugPane extends StatelessWidget {
  final Debugger debugger;

  const DebugPane({super.key, required this.debugger});

  @override
  Widget build(BuildContext context) => StreamBuilder(
      stream: debugger.debugStream,
      builder: (context, snapshot) {
        final opt = snapshot.data;
        if (opt == null || !opt.showDebugView) {
          return Container();
        }

        return Row(children: [
          if (opt.showDisasm)
            Column(children: [
              for (int cpuNo = 0; cpuNo < debugger.cpuInfos.length; cpuNo++)
                DebugDisasm(
                  debugger: debugger,
                  cpuNo: cpuNo,
                  forwardLines: 46 ~/ debugger.cpuInfos.length - 4,
                  backwardLines: 3,
                  width: 300,
                  addrBits: debugger.cpuInfos[cpuNo].addrBits,
                ),
            ]),
          if (opt.showMem) MemPane(debugger: debugger),
          if (opt.showVdc) DebugVdc(debugger: debugger),
          if (opt.log) TracePanel(log: debugger.log),
        ]);
      });
}

class TracePanel extends StatelessWidget {
  final List<String> log;

  const TracePanel({super.key, required this.log});

  copyToClipboard(BuildContext context) async {
    final data = ClipboardData(text: (["# trace"] + log).join("\n"));
    await Clipboard.setData(data);

    if (!context.mounted) return;
    const snackBar = SnackBar(content: Text("Copied to clipboard"));
    ScaffoldMessenger.of(context).showSnackBar(snackBar);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.topLeft,
      child: Column(children: [
        TextButton(
            child: const Text("Copy"),
            onPressed: () => copyToClipboard(context)),
        TextButton(child: const Text("Clear"), onPressed: () => log.clear()),
        Text("${log.length}", style: debugStyle),
      ]),
    );
  }
}

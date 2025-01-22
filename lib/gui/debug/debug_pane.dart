import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/debugger.dart';
import '../../styles.dart';
import 'disasm.dart';
import 'vdc.dart';

class DebugPane extends StatelessWidget {
  final Debugger debugger;

  const DebugPane({super.key, required this.debugger});

  @override
  Widget build(BuildContext context) => StreamBuilder(
      stream: debugger.debugStream,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data?.showDebugView ?? false) {
          return Row(children: [
            if (data?.showDisasm ?? false)
              for (int cpuNo = 0; cpuNo < debugger.cpuInfos.length; cpuNo++)
                DebugDisasm(debugger: debugger, cpuNo: cpuNo),
            if (data?.showVdc ?? false) DebugVdc(debugger: debugger),
            if (data?.log ?? false) TracePanel(log: debugger.log),
          ]);
        } else {
          return Container();
        }
      });
}

class TracePanel extends StatelessWidget {
  final List<String> log;

  const TracePanel({super.key, required this.log});

  copyToClipboard(BuildContext context) async {
    final data = ClipboardData(text: log.join("\n"));
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
          Row(children: [
            TextButton(
                child: const Text("Clear"), onPressed: () => log.clear()),
            TextButton(
                child: const Text("Copy"),
                onPressed: () => copyToClipboard(context)),
          ]),
          Flexible(
              child: SizedBox(
            width: 1200,
            child: ListView.builder(
              itemCount: log.length,
              itemBuilder: (context, index) =>
                  Text(log[index], style: debugStyle),
            ),
          )),
        ]));
  }
}

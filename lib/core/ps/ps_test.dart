import 'dart:async';
import 'dart:io';

import 'package:fnesemu/core/tracer.dart';
import 'package:fnesemu/core/types.dart';

import '../../disc/loader.dart';
import 'ps.dart';

int runSeconds = 10; // run for this many seconds
int traceAddress = -1; // start logging from this address
int traceCycleStart = -1; // start logging from this cycle
int traceCycleEnd = -1; // end logging at this cycle

Ps core = Ps();

TraceLogger logger = TraceLogger(); // start logging from this address

// simple logger that logs CPU state to a file
class TraceLogger {
  final _traceStream = StreamController<String>();
  StreamSubscription<String>? _traceSubscription;
  Tracer? _tracer;
  File? _logFile;

  List<int> callStack = List.of(<int>[]);
  String _indent = "";

  void init(String fileName, CpuInfo cpuInfo, int addr) {
    _logFile = File(fileName);

    // Clear the trace.log file at the beginning
    _logFile?.writeAsStringSync("", mode: FileMode.write);

    _tracer = Tracer(_traceStream, size: 100, maxDiffChars: cpuInfo.traceDiffs);

    _traceSubscription = _traceStream.stream.listen((log) {
      _logFile?.writeAsStringSync("${log.replaceAll("\n", "")}\n",
          mode: FileMode.append);
    },
        onDone: () => {
              _traceSubscription?.cancel(),
            });
  }

  void log(int pc, TraceLog Function() getTrace) {
    final t = getTrace();
    final t2 = TraceLog(t.pc, t.cycle, "$_indent${t.disasm}", t.regs, t.state);
    _indent = "|" * callStack.length; // delay indent change to next log line

    // Adjust indent for function calls/returns
    final op = t.disasm.substring(19, 25);
    if (op.startsWith("jal ") || op.startsWith("jalr ")) {
      // function call
      callStack.add(t.pc + 8);
    } else if (op.startsWith("jr ") &&
        callStack.isNotEmpty &&
        extractToReg(op, t.regs) == callStack.last) {
      // return from function
      callStack.removeLast();
    } else if (t.pc == 0x00000080 || t.pc == 0x80000080) {
      // enter exception
      callStack.add(extractEpc(t.regs));
    } else if (op.startsWith("rfe") && callStack.isNotEmpty) {
      // return from exception
      callStack.removeLast();
    }

    _tracer?.addTraceLog(t2);
  }

  static int extractToReg(String op, String regs) {
    // op   jr r31
    // regs r00:00000000 800a0000 00000000 94639271 r04:00000000 00000000 00000010 800f1638 r08:0007ffe0 00000000 800a2100 00000000 r12:00000001 00000000 00000000 00000000 r16:00000010 00000010 8009d3c8 00000000 r20:00000000 00000000 00000000 00000000 r24:00000001 00000000 800ddc74 00000f1c r28:8009dca8 801ffef0 801fffe8 8002d324 pc:8002d324 hi:0007ffe0 lo:0006ffe4 sr:40000401 cause:00000000 epc:800ddc74
    final toRegNo = int.parse(op.substring(4).trim());
    final toRegPos = 9 * (toRegNo % 4) + 40 * (toRegNo ~/ 4) + 4;
    final toAddr = int.parse(regs.substring(toRegPos, toRegPos + 8), radix: 16);
    return toAddr;
  }

  static int extractEpc(String regs) {
    final epcPos = regs.indexOf("epc:") + 4;
    final epc = int.parse(regs.substring(epcPos, epcPos + 8), radix: 16);
    return epc;
  }
}

List<String> handleOptions(List<String> args) {
  if (args.length < 2) {
    print(
      "Usage: dart ps_test.dart [-n runSeconds] [-ta traceStartAddress] [-tc traceCycleStart-traceCycleEnd] <bios file> <disc file> [<exe file>]",
    );
    return [];
  }

  while (true) {
    if (args[0] == "-n") {
      runSeconds = int.parse(args[1]);
      args = args.sublist(2);
      continue;
    }

    if (args[0] == "-ta") {
      traceAddress = int.parse(args[1], radix: 16);
      args = args.sublist(2);
      continue;
    }

    if (args[0] == "-tc") {
      final parts = args[1].split("-");
      traceCycleStart = int.parse(parts[0]);
      if (parts.length > 1 && parts[1].isNotEmpty) {
        traceCycleEnd = int.parse(parts[1]);
      }
      args = args.sublist(2);
      continue;
    }

    // Initialize logger only if tracing is enabled
    if (traceAddress >= 0 || traceCycleStart >= 0) {
      logger.init("trace.log", core.cpuInfos[0], traceAddress);
    }

    break;
  }

  return args;
}

main(List<String> args) async {
  args = handleOptions(args);

  if (args.isEmpty) {
    return;
  }

  final bios = File(args[0]).readAsBytesSync();
  core.setRom(bios);

  final disc = DiscLoader.load(args[1]);

  core.setDisc(disc);

  core.reset();

  if (false) {
    // fast boot
    final systemCnf =
        String.fromCharCodes(disc.loadIso9660File("SYSTEM.CNF;1"));
    print("debug: SYSTEM.CNF content:\n$systemCnf");
    final bootFileName = systemCnf
        .split("\n")
        .firstWhere(
          (line) => line.startsWith("BOOT = cdrom:\\"),
          orElse: () => "BOOT = cdrom:\\",
        )
        .substring(14)
        .trim();
    if (bootFileName.isEmpty) {
      print("debug: BOOT file not found in SYSTEM.CNF");
    } else {
      print("debug: boot file $bootFileName");
      final boot = disc.loadIso9660File(bootFileName);
      core.setRom(boot);
    }
  }

  if (args.length > 2) {
    final exe = File(args[2]).readAsBytesSync();
    core.setRom(exe);
  }

  bool afterTraceAddress = false;

  for (int i = 0; i < core.systemClockHz * runSeconds; i++) {
    if (!afterTraceAddress &&
        traceAddress >= 0 &&
        core.programCounter(0) == traceAddress) {
      afterTraceAddress = true;
      print("debug: start logging at pc: 0x${traceAddress.toRadixString(16)}");
    }

    core.exec(false);

    final inTraceCycleRange = traceCycleStart >= 0 &&
        core.cpu.clocks >= traceCycleStart &&
        (traceCycleEnd < 0 || core.cpu.clocks <= traceCycleEnd);

    if (afterTraceAddress || inTraceCycleRange) {
      logger.log(core.programCounter(0), () => core.trace(0));
    }

    // Yield to event loop every N iterations
    if (i % 1000 == 0) {
      await Future.delayed(Duration.zero);
    }
  }

  print(core.cpu.dump());
  print(core.cdrom.dump());
}

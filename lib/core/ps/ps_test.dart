import 'dart:async';
import 'dart:io';

import 'package:fnesemu/core/tracer.dart';
import 'package:fnesemu/core/types.dart';

import '../../disc/loader.dart';
import 'ps.dart';

int runSeconds = 10; // run for this many seconds

Ps core = Ps();

TraceLogger logger = TraceLogger(); // start logging from this address

// simple logger that logs CPU state to a file
class TraceLogger {
  bool _enabled = false; // true when logging option is enabled
  bool _started = false; // true when logging has started
  int _startAddress = 0;

  final _traceStream = StreamController<String>();
  StreamSubscription<String>? _traceSubscription;
  Tracer? _tracer;
  File? _logFile;

  int _indent = 0;
  int _nextIndent = 0;

  void init(String fileName, CpuInfo cpuInfo, int addr) {
    _logFile = File(fileName);
    _enabled = true;
    _startAddress = addr;

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
    if (!_enabled) return;

    if (!_started) {
      _started = pc == _startAddress;
      if (_started) {
        print("debug: start logging at 0x${pc.toRadixString(16)}");
      }
    }

    if (_started) {
      final t = getTrace();
      final t2 = TraceLog(
          t.pc, t.cycle, "${"|" * _indent}${t.disasm}", t.regs, t.state);
      _indent = _nextIndent; // delay indent change to next log line

      // Adjust indent for function calls/returns
      if (t.disasm.substring(19, 22) == "jal" && _nextIndent < 20) {
        _nextIndent++;
      } else if (t.disasm.substring(19, 25) == "jr r31" && _nextIndent > 0) {
        _nextIndent--;
      }

      _tracer?.addTraceLog(t2);
    }
  }
}

List<String> handleOptions(List<String> args) {
  if (args.length < 2) {
    print(
      "Usage: dart ps_test.dart [-n runSeconds] <bios file> <disc file> [<exe file>]",
    );
    return [];
  }

  while (true) {
    if (args[0] == "-n") {
      runSeconds = int.parse(args[1]);
      args = args.sublist(2);
    }

    if (args[0] == "-t") {
      logger.init("trace.log", core.cpuInfos[0], int.parse(args[1], radix: 16));
      args = args.sublist(2);
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
  core.reset();

  final disc = DiscLoader.load(args[1]);
  core.onReadDisc(disc.read);

  if (args.length > 2) {
    final exe = File(args[2]).readAsBytesSync();
    core.setRom(exe);
  }

  for (int i = 0; i < core.systemClockHz * 10; i++) {
    core.exec(false);
    logger.log(core.programCounter(0), () => core.trace(0));
    // Yield to event loop every N iterations
    if (i % 1000 == 0) {
      await Future.delayed(Duration.zero);
    }
  }
}

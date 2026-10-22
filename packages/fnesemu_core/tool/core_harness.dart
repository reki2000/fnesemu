// headless harness of the cores: runs a core with its media and input, and
// writes the screen and the audio, serves stepwise control over HTTP, times
// frames or records the instructions through the tracer of the debugger
//
// usage: dart run tool/core_harness.dart <command> <core> <media...> [options]
// commands: run, serve, bench, trace, buttons, check-input (see usage below)
import 'dart:convert';
import 'dart:io';

import 'harness/bench.dart';
import 'harness/options.dart';
import 'harness/run.dart';
import 'harness/serve.dart';
import 'harness/session.dart';
import 'harness/trace.dart';
import 'input_sequence.dart';
import 'logging.dart';

const _usage = """
usage: core_harness <command> <core> <media...> [options]

the options of the commands that run a core:
$mediaUsage

$runUsage

$serveUsage

$benchUsage

$traceUsage

buttons <core>: prints the button names as JSON
check-input <core> --input SEQ: prints the presses of SEQ as JSON
  (both ignore the media and the other options)""";

Future<void> main(List<String> args) async {
  configureLogging();
  if (args.isEmpty || args.first == "-h" || args.first == "--help") {
    stdout.writeln(_usage);
    exit(args.isEmpty ? 64 : 0);
  }
  final rest = args.sublist(1);
  try {
    switch (args.first) {
      case "run":
        await run(rest);
      case "serve":
        await serve(rest);
      case "bench":
        await bench(rest);
      case "trace":
        await trace(rest);
      case "buttons":
        final o = _anyOptions(rest);
        stdout.writeln(jsonEncode(buttonNames(createCore(o.positional.first))));
      case "check-input":
        final o = _anyOptions(rest);
        final buttons = buttonNames(createCore(o.positional.first));
        stdout.writeln(pressesJson(readPresses(o["--input"], buttons), buttons));
      default:
        throw UsageError("unknown command: ${args.first}");
    }
  } on UsageError catch (e) {
    stderr.writeln("$e\n\n$_usage");
    exit(64);
  }
}

/// the options of buttons and check-input, which only need the core name
Options _anyOptions(List<String> args) {
  final o = Options.parse(args,
      valued: {...mediaValued},
      flags: mediaFlags,
      aliases: mediaAliases);
  if (o.positional.isEmpty) throw UsageError("the core");
  return o;
}

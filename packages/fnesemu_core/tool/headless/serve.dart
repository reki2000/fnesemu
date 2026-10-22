import 'dart:convert';
import 'dart:io';

import '../input_sequence.dart';
import 'options.dart';
import 'session.dart';

const serveUsage = """
serve <core> <media...> [--port P]: waits for HTTP GET requests on 127.0.0.1:P
  (0 picks a port; the answers are JSON and the frame counter starts at 0)
  /run?frames=N[&every=E&dir=D]  runs N frames; with every, saves D/frame_NNNNN.png
                                 at the frames that are multiples of E
  /press?seq=S                   adds the presses of the input sequence S, read with
                                 the cursor at the next frame; answers the presses
                                 and the cursor at the end
  /shot?path=P                   saves the current screen as a png
  /audio?path=P                  saves the audio since the previous /audio as a wav
  /state                         the frame, the program counter and the core dump
  /buttons                       the button names
  /quit                          stops the server""";

Future<void> serve(List<String> args) async {
  final o = Options.parse(args,
      valued: {...mediaValued, "--port"},
      flags: mediaFlags,
      aliases: mediaAliases);
  final (name, files) = coreAndFiles(o);
  final s = await Session.open(name, files, o);
  final core = s.core;
  var audioFrom = 0;

  final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4, o.integer("--port", 0));
  stdout.writeln("serving on 127.0.0.1:${server.port}");

  // answers the requests one at a time until /quit; an error is answered
  // with status 400
  Future<Map<String, Object?>?> handle(String path, Map<String, String> q) async {
    switch (path) {
      case "/run":
        final n = int.parse(q["frames"] ?? "1");
        final step = int.tryParse(q["every"] ?? "");
        final dir = q["dir"];
        if (step != null) {
          if (dir == null) throw "every needs dir";
          Directory(dir).createSync(recursive: true);
        }
        for (var i = 0; i < n; i++) {
          if (!await s.stepFrame()) {
            return {"frame": s.frame, "stopped": true, "dump": core.dump()};
          }
          if (step != null && s.frame % step == 0) {
            savePng(core.imageBuffer(), framePath(dir!, s.frame));
          }
        }
        return {"frame": s.frame, "pc": core.programCounter(0)};
      case "/press":
        final seq = q["seq"]!;
        final origin = s.frame + 1;
        final added = resolveInput(seq, s.buttons, origin: origin);
        s.pad.presses.addAll(added);
        return {
          "frame": s.frame,
          "from": origin,
          "end": readInput(seq, origin: origin).end,
          "presses": jsonDecode(pressesJson(added, s.buttons)),
        };
      case "/shot":
        savePng(core.imageBuffer(), q["path"]!);
        return {"frame": s.frame, "path": q["path"]};
      case "/audio":
        final bytes = s.pcm.toBytes();
        File(q["path"]!).writeAsBytesSync(
            wavBytes(bytes.sublist(audioFrom), s.sampleRate, s.channels));
        audioFrom = bytes.length;
        return {"frame": s.frame, "path": q["path"]};
      case "/state":
        return {
          "frame": s.frame,
          "pc": core.programCounter(0),
          "dump": core.dump()
        };
      case "/buttons":
        return {"buttons": s.buttons};
      case "/quit":
        return null;
      default:
        throw "unknown request: $path";
    }
  }

  await for (final req in server) {
    Map<String, Object?>? res;
    try {
      res = await handle(req.uri.path, req.uri.queryParameters);
      req.response.write(jsonEncode(res ?? {"quit": true}));
    } catch (e) {
      req.response.statusCode = 400;
      req.response.write(jsonEncode({"error": e.toString()}));
      res = {};
    }
    await req.response.close();
    if (res == null) break;
  }
  await server.close();
  exit(0);
}

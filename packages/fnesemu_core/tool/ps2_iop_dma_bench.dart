// Synthetic benchmark of the IOP DMA retry scan; no BIOS or disc is needed.
//
// dart build cli -t tool/ps2_iop_dma_bench.dart -o /tmp/ps2-iop-dma
// /tmp/ps2-iop-dma/bundle/bin/ps2_iop_dma_bench [idle|pending] [rounds]
//
// Compare AOT builds with the same mode. The pending channel deliberately
// never completes; its retry count must equal the number of service calls.
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/iop/iop_io.dart';
import 'package:fnesemu_core/src/core/ps2/iop/iop_memory.dart';
import 'package:fnesemu_core/src/core/ps2/sif.dart';

void main(List<String> args) {
  if (args.length > 2) throw ArgumentError('expected [idle|pending] [rounds]');
  final mode = args.isEmpty ? 'idle' : args[0];
  if (mode != 'idle' && mode != 'pending') throw ArgumentError('unknown mode');
  final rounds = args.length < 2 ? 5 : int.parse(args[1]);
  if (rounds < 1) throw ArgumentError('rounds must be positive');
  const iterations = 2000000;
  var best = double.infinity;
  for (var round = 0; round < rounds; round++) {
    final io = IopIo(IopMemory(Uint8List(4 * 1024 * 1024)), Sif());
    var retries = 0;
    if (mode == 'pending') {
      io.dpcr2 |= 1 << ((10 - 7) * 4 + 3);
      io.dmaHandlers[10] = (_) {
        retries++;
        return false;
      };
      io.channels[10].chcr = 1 << 24;
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      io.service();
    }
    sw.stop();
    if (retries != (mode == 'pending' ? iterations : 0)) {
      throw StateError('unexpected DMA retry count: $retries');
    }
    final ms = sw.elapsedMicroseconds / 1000;
    if (ms < best) best = ms;
    print('round $round: ${ms.toStringAsFixed(1)} ms, retries $retries');
  }
  print('$mode: best ${best.toStringAsFixed(1)} ms');
}

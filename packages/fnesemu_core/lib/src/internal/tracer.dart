import 'dart:async';

import '../types.dart';
import '../util/int.dart';
import 'loop_detector.dart';

export 'loop_detector.dart' show TraceRepeatMode;

// Tracer: logs CPU traces, with skipping repeating lines
class Tracer {
  final StreamSink<String> _stream;
  final LoopDetector _detector;

  Tracer(this._stream,
      {int size = 2048,
      int maxCandidates = 8,
      TraceRepeatMode mode = TraceRepeatMode.exact})
      : _detector = LoopDetector(
            capacity: size, maxCandidates: maxCandidates, mode: mode);

  final _calls = <(int, bool)>[];
  TraceFlow? _delayedFlow;
  int _delayRemaining = 0;
  static final _whitespace = RegExp(r'\s+');

  String _format(TraceLog log) =>
      '${'  ' * log.indent}${log.disasm.trimRight()} ${log.regs.replaceAll(_whitespace, ' ').trim()} cl:${log.cycle.format3} f:${log.frame} s:${log.scanline}\n';

  void _output(LoopUpdate update) {
    final ended = update.ended;
    if (ended != null) {
      final stats = ended.statistics;
      final first = stats.first.log, last = stats.last.log;
      _stream.add(
          '...loop period:${stats.period} iterations:${stats.iterations} '
          'tail:${stats.partialInstructions} skipped ${stats.skippedInstructions} lines '
          'cl:${first.cycle}..${last.cycle} elapsed:${stats.elapsedClocks} '
          'f:${first.frame}..${last.frame} s:${first.scanline}..${last.scanline} '
          'mode:${stats.mode.name} registers:${stats.registersChanged ? "changed" : "unchanged"}...\n');
      for (final status in ended.states) {
        _stream.add(_format(status.log));
      }
    }
    for (final status in update.ready) {
      _stream.add(_format(status.log));
    }
  }

  void _applyFlow(TraceFlow flow, int nextPc) {
    switch (flow.kind) {
      case TraceFlowKind.call:
      case TraceFlowKind.exception:
        if (flow.target == null || flow.target == nextPc) {
          _calls
              .add((flow.returnAddress!, flow.kind == TraceFlowKind.exception));
        }
      case TraceFlowKind.returned:
      case TraceFlowKind.jump:
      case TraceFlowKind.interruptReturn:
        final interrupt = flow.kind == TraceFlowKind.interruptReturn;
        final match = _calls.lastIndexWhere(
            (entry) => entry.$1 == nextPc && entry.$2 == interrupt);
        if (match >= 0) {
          _calls.removeRange(match, _calls.length);
        } else if (flow.kind == TraceFlowKind.returned &&
            !_calls.any((entry) => entry.$2)) {
          // A return outside the captured stack (capture may start mid-function).
          _calls.clear();
        }
      case TraceFlowKind.none:
        break;
    }
  }

  /// Emit the deferred tail when capture ends, even inside a repeated loop.
  void finish() {
    _output(_detector.finish());
  }

  void addTraceLog(TraceLog source, {int? nextPc}) {
    final path = _calls.map((entry) => '${entry.$1}:${entry.$2}').join('/');
    final log = TraceLog(
        source.pc, source.cycle, source.disasm, source.regs, source.state,
        frame: source.frame,
        scanline: source.scanline,
        flow: source.flow,
        instructionKey: source.instructionKey,
        indent: _calls.length,
        scope: source.scope);
    // Branch and return delay slots still belong to the caller/callee respectively.
    if (nextPc != null) {
      if (_delayedFlow != null && --_delayRemaining == 0) {
        _applyFlow(_delayedFlow!, nextPc);
        _delayedFlow = null;
      }
      if (log.flow.kind != TraceFlowKind.none) {
        if (log.flow.delaySlots > 0) {
          _delayedFlow = log.flow;
          _delayRemaining = log.flow.delaySlots;
        } else {
          _applyFlow(log.flow, nextPc);
        }
      }
    }
    _output(_detector.add(TraceStatus(log, context: path, nextPc: nextPc)));
  }
}

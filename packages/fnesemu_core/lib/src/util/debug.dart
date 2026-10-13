import 'dart:developer' as developer;

import 'int.dart';

enum LogLevel { debug, info, warn, error, off }

class DebugStatus {
  int clock = 0;
  int frame = 0;
  int scanline = 0;
  int pc = 0;

  @override
  String toString() => "${pc.x8} $frame ${scanline.d3z} $clock";
}

final debugStatus = DebugStatus();

/// A snapshot: the emulator may advance before the sink consumes this event.
class DebugLogEvent {
  const DebugLogEvent(
      this.name, this.level, this.message, this.status, this.id);

  final String name;
  final LogLevel level;
  final String message;
  final String status;
  final String? id;

  @override
  String toString() => '$status [$name${id == null ? '' : ':$id'}] '
      '${level.name}: $message';
}

void _developerSink(DebugLogEvent event) =>
    developer.log(event.toString(), name: event.name);

/// Configuration is local to this isolate. Longer names override their parents.
class DebugLogs {
  void Function(DebugLogEvent) sink = _developerSink;
  LogLevel level = LogLevel.debug;
  bool suppressRepeats = true;
  final _levels = <String, LogLevel>{};
  final _disabled = <(String, String), bool>{};
  final _repeats = <(String, String?), _Repeat>{};

  void setLevel(String name, LogLevel level) {
    _levels[name] = level;
    _repeats.clear();
  }

  void disable(String name, {required String id}) {
    _disabled[(name, id)] = true;
    _repeats.clear();
  }

  void enable(String name, {required String id}) {
    _disabled[(name, id)] = false;
    _repeats.clear();
  }

  Iterable<String> _parents(String name) sync* {
    while (true) {
      yield name;
      final dot = name.lastIndexOf('.');
      if (dot < 0) break;
      name = name.substring(0, dot);
    }
  }

  bool isEnabled(String name, LogLevel requested, {String? id}) {
    if (requested == LogLevel.off) return false;
    var threshold = level;
    for (final parent in _parents(name)) {
      final override = _levels[parent];
      if (override != null) {
        threshold = override;
        break;
      }
    }
    if (requested.index < threshold.index) return false;
    if (id != null) {
      for (final parent in _parents(name)) {
        final disabled = _disabled[(parent, id)];
        if (disabled != null) return !disabled;
      }
    }
    return true;
  }

  void _emit(String name, LogLevel level, String message, String? id) {
    final status = debugStatus.toString();
    if (suppressRepeats) {
      final key = (name, id);
      final previous = _repeats[key];
      if (previous != null &&
          previous.message == message &&
          previous.level == level) {
        previous.count++;
        return;
      }
      if (previous != null && previous.count > 0) {
        sink(DebugLogEvent(name, previous.level,
            '... (suppressed ${previous.count} times)', status, id));
      }
      _repeats[key] = _Repeat(message, level);
    }
    sink(DebugLogEvent(name, level, message, status, id));
  }

  /// Emit pending repeat counts, for example before a tool exits.
  void flush() {
    for (final entry in _repeats.entries) {
      final repeat = entry.value;
      if (repeat.count == 0) continue;
      sink(DebugLogEvent(
          entry.key.$1,
          repeat.level,
          '... (suppressed ${repeat.count} times)',
          debugStatus.toString(),
          entry.key.$2));
      repeat.count = 0;
    }
  }

  /// Restore defaults and discard repeat history.
  void reset() {
    sink = _developerSink;
    level = LogLevel.debug;
    suppressRepeats = true;
    _levels.clear();
    _disabled.clear();
    _repeats.clear();
  }
}

class _Repeat {
  _Repeat(this.message, this.level);
  final String message;
  final LogLevel level;
  int count = 0;
}

final logs = DebugLogs();

/// `c` methods accept a closure and evaluate it only when enabled.
class DebugLog {
  const DebugLog(this.name);
  final String name;

  bool get debugEnabled => logs.isEnabled(name, LogLevel.debug);

  void _write(LogLevel level, String message, String? id) {
    if (logs.isEnabled(name, level, id: id)) {
      logs._emit(name, level, message, id);
    }
  }

  void _lazy(LogLevel level, String Function() message, String? id) {
    if (logs.isEnabled(name, level, id: id)) {
      logs._emit(name, level, message(), id);
    }
  }

  void debug(String message, {String? id}) =>
      _write(LogLevel.debug, message, id);
  void debugc(String Function() message, {String? id}) =>
      _lazy(LogLevel.debug, message, id);
  void info(String message, {String? id}) => _write(LogLevel.info, message, id);
  void infoc(String Function() message, {String? id}) =>
      _lazy(LogLevel.info, message, id);
  void warn(String message, {String? id}) => _write(LogLevel.warn, message, id);
  void warnc(String Function() message, {String? id}) =>
      _lazy(LogLevel.warn, message, id);
  void error(String message, {String? id}) =>
      _write(LogLevel.error, message, id);
  void errorc(String Function() message, {String? id}) =>
      _lazy(LogLevel.error, message, id);
}

import 'package:fnesemu_core/src/util/debug.dart';
import 'package:test/test.dart';

void main() {
  late List<DebugLogEvent> events;
  const cdrom = DebugLog('ps.cdrom');

  setUp(() {
    logs.reset();
    events = [];
    logs.sink = events.add;
    debugStatus.clock =
        debugStatus.frame = debugStatus.scanline = debugStatus.pc = 0;
  });
  tearDown(() {
    logs.reset();
    debugStatus.clock =
        debugStatus.frame = debugStatus.scanline = debugStatus.pc = 0;
  });

  test('normal and closure methods deliver every level', () {
    cdrom.debug('d');
    cdrom.debugc(() => 'dc');
    cdrom.info('i');
    cdrom.infoc(() => 'ic');
    cdrom.warn('w');
    cdrom.warnc(() => 'wc');
    cdrom.error('e');
    cdrom.errorc(() => 'ec');
    expect(events.map((e) => e.message),
        ['d', 'dc', 'i', 'ic', 'w', 'wc', 'e', 'ec']);
    expect(events.map((e) => e.level), [
      LogLevel.debug,
      LogLevel.debug,
      LogLevel.info,
      LogLevel.info,
      LogLevel.warn,
      LogLevel.warn,
      LogLevel.error,
      LogLevel.error,
    ]);
  });

  test('disabled levels never evaluate closures', () {
    logs.level = LogLevel.off;
    String forbidden() => throw StateError('message evaluated');
    cdrom.debugc(forbidden);
    cdrom.infoc(forbidden);
    cdrom.warnc(forbidden);
    cdrom.errorc(forbidden);
    expect(cdrom.debugEnabled, isFalse);
    expect(events, isEmpty);
  });

}

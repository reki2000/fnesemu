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

  test('child overrides inherit levels without matching sibling prefixes', () {
    logs.setLevel('ps', LogLevel.warn);
    logs.setLevel('ps.cdrom', LogLevel.debug);
    cdrom.debug('visible');
    const DebugLog('ps.gpu').info('hidden');
    const DebugLog('ps.gpu').warn('warning');
    const DebugLog('psx').debug('sibling');
    expect(events.map((e) => e.message), ['visible', 'warning', 'sibling']);
  });

  test('item suppression happens before evaluation and child can enable it',
      () {
    logs.disable('ps', id: 'fifo');
    cdrom.debugc(() => throw StateError('message evaluated'), id: 'fifo');
    cdrom.debug('command', id: 'command');
    logs.enable('ps.cdrom', id: 'fifo');
    cdrom.debug('fifo', id: 'fifo');
    const DebugLog('ps.gpu').debug('hidden', id: 'fifo');
    expect(events.map((e) => e.message), ['command', 'fifo']);
  });

  test('repeat histories belong to names and item IDs', () {
    cdrom.debug('same', id: 'fifo');
    cdrom.debug('same', id: 'fifo');
    const DebugLog('ps.gpu').debug('same', id: 'fifo');
    cdrom.debug('same', id: 'command');
    cdrom.debug('next', id: 'fifo');
    expect(events.map((e) => e.message), [
      'same',
      'same',
      'same',
      '... (suppressed 1 times)',
      'next',
    ]);
    expect(events[3].name, 'ps.cdrom');
    expect(events[3].id, 'fifo');
  });

  test(
      'different levels are not suppressed and flush emits pending repeats once',
      () {
    cdrom.debug('same');
    cdrom.warn('same');
    cdrom.warn('same');
    logs.flush();
    logs.flush();
    expect(events.map((e) => e.level),
        [LogLevel.debug, LogLevel.warn, LogLevel.warn]);
    expect(events.last.message, '... (suppressed 1 times)');
  });

  test('events snapshot status before the emulator advances', () {
    debugStatus.pc = 0x1234;
    cdrom.info('loaded');
    debugStatus.pc = 0x5678;
    expect(events.single.status, startsWith('00001234'));
    expect(events.single.toString(), contains('[ps.cdrom] info: loaded'));
  });
}

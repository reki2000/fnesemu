import 'dart:typed_data';

import '../../pad_button.dart';
import '../../pad_source.dart';
import '../../util/state.dart';
import 'allegrex.dart';
import 'disc.dart';
import 'elf.dart';
import 'ge.dart';
import 'memory.dart';
import 'memstick.dart';
import 'rtc.dart';

/// Thread states of the kernel scheduler.
class PspThreadStatus {
  static const ready = 0;
  static const running = 1;
  static const waitVblank = 2;
  static const waitDelay = 3;
  static const waitSema = 4;
  static const waitJoin = 5;
  static const waitSleep = 6;
  static const dead = 7;
  static const dormant = 8; // created, not started
  static const waitLwMutex = 9;
  static const waitDisc = 10;
}

class PspThread {
  final int id;
  final String name;
  final int entry;
  final int stackTop;
  final int stackSize;
  int priority;
  int status = PspThreadStatus.dormant;
  int wakeAt = 0;
  int waitSema = 0;
  int waitCount = 0;
  int waitJoin = 0;
  int waitLw = 0; // workarea address of a lightweight mutex wait
  int exitStatus = 0;
  int? pendingResult;
  final state = AllegrexState();
  PspThread(this.id, this.name, this.entry, this.priority, this.stackTop,
      this.stackSize);
}

class _Sema {
  int count;
  final int max;
  _Sema(this.count, this.max);
}

/// A lightweight mutex, keyed by its guest workarea address. The kernel
/// mirrors the level, owner and waiter count into the workarea itself,
/// because guest libraries read the owner back for recursive locking.
class _LwMutex {
  final int attr;
  final int uid;
  int owner = 0;
  int count = 0;
  _LwMutex(this.attr, this.uid);
}

class _Block {
  final int addr;
  final int size;
  _Block(this.addr, this.size);
}

/// One open file. A memory file holds its bytes in [content]; a disc
/// file points at a node of the mounted disc and reads through it.
class _OpenFile {
  final String path;
  final content = <int>[];
  final PspDiscNode? node;
  final PspMsNode? msNode;

  /// The access the file was opened with (1 read, 2 write, 3 both),
  /// enforced for memory stick files; the other kinds restrict access
  /// at open time instead.
  final int access;

  /// Appending opens write at the end of the file, wherever the
  /// position was moved to.
  final bool append;

  /// A memory stick file whose contents changed since it was opened;
  /// closing it persists the stick.
  bool dirty = false;
  int position = 0;
  _OpenFile(this.path)
      : node = null,
        msNode = null,
        access = 3,
        append = false;
  _OpenFile.disc(this.path, this.node)
      : msNode = null,
        access = 1,
        append = false;
  _OpenFile.stick(this.path, this.msNode, this.access, this.append)
      : node = null;

  int get size => node?.entry.size ?? msNode?.content.length ?? content.length;
}

/// One directory entry as the guest sees it, from either file system.
class _DirEnt {
  final String name;
  final bool isDirectory;
  final int size;
  final int year, month, day, hour, minute, second;
  const _DirEnt(this.name, this.isDirectory, this.size, this.year,
      this.month, this.day, this.hour, this.minute, this.second);

  factory _DirEnt.disc(PspDiscNode node, String name) => _DirEnt(
      name,
      node.entry.isDirectory,
      node.entry.size,
      node.entry.year,
      node.entry.month,
      node.entry.day,
      node.entry.hour,
      node.entry.minute,
      node.entry.second);

  factory _DirEnt.stick(PspMsNode node, String name) {
    final (year, month, day, hour, minute, second) =
        PspMemStick.dateOf(node.modified);
    return _DirEnt(name, node.isDirectory, node.size, year, month, day,
        hour, minute, second);
  }
}

/// One open directory: the entries to hand out, in order (`.` and
/// `..` included).
class _OpenDir {
  final List<_DirEnt> entries;
  int index = 0;
  _OpenDir(this.entries);
}

/// A disc read waiting for the drive to load a sector: the descriptor,
/// the guest buffer and the requested length of the suspended call,
/// plus how many times its completion has been attempted. The waits
/// live outside the save state, like the open files themselves; a wait
/// restored without its entry completes as a zero-length read.
class _DiscWait {
  final int fd;
  final int at;
  final int length;
  int attempts = 0;
  _DiscWait(this.fd, this.at, this.length);
}

class _AudioChannel {
  bool reserved = false;
  int sampleCount = 0;
  int format = 0; // 0 = stereo, 1 = mono
  int nextAt = 0;
}

/// A small high-level emulation of the system software: it patches the
/// module's import stubs with syscall numbers, answers those calls with
/// Dart implementations and schedules the guest threads cooperatively.
/// Blocking calls switch threads; when nothing can run, the core fast
/// forwards time to the next wake-up or display refresh.
///
/// Only the services a first core needs are implemented: threads,
/// semaphores, mutexes, memory blocks, the display frame buffer, the
/// controller, the graphics engine's display lists, the audio channels,
/// file access (in-memory files, the mounted disc and the memory
/// stick), the real-time clock and a few utility calls. Unknown calls return zero, which most software treats as
/// success or as an idle dialog state.
class PspKernel {
  final PspMemory mem;
  final PadPort pad;

  /// The graphics engine; its lists run synchronously from the system
  /// calls below and its callbacks re-enter the processor through
  /// [_runGeCallback].
  late final PspGe ge;
  bool _inCallback = false;

  /// Receives mixed stereo samples at 44100 Hz from [flushAudio].
  void Function(Float32List samples)? audioSink;

  final _audioChannels = List.generate(8, (_) => _AudioChannel());
  final _mix = <double>[];
  int _mixBase = 0;
  final _handlers = <int, int? Function(Allegrex, PspImport?)>{};
  final _byCode = <int, PspImport>{};
  final threads = <int, PspThread>{};
  final _semas = <int, _Sema>{};
  final _lwMutexes = <int, _LwMutex>{};
  final _blocks = <int, _Block>{};
  final unknownCalls = <int, int>{};
  final log = StringBuffer();

  /// Files the guest opened through IoFileMgr, held in memory so that
  /// guests writing reports to files (a common test-harness pattern)
  /// work unchanged.
  final _files = <int, _OpenFile>{};
  final _dirs = <int, _OpenDir>{};

  /// The result of the last asynchronous file call of a descriptor,
  /// collected through the poll and wait calls; asynchronous calls
  /// complete at once in this kernel.
  final _async = <int, int>{};
  int _nextFd = 3;

  /// Disc reads suspended until the drive loads their sectors, by
  /// thread id.
  final _discWaits = <int, _DiscWait>{};

  /// The mounted disc, attached by the core; its files are served on
  /// the `disc0:` and `umd0:` devices.
  PspDisc? disc;

  /// The memory stick, attached by the core; its files are served on
  /// the `ms0:` device, and relative paths resolve against it through
  /// [_cwd]. A kernel the core did not attach one to uses a volatile
  /// stick of its own.
  PspMemStick _memStick = PspMemStick();
  PspMemStick get memStick => _memStick;
  set memStick(PspMemStick stick) {
    _memStick = stick;
    stick.clock = () => _nowSeconds;
  }

  /// The current directory relative paths resolve against, always
  /// device-qualified with a trailing slash.
  String _cwd = 'ms0:/';

  /// Emulated seconds since boot, refreshed on every system call;
  /// the memory stick stamps its files with it.
  int _nowSeconds = 0;

  /// The real-time clock's anchor: the host wall-clock tick taken on
  /// first use, and the processor clock at that moment. Later readings
  /// advance from the anchor by the emulated time elapsed, so delays
  /// measured by the guest match the clock it reads.
  int? _rtcAnchorTick;
  int _rtcAnchorClocks = 0;

  /// The host's offset from UTC in minutes, taken with the anchor;
  /// it is the local time zone of the emulated clock.
  int _rtcLocalOffset = 0;

  int _nextId = 1;
  PspThread? current;
  bool exited = false;
  int exitStatus = 0;

  // Display state, written by the display calls and read by the core.
  int fbAddr = 0;
  int fbWidth = 512;
  int fbFormat = 3;
  bool displayOn = true;
  int vcount = 0;

  int _heapAt;
  int _stackAt = 0x09f00000;
  int _nextDelayWake = 0x7fffffffffffffff;
  int _rng = 0x2545f491;

  static const _exitStubAt = 0x08000000;
  static const _callbackSentinelAt = 0x08000020;
  static const _mainStackTop = 0x0a000000;

  PspKernel(this.mem, this.pad, int heapStart)
      : _heapAt = (heapStart + 0xffff) & ~0xffff {
    ge = PspGe(mem);
    ge.callbackRunner = _runGeCallback;
    _registerHandlers();
  }

  /// Runs a graphics callback on the live processor with the caller's
  /// state saved around it, the way the system software invokes the
  /// signal and finish handlers from interrupt context. The callback
  /// returns to a sentinel that loops on itself; blocking calls made
  /// from a callback return at once instead of switching threads.
  void _runGeCallback(Allegrex cpu, int func, int id, int arg) {
    if (_inCallback || func == 0) return;
    _inCallback = true;
    final saved = AllegrexState()..copyFrom(cpu);
    cpu.r[4] = id;
    cpu.r[5] = arg;
    cpu.r[31] = _callbackSentinelAt;
    cpu.pc = func;
    cpu.nextPc = func + 4;
    var budget = 200000;
    while (budget-- > 0 && cpu.pc != _callbackSentinelAt) {
      if (!cpu.step()) break;
    }
    cpu.copyFrom(saved);
    _inCallback = false;
  }

  /// Prepares a loaded module: patches its stubs, writes the thread exit
  /// stub and creates the main thread. Returns the main thread.
  PspThread startModule(PspModuleImage image) {
    mem.write32(_exitStubAt, 0x0000000c); // syscall 0
    mem.write32(_exitStubAt + 4, 0x03e00008); // jr ra
    mem.write32(_exitStubAt + 8, 0); // nop
    // A jump to itself: graphics callbacks return here and stop.
    mem.write32(_callbackSentinelAt,
        0x08000000 | ((_callbackSentinelAt >> 2) & 0x3ffffff));
    var code = 1;
    for (final import in image.imports) {
      import.code = code++;
      _byCode[import.code] = import;
      mem.write32(import.stubAddr, 0x0000000c | (import.code << 6));
      mem.write32(import.stubAddr + 4, 0x03e00008);
    }
    final main = _newThread('main', image.entry, 0x20, _mainStackTop, 0x100000);
    main.status = PspThreadStatus.running;
    main.state.r[29] = _mainStackTop - 0x100;
    main.state.r[31] = _exitStubAt;
    main.state.r[28] = image.gp;
    main.state.pc = image.entry;
    main.state.nextPc = image.entry + 4;
    current = main;
    return main;
  }

  PspThread _newThread(
      String name, int entry, int priority, int stackTop, int stackSize) {
    final thread =
        PspThread(_nextId++, name, entry, priority, stackTop, stackSize);
    thread.state.r[28] = current?.state.r[28] ?? 0;
    threads[thread.id] = thread;
    return thread;
  }

  /// Whether the current thread can execute right now.
  bool get runnable =>
      current != null && current!.status == PspThreadStatus.running;

  /// The next clock at which a waiting thread wakes on its own, or null.
  int? get nextWake =>
      _nextDelayWake == 0x7fffffffffffffff ? null : _nextDelayWake;

  /// Called by the core when the display refresh begins: waiting display
  /// threads become ready and may preempt.
  void onVblank(Allegrex cpu) {
    vcount++;
    for (final thread in threads.values) {
      if (thread.status == PspThreadStatus.waitVblank) {
        thread.status = PspThreadStatus.ready;
        thread.pendingResult = 0;
      }
    }
    _preempt(cpu);
  }

  /// Wakes delay threads whose time has come; called by the core when the
  /// clock passes the value of [nextWake].
  void wakeDue(Allegrex cpu) {
    _nextDelayWake = 0x7fffffffffffffff;
    for (final thread in threads.values) {
      if (thread.status == PspThreadStatus.waitDelay) {
        if (thread.wakeAt <= cpu.clocks) {
          thread.status = PspThreadStatus.ready;
          thread.pendingResult = 0;
        } else if (thread.wakeAt < _nextDelayWake) {
          _nextDelayWake = thread.wakeAt;
        }
      }
    }
    _retryDiscWaits(cpu);
    _preempt(cpu);
  }

  /// Switches to a ready thread of strictly higher priority, if any.
  void _preempt(Allegrex cpu) {
    final cur = current;
    if (cur == null || cur.status != PspThreadStatus.running) {
      _schedule(cpu);
      return;
    }
    for (final thread in threads.values) {
      if (thread.status == PspThreadStatus.ready &&
          thread.priority < cur.priority) {
        _schedule(cpu);
        return;
      }
    }
  }

  /// Saves the processor into the current thread and loads the best ready
  /// thread. When none is ready the current thread stays loaded but not
  /// runnable, and the core advances time instead of stepping.
  void _schedule(Allegrex cpu) {
    final cur = current;
    if (cur != null && cur.status == PspThreadStatus.running) {
      cur.state.copyFrom(cpu);
      cur.status = PspThreadStatus.ready;
    } else if (cur != null &&
        cur.status != PspThreadStatus.dead &&
        cur.status != PspThreadStatus.ready) {
      // A thread that just blocked still has its live state in the
      // processor; a ready thread already has its state saved, and
      // copying over it would undo the return address the dispatcher
      // fixed up when the thread blocked.
      cur.state.copyFrom(cpu);
    }
    PspThread? best;
    for (final thread in threads.values) {
      if (thread.status != PspThreadStatus.ready) continue;
      if (best == null ||
          thread.priority < best.priority ||
          (thread.priority == best.priority && thread.id < best.id)) {
        best = thread;
      }
    }
    if (best == null) {
      if (cur != null && cur.status == PspThreadStatus.ready) {
        best = cur;
      } else {
        return;
      }
    }
    best.status = PspThreadStatus.running;
    current = best;
    cpu.copyFrom(best.state);
    if (best.pendingResult != null) {
      cpu.r[2] = best.pendingResult!;
      best.pendingResult = null;
    }
  }

  /// Ends the current thread; the main thread ending ends the program.
  void _exitThread(Allegrex cpu, int status, {bool delete = false}) {
    final cur = current!;
    cur.exitStatus = status;
    cur.status = PspThreadStatus.dead;
    _discWaits.remove(cur.id);
    for (final thread in threads.values) {
      if (thread.status == PspThreadStatus.waitJoin &&
          thread.waitJoin == cur.id) {
        thread.status = PspThreadStatus.ready;
        thread.pendingResult = 0;
        final statusAt = thread.state.r[5];
        if (statusAt != 0) mem.write32(statusAt, status);
      }
    }
    if (delete) threads.remove(cur.id);
    _schedule(cpu);
    // The program ends when no live thread remains: the module start
    // thread of SDK programs is only a bootstrap for the user thread it
    // creates, so its own exit does not end the program by itself.
    if (threads.values.every((t) =>
        t.status == PspThreadStatus.dead ||
        t.status == PspThreadStatus.dormant)) {
      exited = true;
    }
  }

  /// The syscall entry point wired to the processor.
  void dispatch(Allegrex cpu, int code) {
    _nowSeconds = cpu.clocks ~/ _cpuHz;
    if (code == 0) {
      _exitThread(cpu, cpu.r[2]);
      return;
    }
    final import = _byCode[code];
    if (import != null && import.library == 'sceAudio') {
    }
    final handler = import == null ? null : _handlers[import.nid];
    if (import == null) {
      // A syscall outside an import stub falls through with a zero.
      cpu.r[2] = 0;
      return;
    }
    final caller = current;
    final returnAt = cpu.r[31];
    int? result = 0;
    if (handler == null) {
      unknownCalls[import.nid] = (unknownCalls[import.nid] ?? 0) + 1;
    } else {
      result = handler(cpu, import);
    }
    if (caller == null || !threads.containsKey(caller.id)) return;
    // An import call returns straight to the link register, as the system
    // software does: the stub's return jump and the delay slot behind it
    // (the next stub's first word) never execute. A plain return value
    // lands in the caller's v0: directly when the caller still runs, or
    // in its saved state when the call blocked or preempted it. A handler
    // that blocked returns null and arranges the value itself.
    if (identical(current, caller) && runnable) {
      cpu.pc = returnAt;
      cpu.nextPc = returnAt + 4;
      if (result != null) cpu.r[2] = result;
    } else {
      caller.state.pc = returnAt;
      caller.state.nextPc = returnAt + 4;
      if (result != null) caller.state.r[2] = result;
      if (identical(current, caller)) {
        // The blocked caller is still the loaded thread: move the
        // processor past the stub as well, so a later reschedule that
        // saves the processor into the thread cannot undo the fix.
        cpu.pc = returnAt;
        cpu.nextPc = returnAt + 4;
      }
    }
  }

  int _arg(Allegrex cpu, int i) => cpu.r[4 + i];

  /// A 64-bit argument whose first word is argument [i]; 64-bit
  /// arguments sit in an even-odd register pair, so a call whose first
  /// argument is a pointer passes its 64-bit second argument at index 2.
  int _arg64(Allegrex cpu, int i) =>
      (_arg(cpu, i) & 0xffffffff) | ((_arg(cpu, i + 1) & 0xffffffff) << 32);

  int _readTick(int at) =>
      mem.read32(at) | (mem.read32(at + 4) << 32);

  void _writeTick(int at, int tick) {
    mem.write32(at, tick & 0xffffffff);
    mem.write32(at + 4, (tick >> 32) & 0xffffffff);
  }

  RtcDateTime _readDateTime(int at) => RtcDateTime(
        mem.read16(at),
        mem.read16(at + 2),
        mem.read16(at + 4),
        mem.read16(at + 6),
        mem.read16(at + 8),
        mem.read16(at + 10),
        mem.read32(at + 12),
      );

  void _writeDateTime(int at, RtcDateTime time) {
    mem.write16(at, time.year);
    mem.write16(at + 2, time.month);
    mem.write16(at + 4, time.day);
    mem.write16(at + 6, time.hour);
    mem.write16(at + 8, time.minute);
    mem.write16(at + 10, time.second);
    mem.write32(at + 12, time.microsecond);
  }

  /// The current real-time clock tick: the host wall clock anchored on
  /// first use, advanced by the emulated time elapsed since then.
  int _nowTick(Allegrex cpu) {
    final anchor = _rtcAnchorTick;
    if (anchor == null) {
      final now = DateTime.now();
      _rtcLocalOffset = now.timeZoneOffset.inMinutes;
      final tick = now.toUtc().microsecondsSinceEpoch + rtcUnixEpochTick;
      _rtcAnchorTick = tick;
      _rtcAnchorClocks = cpu.clocks;
      return tick;
    }
    return anchor + (cpu.clocks - _rtcAnchorClocks) ~/ _clocksPerMicrosecond;
  }

  void _writeRtcString(int at, String text) {
    mem.writeBytes(at, [...text.codeUnits, 0]);
  }

  void _registerHandlers() {
    void on(int nid, int? Function(Allegrex, PspImport?) fn) =>
        _handlers[nid] = fn;

    // ThreadManForUser
    on(0x446d8de6, _createThread);
    on(0x9fa03cd3, _deleteThread);
    on(0xf475845d, _startThread);
    on(0xaa73c935, (cpu, _) {
      _exitThread(cpu, _arg(cpu, 0));
      return null;
    });
    on(0x809ce29b, (cpu, _) {
      _exitThread(cpu, _arg(cpu, 0), delete: true);
      return null;
    });
    on(0x278c0df5, _waitThreadEnd);
    on(0xceadeb47, _delayThread);
    on(0xea748e31, (cpu, _) => current?.id ?? 0);
    on(0x9ace131e, (cpu, _) {
      // SleepThread: wakes only through WakeupThread.
      if (_inCallback) return 0;
      current!.status = PspThreadStatus.waitSleep;
      _schedule(cpu);
      return null;
    });
    on(0x1d17decf, (cpu, _) {
      final thread = threads[_arg(cpu, 0)];
      if (thread != null && thread.status == PspThreadStatus.waitSleep) {
        thread.status = PspThreadStatus.ready;
        thread.pendingResult = 0;
      }
      return 0;
    });
    on(0xd6da4ba1, _createSema);
    on(0x4e3a1105, _waitSema);
    on(0x6d212bac, _waitSema); // the CB form shares the wait machinery
    on(0x3f53e640, _signalSema);
    on(0x58b1f937, _pollSema);
    on(0x28b6489c, (cpu, _) {
      _semas.remove(_arg(cpu, 0));
      return 0;
    });
    // Lightweight mutexes live in a guest workarea, not behind an id.
    on(0x19cff145, _createLwMutex);
    on(0x60107536, _deleteLwMutex);
    on(0xbea46419, (cpu, _) => _lockLwMutex(cpu, blocking: true));
    on(0xdc692ee3, (cpu, _) => _lockLwMutex(cpu, blocking: false));
    on(0x15b6446b, _unlockLwMutex);
    on(0x293b45b8, (cpu, _) => current?.id ?? 0);
    on(0x17c1684e, _referThreadStatus);
    // Message pipes are not implemented; status queries fail cleanly.
    on(0x33be4024, (cpu, _) => 0x80020198);
    // StdioForUser: the standard descriptor numbers.
    on(0x172d316e, (cpu, _) => 0);
    on(0xa6bab2e9, (cpu, _) => 1);
    on(0xf78ba90a, (cpu, _) => 2);

    // SysMemUserForUser: partition memory blocks over a heap arena.
    on(0x237dbd4f, _allocBlock);
    on(0x9d9a5ba1, (cpu, _) => _blocks[_arg(cpu, 0)]?.addr ?? 0);
    on(0xb6d61d02, (cpu, _) {
      _blocks.remove(_arg(cpu, 0));
      return 0;
    });
    on(0xb73cd27a, (cpu, _) {
      _blocks.remove(_arg(cpu, 0));
      return 0;
    });
    on(0xf919f628, (cpu, _) => 0x800000);
    on(0xa291f107, (cpu, _) => 0x800000);

    // LoadExecForUser
    on(0x05572a5f, (cpu, _) {
      exited = true;
      exitStatus = 0;
      return 0;
    });
    on(0x2ac9954b, (cpu, _) {
      exited = true;
      exitStatus = _arg(cpu, 0);
      return 0;
    });

    // ModuleMgrForUser: further modules are accepted but not loaded.
    on(0x977de386, (cpu, _) => 1);
    on(0x50f0c1ec, (cpu, _) => 0);
    on(0xd675ebb8, (cpu, _) => 0);
    on(0x2e0911aa, (cpu, _) => 0);

    // sceDisplay
    on(0x0e20f177, (cpu, _) => 0);
    on(0x289d82fe, (cpu, _) {
      fbAddr = _arg(cpu, 0) & 0x1fffffff;
      fbWidth = _arg(cpu, 1);
      fbFormat = _arg(cpu, 2);
      return 0;
    });
    on(0xeeda2e54, (cpu, _) {
      final at = _arg(cpu, 0);
      if (at != 0) {
        mem.write32(at, fbAddr | 0x40000000);
        mem.write32(at + 4, fbWidth);
        mem.write32(at + 8, fbFormat);
        mem.write32(at + 12, 0);
      }
      return 0;
    });
    on(0x984c27e7, _waitVblank);
    on(0x46f186c3, _waitVblank);
    on(0x9c6eaad7, (cpu, _) => vcount);
    on(0xb4f378fa, (cpu, _) => 0);
    on(0x773dd3a3, (cpu, _) => 0);

    // sceCtrl
    on(0x1f4011e6, (cpu, _) => 0);
    on(0x6a2774f3, (cpu, _) => 0);
    on(0x1f3112b3, (cpu, _) => 0);
    on(0xda6b76a1, (cpu, _) => 0);
    on(0x1f803938, _readCtrl);
    on(0xa9c80c72, _readCtrl);
    on(0x60a81f03, _readCtrl);
    on(0xd6ad4d80, _readCtrl);

    // sceGu: display list execution is not part of this core; the setup
    // calls succeed so software can still present a frame buffer.
    for (final nid in [
      0x7f271dbd,
      0x1f950bcf,
      0xb4356ffa,
      0xa12ece9d,
      0x34d95ebe,
      0x4f6d8a31,
    ]) {
      on(nid, (cpu, _) => 0);
    }
    on(0xb3229c77, (cpu, _) => displayOn ? 1 : 0);

    // sceGe_user: display lists execute synchronously when queued, so
    // the sync calls only report the state the list already reached.
    on(0xab49e76a, (cpu, _) {
      return ge.enqueue(cpu, _arg(cpu, 0), _arg(cpu, 1));
    });
    on(0x1c0d95a6, (cpu, _) {
      return ge.enqueue(cpu, _arg(cpu, 0), _arg(cpu, 1), head: true);
    });
    on(0x5fb86ab0, (cpu, _) => ge.dequeue(_arg(cpu, 0)));
    on(0xe0d68148, (cpu, _) {
      return ge.updateStall(cpu, _arg(cpu, 0), _arg(cpu, 1));
    });
    on(0x03444eb4, (cpu, _) => ge.listState(_arg(cpu, 0)));
    on(0xb287bd61, (cpu, _) => ge.drawState());
    on(0xb448ec0d, (cpu, _) {
      ge.breakQueue(_arg(cpu, 0) == 1);
      return 0;
    });
    on(0x4c06e472, (cpu, _) => 0);
    on(0xa4fc06a4, (cpu, _) => ge.setCallback(_arg(cpu, 0)));
    on(0x05db22ce, (cpu, _) {
      ge.unsetCallback();
      return 0;
    });
    on(0x1f6752ad, (cpu, _) => 0x200000);
    on(0xe47e40e4, (cpu, _) => 0x44000000);
    on(0xb77905ea, (cpu, _) {
      ge.edramTranslation = _arg(cpu, 0);
      return 0;
    });
    on(0xdc93cfef, (cpu, _) => ge.regs[_arg(cpu, 0) & 0xff]);
    on(0x57c8945b, (cpu, _) {
      final dest = _arg(cpu, 1);
      if (dest == 0) return 0;
      final matrix = switch (_arg(cpu, 0)) {
        0 => ge.world,
        1 => ge.view,
        2 => ge.proj,
        _ => ge.tgen,
      };
      final scratch = ByteData(4);
      for (var i = 0; i < 16; i++) {
        scratch.setFloat32(0, matrix[i]);
        mem.write32(dest + i * 4, scratch.getUint32(0));
      }
      return 0;
    });
    on(0xe66cb92e, (cpu, _) => 0);
    on(0x438a385a, (cpu, _) {
      ge.saveContext(_arg(cpu, 0));
      return 0;
    });
    on(0x0bf608fb, (cpu, _) {
      ge.restoreContext(_arg(cpu, 0));
      return 0;
    });

    // UtilsForUser
    on(0x27cc57f0, (cpu, _) {
      // GetSystemTimeWide returns the 64-bit time in v0:v1.
      final micros = cpu.clocks ~/ _clocksPerMicrosecond;
      cpu.r[2] = micros & 0xffffffff;
      cpu.r[3] = micros >>> 32;
      return null;
    });
    on(0xe860e75e, (cpu, _) {
      _rng = _arg(cpu, 1) | 1;
      return 0;
    });
    on(0x06fb8a63, (cpu, _) {
      _rng ^= _rng << 13;
      _rng ^= _rng >>> 17;
      _rng ^= _rng << 5;
      return _rng & 0xffffffff;
    });

    // sceRtc: the current time comes from [_nowTick], the conversions
    // and calendar arithmetic from rtc.dart.
    on(0xc41c2853, (cpu, _) => 1000000);
    on(0x3f7ad767, (cpu, _) {
      final at = _arg(cpu, 0);
      if (at != 0) _writeTick(at, _nowTick(cpu));
      return 0;
    });
    on(0x4cfa57b0, (cpu, _) {
      final tick = _nowTick(cpu) + _arg(cpu, 1) * 60000000;
      _writeDateTime(_arg(cpu, 0), rtcDateTimeFromTick(tick));
      return 0;
    });
    on(0xe7c27d1b, (cpu, _) {
      final tick = _nowTick(cpu) + _rtcLocalOffset * 60000000;
      _writeDateTime(_arg(cpu, 0), rtcDateTimeFromTick(tick));
      return 0;
    });
    on(0x34885e0d, (cpu, _) {
      _nowTick(cpu);
      final tick = _readTick(_arg(cpu, 0)) + _rtcLocalOffset * 60000000;
      _writeTick(_arg(cpu, 1), tick & 0xffffffffffffffff);
      return 0;
    });
    on(0x779242a2, (cpu, _) {
      _nowTick(cpu);
      final tick = _readTick(_arg(cpu, 0)) - _rtcLocalOffset * 60000000;
      _writeTick(_arg(cpu, 1), tick & 0xffffffffffffffff);
      return 0;
    });
    on(0x42307a17, (cpu, _) => rtcIsLeapYear(_arg(cpu, 0)) ? 1 : 0);
    on(0x05ef322c,
        (cpu, _) => rtcDaysInMonth(_arg(cpu, 0), _arg(cpu, 1)));
    on(0x57726bc1, (cpu, _) =>
        rtcDayOfWeek(_arg(cpu, 0), _arg(cpu, 1), _arg(cpu, 2)));
    on(0x4b1b5e82,
        (cpu, _) => rtcCheckValid(_readDateTime(_arg(cpu, 0))));
    on(0x7ed29e40, (cpu, _) {
      final tick = _readTick(_arg(cpu, 1));
      _writeDateTime(_arg(cpu, 0), rtcDateTimeFromTick(tick));
      return 0;
    });
    on(0x6ff40acc, (cpu, _) {
      final time = _readDateTime(_arg(cpu, 0));
      if (time.year < 1 || time.year > 9999) return 0x800001fe;
      _writeTick(_arg(cpu, 1), rtcTickFromDateTime(time));
      return 0;
    });
    on(0x9ed0ae87, (cpu, _) {
      final a = _readTick(_arg(cpu, 0));
      final b = _readTick(_arg(cpu, 1));
      return a == b ? 0 : (a > b ? 1 : -1);
    });
    on(0x44f45e05, (cpu, _) {
      final tick = _readTick(_arg(cpu, 1)) + _arg64(cpu, 2);
      _writeTick(_arg(cpu, 0), tick & 0xffffffffffffffff);
      return 0;
    });
    on(0x26d25a5d, (cpu, _) {
      final tick = _readTick(_arg(cpu, 1)) + _arg64(cpu, 2);
      _writeTick(_arg(cpu, 0), tick & 0xffffffffffffffff);
      return 0;
    });
    on(0xf2a4afe5, (cpu, _) {
      final tick = _readTick(_arg(cpu, 1)) + _arg64(cpu, 2) * 1000000;
      _writeTick(_arg(cpu, 0), tick & 0xffffffffffffffff);
      return 0;
    });
    on(0xe6605bca, (cpu, _) {
      final tick = _readTick(_arg(cpu, 1)) + _arg64(cpu, 2) * 60000000;
      _writeTick(_arg(cpu, 0), tick & 0xffffffffffffffff);
      return 0;
    });
    on(0x26d7a24a, (cpu, _) {
      final tick = _readTick(_arg(cpu, 1)) + _arg(cpu, 2) * 3600000000;
      _writeTick(_arg(cpu, 0), tick & 0xffffffffffffffff);
      return 0;
    });
    on(0xe51b4b7a, (cpu, _) {
      final tick = _readTick(_arg(cpu, 1)) + _arg(cpu, 2) * 86400000000;
      _writeTick(_arg(cpu, 0), tick & 0xffffffffffffffff);
      return 0;
    });
    on(0xcf3a2ca8, (cpu, _) {
      final tick = _readTick(_arg(cpu, 1)) + _arg(cpu, 2) * 604800000000;
      _writeTick(_arg(cpu, 0), tick & 0xffffffffffffffff);
      return 0;
    });
    on(0xdbf74f1b, (cpu, _) {
      final tick = rtcTickAddMonths(_readTick(_arg(cpu, 1)), _arg(cpu, 2));
      _writeTick(_arg(cpu, 0), tick);
      return 0;
    });
    on(0x42842c77, (cpu, _) {
      final tick = rtcTickAddYears(_readTick(_arg(cpu, 1)), _arg(cpu, 2));
      _writeTick(_arg(cpu, 0), tick);
      return 0;
    });
    on(0x3a807cc8, (cpu, _) {
      final tick = rtcUnixEpochTick + _arg(cpu, 1) * 1000000;
      _writeDateTime(_arg(cpu, 0), rtcDateTimeFromTick(tick));
      return 0;
    });
    on(0x1909c99b, (cpu, _) {
      final seconds = _arg64(cpu, 2);
      final tick = rtcUnixEpochTick +
          (seconds.toSigned(64)) * 1000000;
      _writeDateTime(_arg(cpu, 0), rtcDateTimeFromTick(tick));
      return 0;
    });
    on(0x27c4594c, (cpu, _) {
      final tick = rtcTickFromDateTime(_readDateTime(_arg(cpu, 0)));
      mem.write32(
          _arg(cpu, 1), (tick - rtcUnixEpochTick) ~/ 1000000 & 0xffffffff);
      return 0;
    });
    on(0xe1c93e47, (cpu, _) {
      final tick = rtcTickFromDateTime(_readDateTime(_arg(cpu, 0)));
      _writeTick(_arg(cpu, 1), (tick - rtcUnixEpochTick) ~/ 1000000);
      return 0;
    });
    on(0xf006f264, (cpu, _) {
      _writeDateTime(_arg(cpu, 0), rtcDateTimeFromDos(_arg(cpu, 1)));
      return 0;
    });
    on(0x36075567, (cpu, _) {
      final dos = rtcDosFromDateTime(_readDateTime(_arg(cpu, 0)));
      if (dos == null) return -1;
      mem.write32(_arg(cpu, 1), dos);
      return 0;
    });
    on(0x7ace4c04, (cpu, _) {
      final tick = rtcWin32EpochTick + _arg64(cpu, 2) ~/ 10;
      _writeDateTime(_arg(cpu, 0), rtcDateTimeFromTick(tick));
      return 0;
    });
    on(0xcf561893, (cpu, _) {
      final at = _arg(cpu, 1);
      if (at == 0) return 0x800001fe;
      final tick = rtcTickFromDateTime(_readDateTime(_arg(cpu, 0)));
      if (tick < rtcWin32EpochTick) {
        _writeTick(at, 0);
        return 0x800001fe;
      }
      _writeTick(at, (tick - rtcWin32EpochTick) * 10);
      return 0;
    });
    on(0xc663b3b9, (cpu, _) {
      final tick = _readTick(_arg(cpu, 1));
      _writeRtcString(_arg(cpu, 0), rtcFormatRfc2822(tick, _arg(cpu, 2)));
      return 0;
    });
    on(0x7de6711b, (cpu, _) {
      _nowTick(cpu);
      final tick = _readTick(_arg(cpu, 1));
      _writeRtcString(
          _arg(cpu, 0), rtcFormatRfc2822(tick, _rtcLocalOffset));
      return 0;
    });
    on(0x0498fb3c, (cpu, _) {
      final tick = _readTick(_arg(cpu, 1));
      _writeRtcString(_arg(cpu, 0), rtcFormatRfc3339(tick, _arg(cpu, 2)));
      return 0;
    });
    on(0x27f98543, (cpu, _) {
      _nowTick(cpu);
      final tick = _readTick(_arg(cpu, 1));
      _writeRtcString(
          _arg(cpu, 0), rtcFormatRfc3339(tick, _rtcLocalOffset));
      return 0;
    });
    on(0xdfbc5f16, (cpu, _) {
      final tick = rtcParseDateTime(mem.readString(_arg(cpu, 1), 256));
      _writeTick(_arg(cpu, 0), tick ?? 0);
      return tick == null ? -1 : 0;
    });
    on(0x28e1e988, (cpu, _) {
      final tick = rtcParseRfc3339(mem.readString(_arg(cpu, 1), 256));
      _writeTick(_arg(cpu, 0), tick ?? 0);
      return tick == null ? -1 : 0;
    });

    // IoFileMgrForUser: the standard streams and in-memory files, the
    // mounted disc served read-only on its devices and the memory
    // stick served writable on ms0:. The asynchronous forms complete
    // at once and report through the poll and wait calls.
    on(0x109f50bc, _ioOpen);
    on(0x89aa9906, _ioOpenAsync);
    on(0x6a638d83, _ioRead);
    on(0xa0b5a7c2, _ioReadAsync);
    on(0x42ec03ac, _ioWrite);
    on(0x0facab19, _ioWriteAsync);
    on(0x810c4bc3, _ioClose);
    on(0xff5940b6, _ioClose);
    on(0x27eb27b8, _ioLseek);
    on(0x68963324, _ioLseek32);
    on(0x71b19e77, _ioLseekAsync);
    on(0x1b385d8f, _ioLseek32Async);
    on(0xace946e8, _ioGetstat);
    on(0xb29ddf9c, _ioDopen);
    on(0xe3eb004c, _ioDread);
    on(0xeb092469, _ioDclose);
    on(0x06a70004, _ioMkdir);
    on(0xf27a9c51, _ioRemove);
    on(0x779103a0, _ioRename);
    on(0x55f4717d, _ioChdir);
    on(0xab96437f, _ioSync);
    on(0x63632449, (cpu, _) {
      final fd = _arg(cpu, 0);
      return _files.containsKey(fd) || _dirs.containsKey(fd)
          ? 0
          : 0x80010002;
    });
    on(0x3251ea56, _ioPollAsync);
    on(0x35dbd746, _ioPollAsync);
    on(0xe8bc6571, (cpu, _) => 0);
    on(0xb293727f, (cpu, _) => 0);
    on(0xa12a0514, (cpu, _) => 0);

    // sceUmdUser: a mounted disc is present and ready, and no disc
    // reports itself as not present; activation is a formality.
    on(0xc6183d47, (cpu, _) => 0);
    on(0xe83742ba, (cpu, _) => 0);
    on(0x8ef08fce, (cpu, _) => 0);
    on(0x4a9e5e29, (cpu, _) => 0);
    on(0x6b4a146c, (cpu, _) => disc?.isMounted == true ? 0x22 : 0x01);
    on(0xaee7404d, (cpu, _) => 0);
    on(0xbd2bde07, (cpu, _) => 0);
    on(0x54f5fb11, (cpu, _) {
      // sceIoDevctl: the "emulator:" device is how test harnesses
      // detect an emulator and deliver their output (command 2); the
      // probe for it (command 3) and the display query (command 1)
      // succeed. Arguments past the fourth travel in t0/t1 in the
      // Allegrex calling convention, so the output pointer for
      // command 1 is in t0.
      final device = mem.readString(_arg(cpu, 0), 32);
      if (device == 'disc0:' || device == 'umd0:') {
        return disc?.isMounted == true ? 0 : 0x80010002;
      }
      if (device == 'ms0:') return 0;
      if (device != 'emulator:' && device != 'kemulator:') {
        return 0x80010002;
      }
      final command = _arg(cpu, 1);
      switch (command) {
        case 0x02:
          log.write(mem.readString(_arg(cpu, 2), _arg(cpu, 3)));
          return 0;
        case 0x01:
          final out = cpu.r[8];
          if (out != 0) mem.write32(out, 1);
          return 0;
        default:
          return 0;
      }
    });

    // sceAudio: eight channels with fixed block sizes, mixed onto a
    // 44100 Hz stereo timeline and flushed by the core at each refresh.
    on(0x5ec81c55, _audioReserve);
    on(0x136caf51, (cpu, _) => _audioOutput(cpu, blocking: false));
    on(0xe2d56b2d, (cpu, _) => _audioOutput(cpu, blocking: true));
    on(0x13f592bc, (cpu, _) => _audioOutputPanned(cpu));
    on(0x6fc46853, (cpu, _) {
      final index = _arg(cpu, 0);
      if (index < 0 || index >= 8 || !_audioChannels[index].reserved) {
        return 0x80260002;
      }
      _audioChannels[index].reserved = false;
      _audioChannels[index].nextAt = 0;
      return 0;
    });
    on(0xb011b7ff, (cpu, _) {
      final index = _arg(cpu, 0);
      if (index < 0 || index >= 8 || !_audioChannels[index].reserved) {
        return 0x80260002;
      }
      final rest = _audioChannels[index].nextAt - _audioAt(cpu);
      return rest > 0 ? rest : 0;
    });
    on(0x827a2fb7, (cpu, _) => 0);
  }

  static const _audioRate = 44100;
  static const _cpuHz = Allegrex.clockHz;
  static const _clocksPerMicrosecond = _cpuHz ~/ 1000000;

  /// The playhead: how many samples the output has consumed so far.
  int _audioAt(Allegrex cpu) => cpu.clocks * _audioRate ~/ _cpuHz;

  int? _audioReserve(Allegrex cpu, PspImport? _) {
    var index = _arg(cpu, 0);
    final sampleCount = _arg(cpu, 1);
    final format = _arg(cpu, 2);
    if (sampleCount <= 0 || sampleCount > 65472) return 0x8026000a;
    if (index == -1) {
      index = _audioChannels.indexWhere((c) => !c.reserved);
      if (index < 0) return 0x80260005;
    }
    if (index < 0 || index >= 8 || _audioChannels[index].reserved) {
      return 0x80260002;
    }
    final channel = _audioChannels[index];
    channel.reserved = true;
    channel.sampleCount = sampleCount;
    channel.format = format;
    channel.nextAt = 0;
    return index;
  }

  int? _audioOutput(Allegrex cpu, {required bool blocking}) {
    final index = _arg(cpu, 0);
    if (index < 0 || index >= 8) return 0x80260002;
    final channel = _audioChannels[index];
    if (!channel.reserved) return 0x80260002;
    final volume = _arg(cpu, 1);
    final at = _arg(cpu, 2);
    final frames = channel.sampleCount;
    final start =
        channel.nextAt > _audioAt(cpu) ? channel.nextAt : _audioAt(cpu);
    channel.nextAt = start + frames;
    if (at != 0) _mixBlock(channel, start, volume, at);
    final rest = channel.nextAt - _audioAt(cpu);
    if (!blocking || rest <= 0 || _inCallback) return rest > 0 ? rest : 0;
    // Block until the queued block has played out, on the delay queue.
    current!.status = PspThreadStatus.waitDelay;
    current!.wakeAt = cpu.clocks + rest * _cpuHz ~/ _audioRate;
    if (current!.wakeAt < _nextDelayWake) _nextDelayWake = current!.wakeAt;
    _schedule(cpu);
    return null;
  }

  int? _audioOutputPanned(Allegrex cpu) {
    final index = _arg(cpu, 0);
    if (index < 0 || index >= 8) return 0x80260002;
    final channel = _audioChannels[index];
    if (!channel.reserved) return 0x80260002;
    final at = _arg(cpu, 3);
    final frames = channel.sampleCount;
    final start =
        channel.nextAt > _audioAt(cpu) ? channel.nextAt : _audioAt(cpu);
    channel.nextAt = start + frames;
    if (at != 0) {
      _mixBlock(channel, start, _arg(cpu, 1), at, rightVolume: _arg(cpu, 2));
    }
    final rest = channel.nextAt - _audioAt(cpu);
    if (rest <= 0 || _inCallback) return rest > 0 ? rest : 0;
    // The panned output call always blocks until the block has played.
    current!.status = PspThreadStatus.waitDelay;
    current!.wakeAt = cpu.clocks + rest * _cpuHz ~/ _audioRate;
    if (current!.wakeAt < _nextDelayWake) _nextDelayWake = current!.wakeAt;
    _schedule(cpu);
    return null;
  }

  void _mixBlock(_AudioChannel channel, int start, int volume, int at,
      {int? rightVolume}) {
    final gainL = (volume > 0x8000 ? 0x8000 : volume) / 0x8000;
    final gainR = rightVolume == null
        ? gainL
        : (rightVolume > 0x8000 ? 0x8000 : rightVolume) / 0x8000;
    final frames = channel.sampleCount;
    final needed = (start - _mixBase + frames) * 2;
    while (_mix.length < needed) {
      _mix.add(0);
    }
    for (var i = 0; i < frames; i++) {
      final out = (start - _mixBase + i) * 2;
      if (channel.format == 1) {
        final s = _sample16(at + i * 2);
        _mix[out] += s * gainL;
        _mix[out + 1] += s * gainR;
      } else {
        _mix[out] += _sample16(at + i * 4) * gainL;
        _mix[out + 1] += _sample16(at + i * 4 + 2) * gainR;
      }
    }
  }

  double _sample16(int at) {
    final v = mem.read16(at);
    return (v >= 0x8000 ? v - 0x10000 : v) / 32768;
  }

  /// Emits every sample the playhead has passed at [clocks] to the sink
  /// and drops it from the mix timeline.
  void flushAudio(int clocks) {
    final playhead = clocks * _audioRate ~/ _cpuHz;
    final frames = playhead - _mixBase;
    if (frames <= 0) return;
    final out = Float32List(frames * 2);
    final available = _mix.length ~/ 2;
    final copied = frames < available ? frames : available;
    for (var i = 0; i < copied * 2; i++) {
      out[i] = _mix[i];
    }
    _mix.removeRange(0, copied * 2);
    _mixBase = playhead;
    audioSink?.call(out);
  }

  int? _createThread(Allegrex cpu, PspImport? _) {
    final name = mem.readString(_arg(cpu, 0), 32);
    final entry = _arg(cpu, 1);
    final priority = _arg(cpu, 2);
    var stackSize = _arg(cpu, 3);
    if (stackSize <= 0) stackSize = 0x10000;
    stackSize = (stackSize + 0xfff) & ~0xfff;
    _stackAt -= stackSize;
    final thread =
        _newThread(name, entry, priority, _stackAt + stackSize, stackSize);
    return thread.id;
  }

  int? _deleteThread(Allegrex cpu, PspImport? _) {
    final thread = threads[_arg(cpu, 0)];
    if (thread == null) return 0x80020198;
    if (!identical(thread, current)) threads.remove(thread.id);
    return 0;
  }

  int? _startThread(Allegrex cpu, PspImport? _) {
    final thread = threads[_arg(cpu, 0)];
    if (thread == null || thread.status != PspThreadStatus.dormant) {
      return 0x80020198;
    }
    final argSize = _arg(cpu, 1), argAt = _arg(cpu, 2);
    final sp = thread.stackTop - 0x100;
    thread.state.pc = thread.entry;
    thread.state.nextPc = thread.entry + 4;
    thread.state.r[29] = sp;
    thread.state.r[31] = _exitStubAt;
    thread.state.r[4] = argSize;
    if (argSize > 0 && argAt != 0) {
      final dest = sp - ((argSize + 7) & ~7);
      mem.writeBytes(dest, mem.readBytes(argAt, argSize));
      thread.state.r[29] = dest;
      thread.state.r[5] = dest;
    } else {
      thread.state.r[5] = 0;
    }
    thread.status = PspThreadStatus.ready;
    return 0;
  }

  int? _waitThreadEnd(Allegrex cpu, PspImport? _) {
    if (_inCallback) return 0;
    final target = threads[_arg(cpu, 0)];
    if (target == null) return 0x80020198;
    if (target.status == PspThreadStatus.dead) {
      final at = _arg(cpu, 1);
      if (at != 0) mem.write32(at, target.exitStatus);
      return 0;
    }
    current!.status = PspThreadStatus.waitJoin;
    current!.waitJoin = target.id;
    _schedule(cpu);
    return null;
  }

  int? _delayThread(Allegrex cpu, PspImport? _) {
    if (_inCallback) return 0;
    final micros = _arg(cpu, 0);
    if (micros <= 0) {
      // A zero delay is a yield: reschedule and report on resumption.
      current!.pendingResult = 0;
      _schedule(cpu);
      return null;
    }
    final clocks = micros * _clocksPerMicrosecond;
    current!.status = PspThreadStatus.waitDelay;
    current!.wakeAt = cpu.clocks + clocks;
    if (current!.wakeAt < _nextDelayWake) _nextDelayWake = current!.wakeAt;
    _schedule(cpu);
    return null;
  }

  int? _waitVblank(Allegrex cpu, PspImport? _) {
    if (_inCallback) return 0;
    current!.status = PspThreadStatus.waitVblank;
    _schedule(cpu);
    return null;
  }

  int? _createSema(Allegrex cpu, PspImport? _) {
    final initial = cpu.r[6]; // a2
    final max = cpu.r[7]; // a3
    final id = _nextId++;
    _semas[id] = _Sema(initial, max <= 0 ? 1 : max);
    return id;
  }

  int? _waitSema(Allegrex cpu, PspImport? _) {
    if (_inCallback) return 0;
    final sema = _semas[_arg(cpu, 0)];
    if (sema == null) return 0x80020198;
    final count = _arg(cpu, 1) <= 0 ? 1 : _arg(cpu, 1);
    if (sema.count >= count) {
      sema.count -= count;
      return 0;
    }
    final timeout = _arg(cpu, 2);
    if (timeout != 0 && mem.read32(timeout) == 0) return 0x800201b9;
    current!.status = PspThreadStatus.waitSema;
    current!.waitSema = _arg(cpu, 0);
    current!.waitCount = count;
    _schedule(cpu);
    return null;
  }

  int? _pollSema(Allegrex cpu, PspImport? _) {
    final sema = _semas[_arg(cpu, 0)];
    if (sema == null) return 0x80020198;
    final count = _arg(cpu, 1) <= 0 ? 1 : _arg(cpu, 1);
    if (sema.count < count) return 0x800201a8;
    sema.count -= count;
    return 0;
  }

  int? _signalSema(Allegrex cpu, PspImport? _) {
    final id = _arg(cpu, 0);
    final sema = _semas[id];
    if (sema == null) return 0x80020198;
    sema.count += _arg(cpu, 1) <= 0 ? 1 : _arg(cpu, 1);
    if (sema.count > sema.max) sema.count = sema.max;
    for (final thread in threads.values) {
      if (thread.status == PspThreadStatus.waitSema &&
          thread.waitSema == id &&
          sema.count >= thread.waitCount) {
        sema.count -= thread.waitCount;
        thread.status = PspThreadStatus.ready;
        thread.pendingResult = 0;
      }
    }
    _preempt(cpu);
    return 0;
  }

  // Lightweight mutexes. The state lives in a kernel table keyed by the
  // workarea address and is mirrored into the workarea (level, owner,
  // attribute, waiter count, uid) after every change.

  void _writeLwMutex(int at, _LwMutex mutex) {
    var waiters = 0;
    for (final thread in threads.values) {
      if (thread.status == PspThreadStatus.waitLwMutex &&
          thread.waitLw == at) {
        waiters++;
      }
    }
    mem.write32(at, mutex.count);
    mem.write32(at + 4, mutex.owner);
    mem.write32(at + 8, mutex.attr);
    mem.write32(at + 12, waiters);
    mem.write32(at + 16, mutex.uid);
  }

  int? _createLwMutex(Allegrex cpu, PspImport? _) {
    final at = PspMemory.physical(_arg(cpu, 0));
    if (at == 0) return 0x80020198;
    final mutex = _LwMutex(_arg(cpu, 2), _nextId++);
    final initial = _arg(cpu, 3);
    if (initial > 0) {
      mutex.owner = current?.id ?? 0;
      mutex.count = initial;
    }
    _lwMutexes[at] = mutex;
    _writeLwMutex(at, mutex);
    return 0;
  }

  int? _deleteLwMutex(Allegrex cpu, PspImport? _) {
    final at = PspMemory.physical(_arg(cpu, 0));
    if (_lwMutexes.remove(at) == null) return 0x80020198;
    for (final thread in threads.values) {
      if (thread.status == PspThreadStatus.waitLwMutex &&
          thread.waitLw == at) {
        thread.status = PspThreadStatus.ready;
        thread.pendingResult = 0x80020198;
      }
    }
    for (var i = 0; i < 5; i++) {
      mem.write32(at + i * 4, 0);
    }
    return 0;
  }

  int? _lockLwMutex(Allegrex cpu, {required bool blocking}) {
    final at = PspMemory.physical(_arg(cpu, 0));
    final mutex = _lwMutexes[at];
    if (mutex == null) return 0x80020198;
    final count = _arg(cpu, 1) <= 0 ? 1 : _arg(cpu, 1);
    if (mutex.count == 0) {
      mutex.owner = current?.id ?? 0;
      mutex.count = count;
      _writeLwMutex(at, mutex);
      return 0;
    }
    if (mutex.owner == current?.id && mutex.attr & 0x200 != 0) {
      mutex.count += count;
      _writeLwMutex(at, mutex);
      return 0;
    }
    // A thread that already owns a non-recursive mutex can never be
    // woken again if it waits on itself, so the lock fails at once
    // instead of blocking; the SDK libc glue nests stdio locks and
    // relies on this, ignoring the error.
    if (mutex.owner == current?.id) return 0x800201b9;
    if (!blocking || _inCallback) return 0x800201b9;
    final timeout = _arg(cpu, 2);
    if (timeout != 0 && mem.read32(timeout) == 0) return 0x800201b9;
    current!.status = PspThreadStatus.waitLwMutex;
    current!.waitLw = at;
    current!.waitCount = count;
    _writeLwMutex(at, mutex);
    _schedule(cpu);
    return null;
  }

  int? _unlockLwMutex(Allegrex cpu, PspImport? _) {
    final at = PspMemory.physical(_arg(cpu, 0));
    final mutex = _lwMutexes[at];
    if (mutex == null || mutex.owner != current?.id) return 0x80020198;
    final count = _arg(cpu, 1) <= 0 ? 1 : _arg(cpu, 1);
    mutex.count -= count;
    if (mutex.count > 0) {
      _writeLwMutex(at, mutex);
      return 0;
    }
    mutex.count = 0;
    mutex.owner = 0;
    // Hand the mutex to the highest priority waiter, if any.
    PspThread? next;
    for (final thread in threads.values) {
      if (thread.status == PspThreadStatus.waitLwMutex &&
          thread.waitLw == at &&
          (next == null || thread.priority < next.priority)) {
        next = thread;
      }
    }
    if (next != null) {
      mutex.owner = next.id;
      mutex.count = next.waitCount;
      next.status = PspThreadStatus.ready;
      next.pendingResult = 0;
    }
    _writeLwMutex(at, mutex);
    _preempt(cpu);
    return 0;
  }

  int? _referThreadStatus(Allegrex cpu, PspImport? _) {
    var id = _arg(cpu, 0);
    if (id == 0) id = current?.id ?? 0;
    final thread = threads[id];
    final at = _arg(cpu, 1);
    if (thread == null || at == 0) return 0x80020198;
    final status = switch (thread.status) {
      PspThreadStatus.running => 0x01,
      PspThreadStatus.ready => 0x02,
      PspThreadStatus.dead => 0x10,
      PspThreadStatus.dormant => 0x20,
      _ => 0x04, // every wait state
    };
    mem.write32(at, 104);
    final name = thread.name;
    for (var i = 0; i < 32; i++) {
      mem.write8(at + 4 + i, i < name.length ? name.codeUnitAt(i) : 0);
    }
    mem.write32(at + 36, 0);
    mem.write32(at + 40, status);
    mem.write32(at + 44, thread.entry);
    mem.write32(at + 48, thread.stackTop - thread.stackSize);
    mem.write32(at + 52, thread.stackSize);
    mem.write32(at + 56, thread.state.r[28]);
    mem.write32(at + 60, thread.priority);
    mem.write32(at + 64, thread.priority);
    mem.write32(at + 68, 0);
    mem.write32(at + 72, 0);
    mem.write32(at + 76, 0);
    mem.write32(at + 80, thread.exitStatus);
    mem.write32(at + 84, cpu.clocks & 0xffffffff);
    mem.write32(at + 88, cpu.clocks >>> 32);
    return 0;
  }

  int? _allocBlock(Allegrex cpu, PspImport? _) {
    final size = (_arg(cpu, 3) + 0xffff) & ~0xffff;
    // Heap blocks and thread stacks share the user partition: blocks
    // grow up from the module image, stacks grow down from its top,
    // and a block may not cross the current stack frontier.
    if (_heapAt + size > _stackAt) return 0x800200d9;
    final id = _nextId++;
    _blocks[id] = _Block(_heapAt, size);
    _heapAt += size;
    return id;
  }

  int? _readCtrl(Allegrex cpu, PspImport? _) {
    final at = _arg(cpu, 0);
    if (at == 0) return 0;
    var buttons = 0;
    void bit(PadButton button, int mask) {
      if (pad.isPressed(0, button)) buttons |= mask;
    }

    bit(const PadButton('Select'), 0x0001);
    bit(const PadButton('Start'), 0x0008);
    bit(PadButton.up, 0x0010);
    bit(PadButton.right, 0x0020);
    bit(PadButton.down, 0x0040);
    bit(PadButton.left, 0x0080);
    bit(const PadButton('L'), 0x0100);
    bit(const PadButton('R'), 0x0200);
    bit(const PadButton('Home'), 0x010000);
    bit(const PadButton('^'), 0x1000);
    bit(const PadButton('o'), 0x2000);
    bit(const PadButton('x'), 0x4000);
    bit(const PadButton('#'), 0x8000);
    final lx =
        (0x80 + pad.axis(0, PadAxis.leftX).clamp(-1.0, 1.0) * 127).round();
    final ly =
        (0x80 + pad.axis(0, PadAxis.leftY).clamp(-1.0, 1.0) * 127).round();
    mem.write32(at, cpu.clocks ~/ _clocksPerMicrosecond);
    mem.write32(at + 4, buttons);
    mem.write8(at + 8, lx);
    mem.write8(at + 9, ly);
    mem.write8(at + 10, 0x80);
    mem.write8(at + 11, 0x80);
    for (var i = 12; i < 16; i++) {
      mem.write8(at + i, 0);
    }
    return 1;
  }

  /// The device prefix of a guest path, lowercased, or null.
  static String? _deviceOf(String path) {
    final colon = path.indexOf(':');
    return colon < 0 ? null : path.substring(0, colon).toLowerCase();
  }

  /// Splits a guest path into the device it lives on and the path
  /// relative to that device's root. Relative paths resolve against
  /// the current directory, which is itself device-qualified.
  (String, String) _resolve(String path) {
    final device = _deviceOf(path);
    if (device != null) {
      return (device, path.substring(path.indexOf(':') + 1));
    }
    final joined = '$_cwd$path';
    final colon = joined.indexOf(':');
    return (joined.substring(0, colon).toLowerCase(),
        joined.substring(colon + 1));
  }

  int? _ioOpen(Allegrex cpu, PspImport? _) {
    final path = mem.readString(_arg(cpu, 0), 256);
    final flags = _arg(cpu, 1);
    final (device, rel) = _resolve(path);
    if (device == 'disc0' || device == 'umd0') {
      // The disc is read-only: write modes and creation fail, as do
      // missing files and directories opened as files.
      if (flags & 3 == 2 || flags & 3 == 3 || flags & 0x0f00 != 0) {
        return 0x80010002;
      }
      final node = disc?.lookup(rel);
      if (node == null || node.isDirectory) return 0x80010002;
      final fd = _nextFd++;
      _files[fd] = _OpenFile.disc(path, node);
      return fd;
    }
    if (device == 'ms0') {
      var node = memStick.lookup(rel);
      if (node == null) {
        // Without the creation flag a missing file fails; with it,
        // the file appears as long as its directory exists.
        if (flags & 0x0200 == 0) return 0x80010002;
        node = memStick.createFile(rel);
        if (node == null) return 0x80010002;
        memStick.flush();
      } else {
        if (node.isDirectory) return 0x80010002;
        if (flags & 0x0a00 == 0x0a00) return 0x80010002;
        if (flags & 0x0400 != 0 && flags & 3 != 1) {
          node.content.clear();
          node.modified = _nowSeconds;
        }
      }
      final fd = _nextFd++;
      final file = _OpenFile.stick(
          path, node, flags & 3 == 0 ? 1 : flags & 3, flags & 0x0100 != 0);
      if (file.append) file.position = node.content.length;
      _files[fd] = file;
      return fd;
    }
    final fd = _nextFd++;
    _files[fd] = _OpenFile(path);
    return fd;
  }

  int? _ioOpenAsync(Allegrex cpu, PspImport? _) {
    final fd = _ioOpen(cpu, null);
    if (fd != null && fd >= 0) _async[fd] = fd;
    return fd;
  }

  int? _ioRead(Allegrex cpu, PspImport? _) => _readFile(cpu, true);

  /// Reads from an open file. A disc read whose sectors the drive has
  /// not loaded yet suspends the calling thread instead of reporting a
  /// short read: the drive loads in the background, and the scheduler
  /// retries the read as emulated time passes, the way a real read
  /// waits for the disc. After about 200 ms of emulated time the read
  /// gives up and reports zero bytes. Asynchronous reads never suspend;
  /// they report what is available at once.
  int? _readFile(Allegrex cpu, bool mayBlock) {
    final fd = _arg(cpu, 0);
    final file = _files[fd];
    if (file == null) return 0;
    final at = _arg(cpu, 1), length = _arg(cpu, 2);
    final node = file.node;
    if (node != null) {
      final data = disc?.readBytes(node.entry, file.position, length);
      if (data == null) {
        if (!mayBlock || _inCallback || current == null) return 0;
        _discWaits[current!.id] = _DiscWait(fd, at, length);
        current!.status = PspThreadStatus.waitDisc;
        current!.wakeAt = cpu.clocks + _cpuHz ~/ 1000;
        if (current!.wakeAt < _nextDelayWake) {
          _nextDelayWake = current!.wakeAt;
        }
        _schedule(cpu);
        return null;
      }
      mem.writeBytes(at, data);
      file.position += data.length;
      return data.length;
    }
    final msNode = file.msNode;
    if (msNode != null) {
      if (file.access == 2) return 0x80010002;
      var read = 0;
      while (read < length && file.position < msNode.content.length) {
        mem.write8(at + read, msNode.content[file.position++]);
        read++;
      }
      return read;
    }
    var read = 0;
    while (read < length && file.position < file.content.length) {
      mem.write8(at + read, file.content[file.position++]);
      read++;
    }
    return read;
  }

  /// Retries the suspended disc reads whose time has come; called from
  /// [wakeDue] alongside the delay threads.
  void _retryDiscWaits(Allegrex cpu) {
    for (final thread in threads.values) {
      if (thread.status != PspThreadStatus.waitDisc) continue;
      if (thread.wakeAt > cpu.clocks) {
        if (thread.wakeAt < _nextDelayWake) _nextDelayWake = thread.wakeAt;
        continue;
      }
      final wait = _discWaits[thread.id];
      final file = wait == null ? null : _files[wait.fd];
      final node = file?.node;
      final data = node == null
          ? null
          : disc?.readBytes(node.entry, file!.position, wait!.length);
      if (data != null) {
        mem.writeBytes(wait!.at, data);
        file!.position += data.length;
        thread.pendingResult = data.length;
      } else if (wait != null && wait.attempts < 200) {
        wait.attempts++;
        thread.wakeAt = cpu.clocks + _cpuHz ~/ 1000;
        if (thread.wakeAt < _nextDelayWake) _nextDelayWake = thread.wakeAt;
        continue;
      } else {
        // The file is gone, the wait was restored from a save state
        // without its entry, or the drive never delivered: the read
        // completes with zero bytes.
        thread.pendingResult = 0;
      }
      _discWaits.remove(thread.id);
      thread.status = PspThreadStatus.ready;
    }
  }

  int? _ioReadAsync(Allegrex cpu, PspImport? _) {
    final fd = _arg(cpu, 0);
    if (!_files.containsKey(fd)) return 0x80010002;
    _async[fd] = _readFile(cpu, false) ?? 0;
    return 0;
  }

  int? _ioWrite(Allegrex cpu, PspImport? _) {
    final fd = _arg(cpu, 0), at = _arg(cpu, 1), length = _arg(cpu, 2);
    if (fd == 1 || fd == 2) {
      log.write(mem.readString(at, length));
      return length;
    }
    final file = _files[fd];
    if (file == null || file.node != null) return 0x80010002;
    final msNode = file.msNode;
    if (msNode != null) {
      if (file.access == 1) return 0x80010002;
      if (file.append) file.position = msNode.content.length;
      final bytes = mem.readBytes(at, length);
      while (msNode.content.length < file.position) {
        msNode.content.add(0);
      }
      for (var i = 0; i < length; i++) {
        final at = file.position + i;
        if (at < msNode.content.length) {
          msNode.content[at] = bytes[i];
        } else {
          msNode.content.add(bytes[i]);
        }
      }
      file.position += length;
      file.dirty = true;
      msNode.modified = _nowSeconds;
      return length;
    }
    for (var i = 0; i < length; i++) {
      final byte = mem.read8(at + i);
      if (file.position < file.content.length) {
        file.content[file.position] = byte;
      } else {
        file.content.add(byte);
      }
      file.position++;
    }
    return length;
  }

  int? _ioWriteAsync(Allegrex cpu, PspImport? _) {
    final fd = _arg(cpu, 0);
    if (!_files.containsKey(fd)) return 0x80010002;
    _async[fd] = _ioWrite(cpu, null) ?? 0;
    return 0;
  }

  int? _ioClose(Allegrex cpu, PspImport? _) {
    final fd = _arg(cpu, 0);
    final file = _files.remove(fd);
    if (file != null && file.dirty) memStick.flush();
    _dirs.remove(fd);
    _async.remove(fd);
    return 0;
  }

  static int _seek(_OpenFile file, int offset, int whence) {
    var position = switch (whence) {
      0 => offset,
      1 => file.position + offset,
      _ => file.size + offset,
    };
    if (position < 0) position = 0;
    file.position = position;
    return position;
  }

  int? _ioLseek32(Allegrex cpu, PspImport? _) {
    final file = _files[_arg(cpu, 0)];
    if (file == null) return 0x80010002;
    return _seek(file, _arg(cpu, 1), _arg(cpu, 2));
  }

  /// The 64-bit seek: the offset travels in the a2/a3 pair (a1 is the
  /// alignment pad) and the whence in t0, and the result is returned
  /// in the v0/v1 pair.
  int? _ioLseek(Allegrex cpu, PspImport? _) {
    final file = _files[_arg(cpu, 0)];
    if (file == null) return 0x80010002;
    final offset =
        (cpu.r[7] & 0xffffffff) << 32 | (cpu.r[6] & 0xffffffff);
    final position = _seek(file, offset, cpu.r[8]);
    cpu.r[2] = position & 0xffffffff;
    cpu.r[3] = (position >> 32) & 0xffffffff;
    return null;
  }

  int? _ioLseek32Async(Allegrex cpu, PspImport? _) {
    final fd = _arg(cpu, 0);
    if (!_files.containsKey(fd)) return 0x80010002;
    _async[fd] = _ioLseek32(cpu, null) ?? 0;
    return 0;
  }

  int? _ioLseekAsync(Allegrex cpu, PspImport? _) {
    final fd = _arg(cpu, 0);
    final file = _files[fd];
    if (file == null) return 0x80010002;
    final offset =
        (cpu.r[7] & 0xffffffff) << 32 | (cpu.r[6] & 0xffffffff);
    _async[fd] = _seek(file, offset, cpu.r[8]);
    return 0;
  }

  int? _ioPollAsync(Allegrex cpu, PspImport? _) {
    final result = _async.remove(_arg(cpu, 0)) ?? 0;
    final at = _arg(cpu, 1);
    if (at != 0) {
      mem.write32(at, result & 0xffffffff);
      mem.write32(at + 4, (result >> 32) & 0xffffffff);
    }
    return 0;
  }

  int? _ioGetstat(Allegrex cpu, PspImport? _) {
    final (device, rel) = _resolve(mem.readString(_arg(cpu, 0), 256));
    final at = _arg(cpu, 1);
    if (device == 'disc0' || device == 'umd0') {
      final node = disc?.lookup(rel);
      if (node == null) return 0x80010002;
      _writeStatEnt(at, _DirEnt.disc(node, node.entry.name), false);
      return 0;
    }
    if (device == 'ms0') {
      final node = memStick.lookup(rel);
      if (node == null) return 0x80010002;
      _writeStatEnt(at, _DirEnt.stick(node, node.name), true);
      return 0;
    }
    return 0x80010002;
  }

  /// Fills the 88-byte file status structure for [ent]: the mode and
  /// attribute describe the kind, read-only on the disc and writable
  /// on the stick, and all three timestamps are the entry's date.
  void _writeStatEnt(int at, _DirEnt ent, bool writable) {
    if (at == 0) return;
    for (var i = 0; i < 88; i += 4) {
      mem.write32(at + i, 0);
    }
    mem.write32(
        at,
        ent.isDirectory
            ? 0x1000 | (writable ? 0x1ed : 0x16d)
            : 0x2000 | (writable ? 0x1a4 : 0x124));
    mem.write32(at + 4, ent.isDirectory ? 0x10 : 0x20);
    mem.write32(at + 8, ent.size & 0xffffffff);
    mem.write32(at + 12, (ent.size >> 32) & 0xffffffff);
    for (final base in [16, 32, 48]) {
      mem.write16(at + base, ent.year);
      mem.write8(at + base + 2, ent.month);
      mem.write8(at + base + 3, ent.day);
      mem.write8(at + base + 4, ent.hour);
      mem.write8(at + base + 5, ent.minute);
      mem.write8(at + base + 6, ent.second);
    }
  }

  int? _ioDopen(Allegrex cpu, PspImport? _) {
    final (device, rel) = _resolve(mem.readString(_arg(cpu, 0), 256));
    if (device == 'disc0' || device == 'umd0') {
      final node = disc?.lookup(rel);
      if (node == null || !node.isDirectory) return 0x80010002;
      final fd = _nextFd++;
      _dirs[fd] = _OpenDir([
        _DirEnt.disc(node, '.'),
        _DirEnt.disc(node.parent ?? node, '..'),
        for (final child in node.children)
          _DirEnt.disc(child, child.entry.name),
      ]);
      return fd;
    }
    if (device == 'ms0') {
      final node = memStick.lookup(rel);
      if (node == null || !node.isDirectory) return 0x80010002;
      final fd = _nextFd++;
      _dirs[fd] = _OpenDir([
        _DirEnt.stick(node, '.'),
        _DirEnt.stick(node.parent ?? node, '..'),
        for (final child in node.children.values)
          _DirEnt.stick(child, child.name),
      ]);
      return fd;
    }
    return 0x80010002;
  }

  int? _ioDread(Allegrex cpu, PspImport? _) {
    final dir = _dirs[_arg(cpu, 0)];
    if (dir == null) return 0x80010002;
    if (dir.index >= dir.entries.length) return 0;
    final ent = dir.entries[dir.index++];
    final at = _arg(cpu, 1);
    if (at != 0) {
      _writeStatEnt(at, ent, false);
      for (var i = 0; i < 256; i++) {
        mem.write8(at + 88 + i,
            i < ent.name.length ? ent.name.codeUnitAt(i) & 0xff : 0);
      }
      mem.write32(at + 344, 0);
      mem.write32(at + 348, 0);
    }
    return 1;
  }

  int? _ioMkdir(Allegrex cpu, PspImport? _) {
    final (device, rel) = _resolve(mem.readString(_arg(cpu, 0), 256));
    if (device != 'ms0') return 0x80010002;
    if (memStick.mkdir(rel) == null) return 0x80010002;
    memStick.flush();
    return 0;
  }

  int? _ioRemove(Allegrex cpu, PspImport? _) {
    final (device, rel) = _resolve(mem.readString(_arg(cpu, 0), 256));
    if (device != 'ms0') return 0x80010002;
    final node = memStick.lookup(rel);
    if (node == null || !memStick.remove(node)) return 0x80010002;
    memStick.flush();
    return 0;
  }

  int? _ioRename(Allegrex cpu, PspImport? _) {
    final (oldDevice, oldRel) = _resolve(mem.readString(_arg(cpu, 0), 256));
    final (newDevice, newRel) = _resolve(mem.readString(_arg(cpu, 1), 256));
    if (oldDevice != 'ms0' || newDevice != 'ms0') return 0x80010002;
    final node = memStick.lookup(oldRel);
    if (node == null || !memStick.rename(node, newRel)) {
      return 0x80010002;
    }
    memStick.flush();
    return 0;
  }

  int? _ioChdir(Allegrex cpu, PspImport? _) {
    final path = mem.readString(_arg(cpu, 0), 256);
    final (device, rel) = _resolve(path);
    String? canonical;
    if (device == 'disc0' || device == 'umd0') {
      final node = disc?.lookup(rel);
      if (node != null && node.isDirectory) {
        final parts = <String>[];
        var walk = node;
        while (walk.parent != null) {
          parts.add(walk.entry.name);
          walk = walk.parent!;
        }
        canonical = parts.reversed.join('/');
      }
    } else if (device == 'ms0') {
      final node = memStick.lookup(rel);
      if (node != null && node.isDirectory) canonical = node.path;
    }
    if (canonical == null) return 0x80010002;
    _cwd = canonical.isEmpty ? '$device:/' : '$device:/$canonical/';
    return 0;
  }

  int? _ioSync(Allegrex cpu, PspImport? _) {
    memStick.flush();
    return 0;
  }

  int? _ioDclose(Allegrex cpu, PspImport? _) {
    _dirs.remove(_arg(cpu, 0));
    return 0;
  }

  /// Writes the kernel section of a saved state. The running thread's
  /// saved state is refreshed from the live processor first.
  void saveState(StateWriter writer, Allegrex cpu) {
    final cur = current;
    if (cur != null && cur.status == PspThreadStatus.running) {
      cur.state.copyFrom(cpu);
    }
    writer.section('kernel');
    writer.int32(vcount);
    writer.int32(fbAddr);
    writer.int32(fbWidth);
    writer.int32(fbFormat);
    writer.boolean(displayOn);
    writer.boolean(exited);
    writer.int32(exitStatus);
    writer.int32(current?.id ?? 0);
    writer.int32(_nextId);
    writer.int32(_heapAt);
    writer.int32(_stackAt);
    writer.int32(threads.length);
    for (final thread in threads.values) {
      writer.int32(thread.id);
      writer.string(thread.name);
      writer.int32(thread.entry);
      writer.int32(thread.priority);
      writer.int32(thread.status);
      writer.int32(thread.stackTop);
      writer.int32(thread.stackSize);
      writer.int64(thread.wakeAt);
      writer.int32(thread.waitSema);
      writer.int32(thread.waitCount);
      writer.int32(thread.waitJoin);
      writer.int32(thread.waitLw);
      writer.int32(thread.exitStatus);
      writer.boolean(thread.pendingResult != null);
      writer.int32(thread.pendingResult ?? 0);
      thread.state.saveState(writer);
    }
    writer.int32(_semas.length);
    for (final entry in _semas.entries) {
      writer.int32(entry.key);
      writer.int32(entry.value.count);
      writer.int32(entry.value.max);
    }
    writer.int32(_lwMutexes.length);
    for (final entry in _lwMutexes.entries) {
      writer.int32(entry.key);
      writer.int32(entry.value.attr);
      writer.int32(entry.value.uid);
      writer.int32(entry.value.owner);
      writer.int32(entry.value.count);
    }
    writer.int32(_blocks.length);
    for (final entry in _blocks.entries) {
      writer.int32(entry.key);
      writer.int32(entry.value.addr);
      writer.int32(entry.value.size);
    }
    for (final channel in _audioChannels) {
      writer.boolean(channel.reserved);
      writer.int32(channel.sampleCount);
      writer.int32(channel.format);
      writer.int64(channel.nextAt);
    }
    writer.int64(_mixBase);
    writer.floats(_mix);
    ge.saveState(writer);
    writer.boolean(_rtcAnchorTick != null);
    writer.int64(_rtcAnchorTick ?? 0);
    writer.int64(_rtcAnchorClocks);
    writer.int32(_rtcLocalOffset);
    writer.int64(_rng);
  }

  void loadState(StateReader reader, {required bool legacy}) {
    reader.section('kernel');
    vcount = reader.int32();
    fbAddr = reader.int32();
    fbWidth = reader.int32();
    fbFormat = reader.int32();
    displayOn = reader.boolean();
    exited = reader.boolean();
    exitStatus = reader.int32();
    final currentId = reader.int32();
    _nextId = reader.int32();
    _heapAt = reader.int32();
    _stackAt = reader.int32();
    threads.clear();
    final threadCount = reader.int32();
    for (var i = 0; i < threadCount; i++) {
      final id = reader.int32();
      final name = reader.string();
      final entry = reader.int32();
      final priority = reader.int32();
      final status = reader.int32();
      final stackTop = reader.int32();
      final stackSize = reader.int32();
      final thread = PspThread(id, name, entry, priority, stackTop, stackSize);
      thread.status = status;
      thread.wakeAt = legacy ? reader.int32().toUnsigned(32) : reader.int64();
      thread.waitSema = reader.int32();
      thread.waitCount = reader.int32();
      thread.waitJoin = reader.int32();
      thread.waitLw = reader.int32();
      thread.exitStatus = reader.int32();
      final hasPending = reader.boolean();
      final pending = reader.int32();
      thread.pendingResult = hasPending ? pending : null;
      thread.state.loadState(reader, hasVfpu: !legacy);
      threads[id] = thread;
    }
    _semas.clear();
    final semaCount = reader.int32();
    for (var i = 0; i < semaCount; i++) {
      final id = reader.int32();
      _semas[id] = _Sema(reader.int32(), reader.int32());
    }
    _lwMutexes.clear();
    final lwCount = reader.int32();
    for (var i = 0; i < lwCount; i++) {
      final at = reader.int32();
      final mutex = _LwMutex(reader.int32(), reader.int32());
      mutex.owner = reader.int32();
      mutex.count = reader.int32();
      _lwMutexes[at] = mutex;
    }
    _blocks.clear();
    final blockCount = reader.int32();
    for (var i = 0; i < blockCount; i++) {
      final id = reader.int32();
      _blocks[id] = _Block(reader.int32(), reader.int32());
    }
    for (final channel in _audioChannels) {
      channel.reserved = reader.boolean();
      channel.sampleCount = reader.int32();
      channel.format = reader.int32();
      channel.nextAt = legacy ? reader.int32() : reader.int64();
    }
    _mixBase = legacy ? reader.int32() : reader.int64();
    _mix
      ..clear()
      ..addAll(reader.floats());
    ge.loadState(reader);
    final hasRtcAnchor = !legacy && reader.boolean();
    final rtcAnchor = legacy ? 0 : reader.int64();
    _rtcAnchorTick = hasRtcAnchor ? rtcAnchor : null;
    _rtcAnchorClocks = legacy ? 0 : reader.int64();
    _rtcLocalOffset = legacy ? 0 : reader.int32();
    _rng = legacy ? 0x2545f491 : reader.int64();
    _discWaits.clear();
    current = threads[currentId];
    _nextDelayWake = 0x7fffffffffffffff;
    for (final thread in threads.values) {
      if ((thread.status == PspThreadStatus.waitDelay ||
              thread.status == PspThreadStatus.waitDisc) &&
          thread.wakeAt < _nextDelayWake) {
        _nextDelayWake = thread.wakeAt;
      }
    }
  }
}

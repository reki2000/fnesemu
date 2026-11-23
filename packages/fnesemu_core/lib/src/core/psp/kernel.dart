import 'dart:collection';
import 'dart:typed_data';

import '../../media_decoder.dart';
import '../../pad_button.dart';
import '../../pad_source.dart';
import '../../util/state.dart';
import 'allegrex.dart';
import 'atrac.dart';
import 'disc.dart';
import 'elf.dart';
import 'ge.dart';
import 'memory.dart';
import 'memstick.dart';
import 'mpeg.dart';
import 'printf.dart';
import 'rtc.dart';
import 'sas.dart';
import 'utility.dart';

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
  static const waitEvent = 11;
  static const waitMbx = 12;
  static const waitAsync = 13;
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
  int wakeupCount = 0; // wake-ups that arrived while not sleeping
  // An event flag wait: the flag, the bits, the mode and where the
  // pattern goes on release. A vblank wait returns [waitBits].
  int waitEvent = 0, waitBits = 0, waitMode = 0, waitOutAt = 0;
  int exitStatus = 0;
  bool cbWait = false; // blocked in a CB wait: notified callbacks run at once
  PspImport? lastCall; // the last kernel call, for the state report
  int? pendingResult;
  final state = AllegrexState();
  PspThread(this.id, this.name, this.entry, this.priority, this.stackTop,
      this.stackSize);
}

/// A callback: a function the kernel runs on its owner thread, with the
/// notification count and argument, when that thread waits in a CB call.
class _Callback {
  final int thread;
  final int func;
  final int common;
  int count = 0;
  int arg = 0;
  _Callback(this.thread, this.func, this.common);
}

/// A ring buffer put in progress on a thread: the packets still wanted,
/// the packets put so far and where the put returns to.
class _Put {
  int want;
  int done;
  final int returnAt;
  _Put(this.want, this.done, this.returnAt);
}

class _EventFlag {
  int pattern;
  final int attr;
  _EventFlag(this.pattern, this.attr);
}

class _Sema {
  int count;
  final int max;
  _Sema(this.count, this.max);
}

/// A message box: the messages are guest pointers, kept in the order sent.
class _Mbx {
  final messages = <int>[];
}

/// A mutex behind an id. A thread that already owns it may lock it again,
/// and the lock is given to a waiting thread when the count reaches zero.
class _Mutex {
  int owner = 0;
  int count = 0;
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

/// A registered sub-interrupt handler, called with its sub-interrupt
/// number and [arg].
class _SubIntr {
  final int func, arg;
  bool enabled = false;
  _SubIntr(this.func, this.arg);
}

class _Block {
  final int addr;
  final int size;
  _Block(this.addr, this.size);
}

/// A fixed-size pool: [count] blocks of [blockSize] bytes from [addr],
/// with a flag per block that is in use.
class _Fpl {
  final int addr;
  final int blockSize;
  final List<bool> used;
  _Fpl(this.addr, this.blockSize, int count)
      : used = List.filled(count, false);
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

  /// The bytes of the unit of [position], [size] and the lengths of reads:
  /// a sector of 2048 bytes for the raw disc device, a byte otherwise.
  final int unit;
  int position = 0;
  _OpenFile(this.path)
      : node = null,
        msNode = null,
        access = 3,
        append = false,
        unit = 1;
  _OpenFile.disc(this.path, this.node, {this.unit = 1})
      : msNode = null,
        access = 1,
        append = false;
  _OpenFile.stick(this.path, this.msNode, this.access, this.append)
      : node = null,
        unit = 1;

  int get size =>
      (node?.entry.size ?? msNode?.content.length ?? content.length) ~/ unit;
}

/// One directory entry as the guest sees it, from either file system.
class _DirEnt {
  final String name;
  final bool isDirectory;
  final int size;
  final int year, month, day, hour, minute, second;

  /// The first sector of a disc file, which the status structure reports
  /// in its first private word; zero elsewhere.
  final int lba;
  const _DirEnt(this.name, this.isDirectory, this.size, this.year,
      this.month, this.day, this.hour, this.minute, this.second,
      [this.lba = 0]);

  factory _DirEnt.disc(PspDiscNode node, String name) => _DirEnt(
      name,
      node.entry.isDirectory,
      node.entry.size,
      node.entry.year,
      node.entry.month,
      node.entry.day,
      node.entry.hour,
      node.entry.minute,
      node.entry.second,
      node.entry.lba);

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
  int loaded = 0; // the bytes found loaded at the last attempt
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
/// the sound synthesizer (sceSasCore), file access (in-memory files, the mounted disc and the memory
/// stick), the real-time clock and a few utility calls. Unknown calls return zero, which most software treats as
/// success or as an idle dialog state.
class PspKernel {
  final PspMemory mem;
  final PadPort pad;

  /// The graphics engine; its lists run synchronously from the system
  /// calls below and its callbacks re-enter the processor through
  /// [_runHandler].
  late final PspGe ge;
  bool _inCallback = false;
  bool _interruptsEnabled = true;

  /// Handlers called while interrupts were disabled, as (function, first
  /// argument, second argument), run when they are enabled again.
  final _pendingHandlers = Queue<(int, int, int)>();

  /// The sub-interrupt handlers by (interrupt, sub-interrupt).
  final _subIntrs = <(int, int), _SubIntr>{};
  static const _vblankInterrupt = 30;
  static const _volatileAt = 0x08400000, _volatileSize = 0x400000;

  /// Receives mixed stereo samples at 44100 Hz from [flushAudio].
  void Function(Float32List samples)? audioSink;

  final _audioChannels = List.generate(8, (_) => _AudioChannel());
  late final _sas = PspSas(mem);
  late final _mpeg = PspMpeg(mem);
  late final _atrac = PspAtrac(mem);
  late final _savedata = PspSavedataDialog(mem, () => _memStick);
  late final _msgDialog = PspMessageDialog(mem);
  late final _keyboard = PspKeyboardDialog(mem);

  /// Decodes the movies; null plays them with black pictures.
  set mediaDecoder(MediaDecoder? decoder) {
    _mpeg.closeVideo();
    _mpeg.decoder = decoder;
    _atrac
      ..closeAll()
      ..decoder = decoder;
  }
  final _puts = <int, _Put>{};

  /// Set by a handler that sent the processor into guest code of its own
  /// instead of back to the caller.
  bool _redirected = false;

  /// The second stereo output (sceAudioOutput2), outside the eight
  /// channels.
  final _output2 = _AudioChannel();
  final _mix = <double>[];
  int _mixBase = 0;
  final _handlers = <int, int? Function(Allegrex, PspImport?)>{};
  final _byCode = <int, PspImport>{};
  final threads = <int, PspThread>{};
  final _semas = <int, _Sema>{};
  final _eventFlags = <int, _EventFlag>{};
  final _callbacks = <int, _Callback>{};
  final _lwMutexes = <int, _LwMutex>{};
  final _mutexes = <int, _Mutex>{};
  final _mbxs = <int, _Mbx>{};
  final _blocks = <int, _Block>{};
  final _fpls = <int, _Fpl>{};
  final unknownCalls = <int, int>{};

  /// one line per entry of [unknownCalls]: the library, the NID and the
  /// number of calls
  Iterable<String> get unknownCallLines => unknownCalls.entries.map((e) {
        final library =
            _byCode.values.where((i) => i.nid == e.key).firstOrNull?.library;
        return '$library 0x${e.key.toRadixString(16).padLeft(8, '0')} '
            'x${e.value}';
      });
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

  /// Disc reads started by sceIoReadAsync whose sectors the drive has not
  /// loaded yet, by file. They finish when the sectors arrive, or after
  /// about 200 ms of emulated time without new sectors with zero bytes.
  final _asyncPending = <int, _DiscWait>{};

  /// The completion callback of an open file: the callback id and the
  /// argument pointer given to sceIoSetAsyncCallback, which is not used.
  final _asyncCallbacks = <int, (int, int)>{};

  /// Records the result of an asynchronous call on [fd] and notifies the
  /// completion callback of the file. The callback gets the file and the
  /// result.
  void _asyncDone(int fd, int result) {
    _async[fd] = result;
    _notifyAsync(fd);
  }

  void _notifyAsync(int fd) {
    final result = _async[fd] ?? 0;
    final registered = _asyncCallbacks[fd];
    final callback = registered == null ? null : _callbacks[registered.$1];
    if (callback == null) return;
    callback.count = fd;
    callback.arg = result & 0xffffffff;
    _wakeCallbackOwner(callback);
  }
  int _nextFd = 3;

  /// Descriptors closed by sceIoCloseAsync whose result no poll or wait
  /// has collected yet. Descriptors are not reused, so the result stays
  /// with the closed number.
  final _closedAsync = <int>{};

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

  late final PspModuleImage _mainModule;
  int _compiledSdkVersion = 0;

  /// The loaded modules: the main module and the modules it loaded, in
  /// load order. A loaded module's id is its index plus [_moduleIdBase].
  final _images = <PspModuleImage>[];
  static const _moduleIdBase = 0x01000000;
  int _nextImportCode = 1;
  int _compilerVersion = 0;
  int _nextId = 1;
  static const _mainModuleId = 0x01000000;
  static const displayHz = 60;
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
  int _stackAt = _mainStackTop - _mainStackSize;

  /// The lowest address the arena hands out again after a release. A
  /// state from before the arena kept the loaded modules in its blocks
  /// raises it to the heap top of that state.
  int _heapFloor;

  /// The clock frequencies in MHz that scePower reports and the game sets.
  /// They do not change the speed of the emulation.
  int _cpuMhz = 222, _busMhz = 111;
  int _nextDelayWake = 0x7fffffffffffffff;
  int _rng = 0x2545f491;

  static const _exitStubAt = 0x08000000;
  static const _callbackSentinelAt = 0x08000020;

  /// A guest function that the kernel calls on a thread returns here,
  /// to a syscall that resumes the kernel call that made it.
  static const _guestReturnAt = 0x08000040, _guestReturnCode = 0xfffff;
  static const _mainStackTop = PspMemory.ramEnd;
  static const _mainStackSize = 256 * 1024;

  PspKernel(this.mem, this.pad, int heapStart)
      : _heapAt = (heapStart + 0xffff) & ~0xffff,
        _heapFloor = (heapStart + 0xffff) & ~0xffff {
    ge = PspGe(mem);
    ge.callbackRunner = _runHandler;
    _registerHandlers();
  }

  /// Runs a graphics callback or an interrupt handler on the live
  /// processor with the caller's state saved around it, the way the
  /// system software invokes them from interrupt context. The callback
  /// returns to a sentinel that loops on itself; blocking calls made
  /// from a callback return at once instead of switching threads.
  void _runHandler(Allegrex cpu, int func, int id, int arg) {
    if (_inCallback || func == 0) return;
    if (!_interruptsEnabled) {
      _pendingHandlers.addLast((func, id, arg));
      return;
    }
    _runGuest(cpu, func, id, arg, 0);
  }

  /// Runs the guest function [func] with three arguments on the live
  /// processor up to its return and restores the processor. Returns the
  /// function's v0.
  int _runGuest(Allegrex cpu, int func, int a0, int a1, int a2) {
    _inCallback = true;
    final saved = AllegrexState()..copyFrom(cpu);
    cpu.r[4] = a0;
    cpu.r[5] = a1;
    cpu.r[6] = a2;
    cpu.r[31] = _callbackSentinelAt;
    cpu.pc = func;
    cpu.nextPc = func + 4;
    var budget = 200000;
    while (budget-- > 0 && cpu.pc != _callbackSentinelAt) {
      if (!cpu.step()) break;
    }
    final result = cpu.r[2];
    cpu.copyFrom(saved);
    _inCallback = false;
    return result;
  }

  /// Sends the thread into the ring buffer read callback for the next
  /// chunk of [put]. Returns false when nothing remains to read.
  bool _callPut(Allegrex cpu, _Put put) {
    final n = _mpeg.chunk(put.want);
    if (n <= 0 || _mpeg.callback == 0) return false;
    cpu.r[4] = _mpeg.putAt;
    cpu.r[5] = n;
    cpu.r[6] = _mpeg.callbackArg;
    cpu.r[31] = _guestReturnAt;
    cpu.pc = _mpeg.callback;
    cpu.nextPc = cpu.pc + 4;
    return true;
  }

  /// The read callback of a ring buffer put returned the packets it read
  /// in v0: the put asks for the next chunk, or returns the packets put
  /// to the caller when the request is met or the callback read nothing.
  void _putReturned(Allegrex cpu) {
    final put = current == null ? null : _puts[current!.id];
    if (put == null) return;
    final read = cpu.r[2].toSigned(32);
    // A callback that reads nothing has reached the end of the stream.
    if (read == 0) _mpeg.ended = true;
    if (read > 0) {
      _mpeg.put(read);
      put.done += read;
      put.want -= read;
    }
    if (read > 0 && put.want > 0 && _callPut(cpu, put)) return;
    _puts.remove(current!.id);
    cpu.r[2] = put.done > 0 || read >= 0 ? put.done : read;
    cpu.pc = put.returnAt;
    cpu.nextPc = put.returnAt + 4;
  }

  /// Records a notification of callback [id] with [arg]; it runs at the
  /// next CB call of its owner thread.
  void _notifyCallback(int id, int arg) {
    final callback = _callbacks[id];
    if (callback == null) return;
    callback.count++;
    callback.arg = arg;
    _wakeCallbackOwner(callback);
  }

  Allegrex? _liveCpu;

  /// A callback notified while its owner is blocked in a CB wait runs
  /// now, the way the wait would be interrupted to run it; the wait then
  /// goes on.
  void _wakeCallbackOwner(_Callback callback) {
    final owner = threads[callback.thread];
    final cpu = _liveCpu;
    if (owner == null || cpu == null || !owner.cbWait || _inCallback) return;
    _runCallbacks(cpu, owner);
  }

  /// Runs the notified callbacks of the current thread. A callback that
  /// returns nonzero is deleted. Returns whether any ran.
  bool _runCallbacks(Allegrex cpu, [PspThread? owner]) {
    final cur = owner ?? current;
    if (cur == null || _inCallback) return false;
    var ran = false;
    for (final id in _callbacks.keys.toList()) {
      final callback = _callbacks[id];
      if (callback == null ||
          callback.thread != cur.id ||
          callback.count == 0) {
        continue;
      }
      final count = callback.count;
      callback.count = 0;
      ran = true;
      if (_runGuest(cpu, callback.func, count, callback.arg,
              callback.common) !=
          0) {
        _callbacks.remove(id);
      }
    }
    return ran;
  }

  /// Prepares a loaded module: patches its stubs, writes the thread exit
  /// stub and creates the main thread. Returns the main thread.
  PspThread startModule(PspModuleImage image) {
    _mainModule = image;
    mem.write32(_exitStubAt, 0x0000000c); // syscall 0
    mem.write32(_exitStubAt + 4, 0x03e00008); // jr ra
    mem.write32(_exitStubAt + 8, 0); // nop
    // A jump to itself: graphics callbacks return here and stop.
    mem.write32(_callbackSentinelAt,
        0x08000000 | ((_callbackSentinelAt >> 2) & 0x3ffffff));
    mem.write32(_guestReturnAt, 0x0000000c | (_guestReturnCode << 6));
    _images.add(image);
    _linkImports(image);
    // The module may set the priority and stack size of the thread that
    // runs its entry point (module_start_thread_parameter: a word count,
    // the priority, the stack size and the attributes). The stack comes
    // from the top of user memory, so a small one leaves more for the
    // game.
    var priority = 0x20, stackSize = _mainStackSize;
    final parameter = image.exports[('', 0x0f7c276c)];
    if (parameter != null && mem.read32(parameter) >= 3) {
      if (mem.read32(parameter + 4) != 0) priority = mem.read32(parameter + 4);
      final size = mem.read32(parameter + 8);
      if (size != 0) {
        stackSize = ((size + 0xff) & ~0xff).clamp(0x400, _mainStackSize);
      }
    }
    _stackAt = _mainStackTop - stackSize;
    final main =
        _newThread('main', image.entry, priority, _mainStackTop, stackSize);
    main.status = PspThreadStatus.running;
    _prepareK0Area(main);
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

  /// Clears the 0x100 bytes at the top of the stack of [thread] and points
  /// its k0 register there. User code keeps per-thread data in this area
  /// through k0, such as the C library finding its reentrancy structure;
  /// the fields the kernel itself writes there are not filled in.
  void _prepareK0Area(PspThread thread) {
    final at = thread.stackTop - 0x100;
    for (var i = 0; i < 0x100; i += 4) {
      mem.write32(at + i, 0);
    }
    thread.state.r[26] = at;
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
    for (final MapEntry(key: (interrupt, sub), value: handler)
        in _subIntrs.entries.toList()) {
      if (interrupt == _vblankInterrupt && handler.enabled) {
        _runHandler(cpu, handler.func, sub, handler.arg);
      }
    }
    for (final thread in threads.values) {
      if (thread.status == PspThreadStatus.waitVblank &&
          --thread.waitCount <= 0) {
        thread.status = PspThreadStatus.ready;
        thread.pendingResult = thread.waitBits;
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
    _retryAsyncReads(cpu);
    _preempt(cpu);
  }

  /// Switches to a ready thread of strictly higher priority, if any. A
  /// current thread that does not run gives way even while interrupts
  /// are disabled, since it blocked in a call. Inside a handler nothing
  /// switches: the handler runs on the interrupted thread's processor
  /// state, and the switch waits for the next scheduling point after it.
  void _preempt(Allegrex cpu) {
    if (_inCallback) return;
    final cur = current;
    if (cur == null || cur.status != PspThreadStatus.running) {
      _schedule(cpu);
      return;
    }
    if (!_interruptsEnabled) return;
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
    if (code == _guestReturnCode) {
      _putReturned(cpu);
      return;
    }
    final import = _byCode[code];
    final handler = import == null ? null : _handlers[import.nid];
    if (import == null) {
      // A syscall outside an import stub falls through with a zero.
      cpu.r[2] = 0;
      return;
    }
    final caller = current;
    if (!_inCallback) {
      caller?.lastCall = import;
      caller?.cbWait = false;
    }
    _liveCpu = cpu;
    final returnAt = cpu.r[31];
    int? result = 0;
    if (handler == null) {
      unknownCalls[import.nid] = (unknownCalls[import.nid] ?? 0) + 1;
    } else {
      result = handler(cpu, import);
    }
    if (_redirected) {
      _redirected = false;
      return;
    }
    if (_inCallback) {
      // A call from a handler returns to the handler on the live
      // processor; the interrupted thread's saved state, which may
      // belong to a thread that is blocked, stays untouched.
      cpu.pc = returnAt;
      cpu.nextPc = returnAt + 4;
      if (result != null) cpu.r[2] = result;
      return;
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

    // Kernel_Library
    on(0x092968f4, (cpu, _) {
      final flags = _interruptsEnabled ? 1 : 0;
      _interruptsEnabled = false;
      return flags;
    });
    int? resumeInterrupts(Allegrex cpu, PspImport? _) {
      _interruptsEnabled = _arg(cpu, 0) & 1 != 0;
      if (!_inCallback) {
        while (_interruptsEnabled && _pendingHandlers.isNotEmpty) {
          final (func, id, arg) = _pendingHandlers.removeFirst();
          _runHandler(cpu, func, id, arg);
        }
        _preempt(cpu);
      }
      return null;
    }

    on(0x5f10d406, resumeInterrupts);
    on(0x3b84732d, resumeInterrupts); // the form with a memory barrier

    // sceUtility: the save data, message and keyboard dialogs. Their
    // update calls have nothing to draw. The module loading stays an
    // unknown call, which returns zero.
    on(0x50c4cd57, (cpu, _) => _savedata.initStart(_arg(cpu, 0)));
    on(0x8874dbe0, (cpu, _) => _savedata.getStatus());
    on(0xd4b95ffb, (cpu, _) => 0);
    on(0x9790b33c, (cpu, _) => _savedata.shutdownStart());
    on(0x2ad8e239, (cpu, _) => _msgDialog.initStart(_arg(cpu, 0)));
    on(0x9a1c91d7, (cpu, _) => _msgDialog.getStatus());
    on(0x67af3428, (cpu, _) => _msgDialog.shutdownStart());
    on(0x95fc253b, (cpu, _) => 0); // update
    on(0xf6269b82, (cpu, _) => _keyboard.initStart(_arg(cpu, 0)));
    on(0xf3f76017, (cpu, _) => _keyboard.getStatus());
    on(0x3dfaeba9, (cpu, _) => _keyboard.shutdownStart());
    on(0x4b85c861, (cpu, _) => 0); // update

    // The system settings are those of a Japanese console: Japanese, the
    // circle button confirms, the date as year, month, day, a 24-hour
    // clock and Japan's time zone without daylight saving.
    on(0xa5da2406, (cpu, _) { // GetSystemParamInt(id, value)
      final value = _systemParams[_arg(cpu, 0)];
      if (value == null) return _systemParamFail;
      mem.write32(_arg(cpu, 1), value);
      return 0;
    });
    on(0x34b78343, (cpu, _) { // GetSystemParamString(id, text, size)
      if (_arg(cpu, 0) != 1) return _systemParamFail; // the nickname
      final at = _arg(cpu, 1), size = _arg(cpu, 2);
      const name = PspKeyboardDialog.defaultText;
      for (var i = 0; i < size; i++) {
        mem.write8(at + i, i < name.length ? name.codeUnitAt(i) : 0);
      }
      return 0;
    });
    // sceImpose GetLanguageMode(language, button): the same two settings
    on(0x36aa6e91, (cpu, _) {
      mem.write32(_arg(cpu, 0), _systemParams[_paramLanguage]!);
      mem.write32(_arg(cpu, 1), _systemParams[_paramButton]!);
      return 0;
    });

    // scePower: the clocks a game sets are reported back; the battery is
    // full and the power is on. Locks and callbacks do nothing.
    on(0xfdb5bfe9, (cpu, _) => _cpuMhz); // GetCpuClockFrequencyInt
    on(0xfee03a2f, (cpu, _) => _cpuMhz); // GetCpuClockFrequency
    on(0xbd681969, (cpu, _) => _busMhz); // GetBusClockFrequencyInt
    on(0x478fe6f5, (cpu, _) => _busMhz); // GetBusClockFrequency
    on(0xb1a52c83, (cpu, _) { // GetCpuClockFrequencyFloat
      cpu.f[0] = _cpuMhz.toDouble();
      return 0;
    });
    on(0x9badb3eb, (cpu, _) { // GetBusClockFrequencyFloat
      cpu.f[0] = _busMhz.toDouble();
      return 0;
    });
    int? setClocks(Allegrex cpu, PspImport? _) {
      _cpuMhz = _arg(cpu, 1);
      _busMhz = _arg(cpu, 2);
      return 0;
    }

    on(0x737486f2, setClocks); // SetClockFrequency
    on(0xebd177d6, setClocks); // SetClockFrequency, later firmware
    on(0x469989ad, setClocks); // the same, later firmware
    on(0x843fbf43, (cpu, _) { // SetCpuClockFrequency
      _cpuMhz = _arg(cpu, 0);
      return 0;
    });
    on(0xb8d7b3fb, (cpu, _) { // SetBusClockFrequency
      _busMhz = _arg(cpu, 0);
      return 0;
    });
    on(0x2085d15d, (cpu, _) => 100); // GetBatteryLifePercent
    on(0x8efb3fa2, (cpu, _) => 300); // GetBatteryLifeTime, in minutes
    on(0x87440f5e, (cpu, _) => 1); // IsPowerOnline
    on(0x0afd0d8b, (cpu, _) => 1); // IsBatteryExist
    on(0x1e490401, (cpu, _) => 0); // IsBatteryCharging
    on(0x04b7766e, (cpu, _) => 0); // RegisterCallback
    on(0xdfa8baf8, (cpu, _) => 0); // UnregisterCallback
    on(0xd6d016ef, (cpu, _) => 0); // Lock
    on(0xca3d34c1, (cpu, _) => 0); // Unlock
    on(0xefd3c963, (cpu, _) => 0); // Tick

    // sceSuspendForUser: power locks do nothing. The volatile memory is
    // taken to be the 4 MiB below the user module area, handed to the game
    // whole; the address is as recalled from public descriptions of the
    // memory map, not checked against hardware.
    on(0xeadb1bd7, (cpu, _) => 0);
    on(0x3aee7261, (cpu, _) => 0);
    int? lockVolatile(Allegrex cpu, PspImport? _) {
      if (_arg(cpu, 1) != 0) mem.write32(_arg(cpu, 1), _volatileAt);
      if (_arg(cpu, 2) != 0) mem.write32(_arg(cpu, 2), _volatileSize);
      return 0;
    }

    on(0x3e0271d3, lockVolatile);
    on(0xa14f40b2, lockVolatile); // the try form
    on(0xa569e425, (cpu, _) => 0);

    // InterruptManager: sub-interrupt handlers. Only the vblank
    // interrupt calls them. The errors of a handler already registered
    // and of a missing one are as recalled from the public SDK error
    // list, not checked against games.
    on(0xca04a2b9, (cpu, _) {
      final key = (_arg(cpu, 0), _arg(cpu, 1));
      if (_subIntrs.containsKey(key)) return 0x80020065;
      _subIntrs[key] = _SubIntr(_arg(cpu, 2), _arg(cpu, 3));
      return 0;
    });
    on(0xd61e6961, (cpu, _) =>
        _subIntrs.remove((_arg(cpu, 0), _arg(cpu, 1))) == null
            ? 0x80020068
            : 0);
    on(0xfb8e22ec, (cpu, _) {
      final handler = _subIntrs[(_arg(cpu, 0), _arg(cpu, 1))];
      if (handler == null) return 0x80020068;
      handler.enabled = true;
      return 0;
    });
    on(0x8a389411, (cpu, _) {
      final handler = _subIntrs[(_arg(cpu, 0), _arg(cpu, 1))];
      if (handler == null) return 0x80020068;
      handler.enabled = false;
      return 0;
    });

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
    on(0x2c34e053, _releaseWaitThread);
    on(0xceadeb47, _delayThread);
    // The CB forms of the waits run the thread's notified callbacks
    // first and then wait as the plain forms do.
    int? Function(Allegrex, PspImport?) withCallbacks(
            int? Function(Allegrex, PspImport?) wait) =>
        (cpu, import) {
          _runCallbacks(cpu);
          final self = current;
          final result = wait(cpu, import);
          if (self != null && self.status != PspThreadStatus.running) {
            self.cbWait = true;
          }
          return result;
        };
    on(0x68da9e36, withCallbacks(_delayThread));
    on(0x840e8133, withCallbacks(_waitThreadEnd));
    on(0xea748e31, (cpu, _) => current?.id ?? 0);
    // GetSystemTime fills a 64-bit microsecond count at a0;
    // GetSystemTimeWide returns it in v0:v1 and GetSystemTimeLow
    // returns its low word.
    on(0xdb738f35, (cpu, _) {
      final micros = cpu.clocks ~/ _clocksPerMicrosecond;
      mem.write32(_arg(cpu, 0), micros & 0xffffffff);
      mem.write32(_arg(cpu, 0) + 4, micros >>> 32);
      return 0;
    });
    on(0x82bc5777, (cpu, _) {
      final micros = cpu.clocks ~/ _clocksPerMicrosecond;
      cpu.r[2] = micros & 0xffffffff;
      cpu.r[3] = micros >>> 32;
      return null;
    });
    on(0x369ed59d,
        (cpu, _) => (cpu.clocks ~/ _clocksPerMicrosecond) & 0xffffffff);
    int? sleepThread(Allegrex cpu, PspImport? _) {
      // SleepThread: wakes only through WakeupThread; a wake-up that came
      // first is consumed at once.
      if (_inCallback) return 0;
      if (current!.wakeupCount > 0) {
        current!.wakeupCount--;
        return 0;
      }
      current!.status = PspThreadStatus.waitSleep;
      _schedule(cpu);
      return null;
    }

    on(0x9ace131e, sleepThread);
    on(0x82826f70, withCallbacks(sleepThread));
    on(0x1d17decf, (cpu, _) {
      final thread = threads[_arg(cpu, 0)];
      if (thread != null && thread.status == PspThreadStatus.waitSleep) {
        thread.status = PspThreadStatus.ready;
        thread.pendingResult = 0;
      }
      return 0;
    });
    on(0xd59ead2f, (cpu, _) {
      // WakeupThread
      final thread = threads[_arg(cpu, 0)];
      if (thread == null) return 0x80020198;
      if (thread.status == PspThreadStatus.waitSleep) {
        thread.status = PspThreadStatus.ready;
        thread.pendingResult = 0;
        _preempt(cpu);
      } else {
        thread.wakeupCount++;
      }
      return 0;
    });
    // Event flags
    on(0x55c20a00, (cpu, _) {
      final id = _nextId++;
      _eventFlags[id] = _EventFlag(_arg(cpu, 2), _arg(cpu, 1));
      return id;
    });
    on(0xef9e4c70, (cpu, _) =>
        _eventFlags.remove(_arg(cpu, 0)) == null ? _unknownEventFlag : 0);
    on(0x1fb15a32, _setEventFlag);
    on(0x812346e4, (cpu, _) {
      final flag = _eventFlags[_arg(cpu, 0)];
      if (flag == null) return _unknownEventFlag;
      flag.pattern &= _arg(cpu, 1);
      return 0;
    });
    on(0x402fcf22, (cpu, _) => _waitEventFlag(cpu, poll: false));
    on(0x328c546a,
        withCallbacks((cpu, _) => _waitEventFlag(cpu, poll: false)));
    on(0x30fd48f0, (cpu, _) => _waitEventFlag(cpu, poll: true));
    on(0xa66b0120, (cpu, _) {
      // ReferEventFlagStatus(id, info): the size, the name, the
      // attributes, the initial and current patterns and the number of
      // waiting threads. The kernel keeps neither the name nor the
      // initial pattern; the name is left empty and the initial pattern
      // reads as the current one.
      final flag = _eventFlags[_arg(cpu, 0)];
      if (flag == null) return _unknownEventFlag;
      final at = _arg(cpu, 1);
      final waiting = threads.values
          .where((t) =>
              t.status == PspThreadStatus.waitEvent &&
              t.waitEvent == _arg(cpu, 0))
          .length;
      mem.write8(at + 4, 0);
      mem.write32(at + 36, flag.attr);
      mem.write32(at + 40, flag.pattern);
      mem.write32(at + 44, flag.pattern);
      mem.write32(at + 48, waiting);
      return 0;
    });
    on(0xe81caf8f, (cpu, _) {
      // CreateCallback(name, func, common): owned by the calling thread
      final id = _nextId++;
      _callbacks[id] =
          _Callback(current?.id ?? 0, _arg(cpu, 1), _arg(cpu, 2));
      return id;
    });
    on(0xedba5844, (cpu, _) => _callbacks.remove(_arg(cpu, 0)) == null
        ? 0x800201a1
        : 0); // DeleteCallback
    on(0xc11ba8c4, (cpu, _) {
      // NotifyCallback
      if (!_callbacks.containsKey(_arg(cpu, 0))) return 0x800201a1;
      _notifyCallback(_arg(cpu, 0), _arg(cpu, 1));
      return 0;
    });
    on(0x349d6d6c, (cpu, _) => _runCallbacks(cpu) ? 1 : 0); // CheckCallback
    on(0xd6da4ba1, _createSema);
    on(0x4e3a1105, _waitSema);
    on(0x6d212bac, withCallbacks(_waitSema));
    on(0x3f53e640, _signalSema);
    on(0x58b1f937, _pollSema);
    on(0x28b6489c, (cpu, _) {
      _semas.remove(_arg(cpu, 0));
      return 0;
    });
    on(0x94aa61ee, (cpu, _) => current?.priority ?? 0);
    on(0x71bc9871, (cpu, _) {
      final thread = _arg(cpu, 0) == 0 ? current : threads[_arg(cpu, 0)];
      if (thread == null) return 0x80020198;
      thread.priority = _arg(cpu, 1);
      _preempt(cpu);
      return 0;
    });
    // Message boxes. A receive on an empty box waits for a send, which
    // hands the message to the first waiting thread. The errors are as
    // recalled from the public SDK error list, not checked against games.
    on(0x8125221d, (cpu, _) {
      final id = _nextId++;
      _mbxs[id] = _Mbx();
      return id;
    });
    on(0x86255ada, (cpu, _) => _mbxs.remove(_arg(cpu, 0)) == null
        ? 0x800201c8
        : 0);
    on(0xe9b3061e, (cpu, _) {
      final id = _arg(cpu, 0);
      final mbx = _mbxs[id];
      if (mbx == null) return 0x800201c8;
      for (final thread in threads.values) {
        if (thread.status == PspThreadStatus.waitMbx && thread.waitSema == id) {
          mem.write32(thread.waitOutAt, _arg(cpu, 1));
          thread.status = PspThreadStatus.ready;
          thread.pendingResult = 0;
          _preempt(cpu);
          return 0;
        }
      }
      mbx.messages.add(_arg(cpu, 1));
      return 0;
    });
    int? receiveMbx(Allegrex cpu, PspImport? _, {required bool poll}) {
      final id = _arg(cpu, 0);
      final mbx = _mbxs[id];
      if (mbx == null) return 0x800201c8;
      if (mbx.messages.isNotEmpty) {
        mem.write32(_arg(cpu, 1), mbx.messages.removeAt(0));
        return 0;
      }
      if (poll || _inCallback) return 0x800201ca;
      final timeout = _arg(cpu, 2);
      if (timeout != 0 && mem.read32(timeout) == 0) return 0x800201b9;
      current!
        ..status = PspThreadStatus.waitMbx
        ..waitSema = id
        ..waitOutAt = _arg(cpu, 1);
      _schedule(cpu);
      return null;
    }

    on(0x18260574, (cpu, import) => receiveMbx(cpu, import, poll: false));
    on(0xf3986382, withCallbacks(
        (cpu, import) => receiveMbx(cpu, import, poll: false)));
    on(0x0d81716a, (cpu, import) => receiveMbx(cpu, import, poll: true));
    on(0xb7d098c6, (cpu, _) {
      final id = _nextId++;
      final mutex = _mutexes[id] = _Mutex();
      if (_arg(cpu, 2) > 0) {
        mutex.owner = current?.id ?? 0;
        mutex.count = _arg(cpu, 2);
      }
      return id;
    });
    on(0xf8170fbe, (cpu, _) =>
        _mutexes.remove(_arg(cpu, 0)) == null ? 0x800201c3 : 0);
    on(0xb011b11f, (cpu, _) => _lockMutex(cpu, blocking: true));
    on(0x5bf4dd27, (cpu, _) => _lockMutex(cpu, blocking: true));
    on(0x0ddcd2c9, (cpu, _) => _lockMutex(cpu, blocking: false));
    on(0x6b30100f, _unlockMutex);
    // Lightweight mutexes live in a guest workarea, not behind an id.
    on(0x19cff145, _createLwMutex);
    on(0x60107536, _deleteLwMutex);
    on(0xbea46419, (cpu, _) => _lockLwMutex(cpu, blocking: true));
    on(0x1fc64e09,
        withCallbacks((cpu, _) => _lockLwMutex(cpu, blocking: true)));
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

    // ThreadManForUser: fixed-size pools. An allocation does not wait
    // for a free block: a full pool returns the no-memory error.
    on(0xc07bb470, _createFpl);
    on(0xed1410e0, (cpu, _) =>
        _fpls.remove(_arg(cpu, 0)) == null ? _unknownFpl : 0);
    on(0xd979e9bf, _allocateFpl);
    on(0xe7282cb6, _allocateFpl); // the CB form shares the allocation
    on(0x623ae665, _allocateFpl);
    on(0xf6414a71, _freeFpl);
    on(0xb6d61d02, (cpu, _) {
      _blocks.remove(_arg(cpu, 0));
      return 0;
    });
    on(0xb73cd27a, (cpu, _) {
      _blocks.remove(_arg(cpu, 0));
      return 0;
    });
    // The free user memory: the largest free span (MaxFreeMemSize) and
    // the sum of them (TotalFreeMemSize).
    on(0xf919f628, (cpu, _) => _arenaFree().$2);
    on(0xa291f107, (cpu, _) => _arenaFree().$1);
    on(0x7591c7db, (cpu, _) {
      _compiledSdkVersion = _arg(cpu, 0);
      return 0;
    });
    on(0xfc114573, (cpu, _) => _compiledSdkVersion);
    on(0xf77d77cb, (cpu, _) {
      _compilerVersion = _arg(cpu, 0);
      return 0;
    });
    on(0x13a5abef, (cpu, _) {
      log.write(formatKernelPrintf(cpu));
      return null;
    });

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
    on(0xf0a26395, (cpu, _) => _mainModuleId);
    on(0xd8b73127, (cpu, _) {
      final address = PspMemory.physical(_arg(cpu, 0));
      final found = _mainModule.segments.any(
          (segment) => address >= segment.start && address < segment.end);
      return found ? _mainModuleId : 0x8002012e;
    });
    on(0x977de386, _loadModuleByPath);
    on(0xb7f46618, _loadModuleById);
    on(0x50f0c1ec, _startLoadedModule);
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
      // GetFrameBuf: the address, the width and the format each go to
      // their own pointer.
      final addrAt = _arg(cpu, 0), widthAt = _arg(cpu, 1);
      final formatAt = _arg(cpu, 2);
      if (addrAt != 0) mem.write32(addrAt, fbAddr | 0x40000000);
      if (widthAt != 0) mem.write32(widthAt, fbWidth);
      if (formatAt != 0) mem.write32(formatAt, fbFormat);
      return 0;
    });
    on(0x984c27e7, _waitVblank);
    on(0x46f186c3, _waitVblank);
    // WaitVblank and its callback form return at once inside the vblank
    // period; the vblank here is an instant, so they wait for the next.
    on(0x36cdfade, _waitVblank);
    on(0x8eb9ec49, withCallbacks(_waitVblank));
    // WaitVblankStartMulti and its callback form: the count in a0.
    on(0x40f1469c, (cpu, _) => _waitVblank(cpu, null, _arg(cpu, 0)));
    on(0x77ed8b3a, withCallbacks((cpu, _) =>
        _waitVblank(cpu, null, _arg(cpu, 0))));
    on(0x9c6eaad7, (cpu, _) => vcount);
    on(0xdba6c4c4, (cpu, _) {
      cpu.f[0] = displayHz.toDouble();
      return null;
    });
    on(0xb4f378fa, (cpu, _) => 0);
    // The horizontal counters follow the emulated clock: 286 lines a frame.
    on(0x773dd3a3, (cpu, _) => _hcount(cpu) % _linesPerFrame);
    on(0x210eab3a, (cpu, _) => _hcount(cpu));

    // sceCtrl
    on(0x1f4011e6, (cpu, _) => 0);
    on(0x6a2774f3, (cpu, _) => 0);
    on(0x1f3112b3, (cpu, _) => 0);
    on(0xda6b76a1, (cpu, _) => 0);
    // The read forms wait for the sample of the next vblank; the peek
    // forms return at once. The negative forms set the bits of the
    // buttons that are up.
    on(0x1f803938, (cpu, _) => _readCtrlWait(cpu, false)); // Read
    on(0x60b81f86, (cpu, _) => _readCtrlWait(cpu, true)); // ReadNegative
    on(0x3a622550, _readCtrl); // PeekBufferPositive
    on(0xc152080a, (cpu, _) => _readCtrl(cpu, null, true)); // PeekNegative
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
    // sceDmacMemcpy: the copy completes at once.
    on(0x617f3fe6, (cpu, _) {
      final dst = _arg(cpu, 0), src = _arg(cpu, 1), size = _arg(cpu, 2);
      if (size > 0) mem.writeBytes(dst, mem.readBytes(src, size));
      return 0;
    });
    // sceKernelLibcClock: the processor time in microseconds.
    on(0x91e4f6a7,
        (cpu, _) => (cpu.clocks ~/ _clocksPerMicrosecond) & 0x7fffffff);
    on(0x71ec4271, (cpu, _) {
      // sceKernelLibcGettimeofday: seconds and microseconds of the clock.
      final tv = _arg(cpu, 0);
      if (tv != 0) {
        final micros = cpu.clocks ~/ _clocksPerMicrosecond;
        mem.write32(tv, _nowSeconds);
        mem.write32(tv + 4, micros % 1000000);
      }
      return 0;
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
    on(0xff5940b6, _ioCloseAsync);
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
      // sceIoIoctl(fd, command, in, inLength, out, outLength). Command
      // 0x01020006 reads the first sector of a disc file, which games use
      // to name the file by its sector.
      final fd = _arg(cpu, 0);
      final node = _files[fd]?.node;
      if (node != null && _arg(cpu, 1) == 0x01020006) {
        final out = cpu.r[8], outLength = cpu.r[9];
        if (out == 0 || outLength < 4) return 0x80010016;
        mem.write32(out, node.entry.lba);
        return 0;
      }
      return _files.containsKey(fd) || _dirs.containsKey(fd)
          ? 0
          : 0x80010002;
    });
    on(0x3251ea56, _ioPollAsync);
    on(0xe23eec33, _ioWaitAsync);
    on(0x35dbd746, withCallbacks(_ioWaitAsync));
    on(0xcb05f8d6, _ioPollAsync);
    on(0xe8bc6571, (cpu, _) => 0);
    on(0xb293727f, (cpu, _) => 0);
    on(0xa12a0514, (cpu, _) {
      if (!_files.containsKey(_arg(cpu, 0))) return 0x80010002;
      _asyncCallbacks[_arg(cpu, 0)] = (_arg(cpu, 1), _arg(cpu, 2));
      // The calls finish at once here, so a call made before the callback
      // was set has already finished: the callback hears of it now.
      if (_async.containsKey(_arg(cpu, 0))) _notifyAsync(_arg(cpu, 0));
      return 0;
    });

    // sceUmdUser: a mounted disc is present and ready, and no disc
    // reports itself as not present; activation is a formality.
    on(0xc6183d47, (cpu, _) => 0);
    on(0xe83742ba, (cpu, _) => 0);
    on(0x8ef08fce, (cpu, _) => 0);
    on(0x4a9e5e29, withCallbacks((cpu, _) => 0)); // WaitDriveStatCB
    on(0x6b4a146c, (cpu, _) => disc?.isMounted == true ? 0x22 : 0x01);
    on(0x46ebb729, (cpu, _) => disc?.isMounted == true ? 1 : 0); // CheckMedium
    on(0xaee7404d, (cpu, _) {
      // RegisterUMDCallBack: the callback learns the drive state at once
      // (present, initialized and ready while a disc is mounted).
      _notifyCallback(
          _arg(cpu, 0), disc?.isMounted == true ? 0x32 : 0x01);
      return 0;
    });
    on(0xbd2bde07, (cpu, _) => 0);
    on(0x54f5fb11, (cpu, _) {
      // sceIoDevctl: the "emulator:" device is how test harnesses
      // detect an emulator and deliver their output (command 2); the
      // probe for it (command 3) and the display query (command 1)
      // succeed. Arguments past the fourth travel in t0/t1 in the
      // Allegrex calling convention, so the output pointer for
      // command 1 is in t0.
      final device = mem.readString(_arg(cpu, 0), 32);
      // The commands of the disc devices, such as a seek, succeed while a
      // disc is in; the reads they prepare go through the files.
      if (device == 'disc0:' || device == 'umd0:' || device == 'umd1:' ||
          device == 'umd:') {
        return disc?.isMounted == true ? 0 : 0x80010002;
      }
      if (device == 'ms0:' || device == 'fatms0:' || device == 'mscmhc0:') {
        return _memoryStickDevctl(cpu, _arg(cpu, 1));
      }
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
    // GetChannelRestLen and GetChannelRestLength: the samples of the
    // channel that have not played yet
    for (final nid in [0xb011b7ff, 0xb011922f]) {
      on(nid, (cpu, _) {
        final index = _arg(cpu, 0);
        if (index < 0 || index >= 8 || !_audioChannels[index].reserved) {
          return 0x80260002;
        }
        final rest = _audioChannels[index].nextAt - _audioAt(cpu);
        return rest > 0 ? rest : 0;
      });
    }
    on(0x827a2fb7, (cpu, _) => 0);

    // sceAudioOutput2: one more stereo output with its own block size.
    on(0x01562ba3, (cpu, _) {
      final sampleCount = _arg(cpu, 0);
      if (_output2.reserved) return 0x80260002;
      if (sampleCount <= 0 || sampleCount > 65472) return 0x8026000a;
      _output2
        ..reserved = true
        ..sampleCount = sampleCount
        ..format = 0
        ..nextAt = 0;
      return 0;
    });
    on(0x43196845, (cpu, _) {
      if (!_output2.reserved) return 0x80260002;
      _output2
        ..reserved = false
        ..nextAt = 0;
      return 0;
    });
    on(0x63f2889c, (cpu, _) {
      final sampleCount = _arg(cpu, 0);
      if (!_output2.reserved) return 0x80260002;
      if (sampleCount <= 0 || sampleCount > 65472) return 0x8026000a;
      _output2.sampleCount = sampleCount;
      return 0;
    });
    on(0x647cef33, (cpu, _) {
      if (!_output2.reserved) return 0x80260002;
      final rest = _output2.nextAt - _audioAt(cpu);
      return rest > 0 ? rest : 0;
    });
    on(0x2d53f36e, (cpu, _) {
      if (!_output2.reserved) return 0x80260002;
      return _queueBlock(cpu, _output2, _arg(cpu, 1), _arg(cpu, 0), null,
          blocking: true);
    });

    // sceMpeg: the movie player without decoders (see [PspMpeg]). The
    // work area sizes only need room for the guest's own bookkeeping.
    on(0x682a619b, (cpu, _) => 0); // Init
    on(0x874624d6, (cpu, _) => 0); // Finish
    on(0xc132e22f, (cpu, _) => 0x10000); // QueryMemSize
    on(0xd7a29f46, (cpu, _) => _arg(cpu, 0) * 0x868); // RingbufferQueryMemSize
    on(0x37295ed8, (cpu, _) {
      // RingbufferConstruct(rb, packets, data, size, callback, arg)
      _mpeg.construct(_arg(cpu, 0), _arg(cpu, 1), _arg(cpu, 2),
          _arg(cpu, 4), _arg(cpu, 5));
      return 0;
    });
    on(0x13407f13, (cpu, _) => 0); // RingbufferDestruct
    on(0xd8c5f121, (cpu, _) {
      // Create(mpeg, data, size, rb, frameWidth, ...): the handle points
      // at the work area
      mem.write32(_arg(cpu, 0), _arg(cpu, 1));
      mem.write32(_arg(cpu, 3) + 40, _arg(cpu, 0));
      _mpeg
        ..closeVideo()
        ..ringbuffer = _arg(cpu, 3)
        ..videoOn = false
        ..audioOn = false
        ..flush();
      return 0;
    });
    on(0x606a4649, (cpu, _) {
      _mpeg.closeVideo(); // Delete
      return 0;
    });
    on(0xa780cf7e, (cpu, _) => 1); // MallocAvcEsBuf
    on(0xceb870b1, (cpu, _) => 0); // FreeAvcEsBuf
    on(0xf8dcb679, (cpu, _) {
      // QueryAtracEsSize(mpeg, esSize, outSize)
      mem.write32(_arg(cpu, 1), 2112);
      mem.write32(_arg(cpu, 2), 8192);
      return 0;
    });
    on(0x167afd9e, (cpu, _) {
      // InitAu(mpeg, esBuffer, au)
      _mpeg.initUnit(_arg(cpu, 2), _arg(cpu, 1));
      return 0;
    });
    on(0x21ff80e4, (cpu, _) {
      // QueryStreamOffset(mpeg, header, offset): the big-endian word at
      // byte 8 of a PSMF header
      final at = _arg(cpu, 1);
      if (mem.read32(at) != 0x464d5350) {
        mem.write32(_arg(cpu, 2), 0);
        return 0x806101fe;
      }
      final word = mem.read32(at + 8);
      mem.write32(
          _arg(cpu, 2),
          (word & 0xff) << 24 |
              (word >> 8 & 0xff) << 16 |
              (word >> 16 & 0xff) << 8 |
              word >>> 24);
      return 0;
    });
    on(0x611e9e11, (cpu, _) {
      // QueryStreamSize(header, size): the big-endian word at byte 12 of
      // a PSMF header, the size of the program stream
      final word = mem.read32(_arg(cpu, 0) + 12);
      mem.write32(
          _arg(cpu, 1),
          (word & 0xff) << 24 |
              (word >> 8 & 0xff) << 16 |
              (word >> 16 & 0xff) << 8 |
              word >>> 24);
      return 0;
    });
    on(0x740fccd1, (cpu, _) {
      // AvcDecodeStop(mpeg, frameWidth, buffer, status): no picture is
      // held back, so none comes out
      if (_arg(cpu, 3) != 0) mem.write32(_arg(cpu, 3), 0);
      return 0;
    });
    on(0x42560f23, (cpu, _) {
      // RegistStream(mpeg, type, channel): the handle names the type
      final type = _arg(cpu, 1);
      if (type == PspMpeg.streamVideo) _mpeg.videoOn = true;
      if (type == PspMpeg.streamAudio) _mpeg.audioOn = true;
      return 0x34340000 | type;
    });
    on(0x591a4aa2, (cpu, _) {
      // UnRegistStream(mpeg, stream)
      final type = _arg(cpu, 1) & 0xff;
      if (type == PspMpeg.streamVideo) _mpeg.videoOn = false;
      if (type == PspMpeg.streamAudio) _mpeg.audioOn = false;
      return 0;
    });
    on(0x707b7629, (cpu, _) {
      _mpeg.flush(); // FlushAllStream
      return 0;
    });
    on(0xb5f6dc87, (cpu, _) => _mpeg.free); // RingbufferAvailableSize
    on(0xb240a59e, (cpu, _) {
      // RingbufferPut(rb, packets, available): the read callback fills
      // the buffer on the calling thread
      if (_inCallback || current == null) return 0;
      final put = _Put(_arg(cpu, 1), 0, cpu.r[31]);
      if (!_callPut(cpu, put)) return 0;
      _puts[current!.id] = put;
      _redirected = true;
      return null;
    });
    on(0xfe246728, (cpu, _) => _mpeg.videoUnit(_arg(cpu, 2))); // GetAvcAu
    on(0xe1ce83a7, (cpu, _) => _mpeg.audioUnit(_arg(cpu, 2))); // GetAtracAu
    on(0x8c1e027d, (cpu, _) => PspMpeg.errorNoData); // GetPcmAu
    on(0xa11c7026, (cpu, _) {
      // AvcDecodeMode(mpeg, mode): the second word is the pixel format
      final at = _arg(cpu, 1);
      if (at != 0) _mpeg.pixelMode = mem.read32(at + 4);
      return 0;
    });
    on(0x0e3c2e9d, (cpu, _) {
      // AvcDecode(mpeg, au, frameWidth, buffer, init): the picture of the
      // unit that GetAvcAu took
      final bufferAt = mem.read32(_arg(cpu, 3));
      _mpeg.decodePicture(bufferAt, _arg(cpu, 2));
      if (cpu.r[8] != 0) mem.write32(cpu.r[8], 1);
      return 0;
    });
    on(0x4571cc64, (cpu, _) => 0); // AvcDecodeFlush
    on(0x0f6c18d7, (cpu, _) {
      // AvcDecodeDetail(mpeg, detail): the size of the picture at 8 and
      // 12. The layout is not documented; these two words are what a game
      // reads to draw the picture, and the other fields stay untouched.
      final at = _arg(cpu, 1);
      if (at != 0) {
        mem.write32(at + 8, _mpeg.pictureWidth);
        mem.write32(at + 12, _mpeg.pictureHeight);
      }
      return 0;
    });
    on(0x800c44df, (cpu, _) {
      _mpeg.decodeAudio(_arg(cpu, 2)); // AtracDecode(mpeg, au, buffer, init)
      return 0;
    });

    // sceAtrac3plus: the ATRAC player, for files held whole in memory
    // or streamed through a buffer
    on(0x780f88d1, (cpu, _) => _atrac.allocate(_arg(cpu, 0))); // GetAtracID
    on(0x7a20e7af, // SetDataAndGetID(buffer, size)
        (cpu, _) => _atrac.setDataAndGetId(_arg(cpu, 0), _arg(cpu, 1)));
    on(0x0e2a73ab, // SetData(id, buffer, size)
        (cpu, _) => _atrac.setData(_arg(cpu, 0), _arg(cpu, 1), _arg(cpu, 2)));
    on(0x61eb33f5, (cpu, _) => _atrac.release(_arg(cpu, 0)));
    on(0x6a8c3cd5, // DecodeData(id, out, count, end, remainFrame)
        (cpu, _) => _atrac.decode(_arg(cpu, 0), _arg(cpu, 1), _arg(cpu, 2),
            _arg(cpu, 3), _arg(cpu, 4)));
    on(0xa2bba8be, // GetSoundSample(id, end, loopStart, loopEnd)
        (cpu, _) => _atrac.soundSample(
            _arg(cpu, 0), _arg(cpu, 1), _arg(cpu, 2), _arg(cpu, 3)));
    on(0x868120b5,
        (cpu, _) => _atrac.setLoopNum(_arg(cpu, 0), _arg(cpu, 1).toSigned(32)));
    on(0x644e5607, // ResetPlayPosition(id, sample, first, second)
        (cpu, _) => _atrac.resetPlayPosition(
            _arg(cpu, 0), _arg(cpu, 1), _arg(cpu, 2)));
    on(0x9ae849a7,
        (cpu, _) => _atrac.remainFrame(_arg(cpu, 0), _arg(cpu, 1)));
    on(0x36faabfb,
        (cpu, _) => _atrac.nextSample(_arg(cpu, 0), _arg(cpu, 1)));
    on(0xd6a5f2f7, (cpu, _) => _atrac.maxSample(_arg(cpu, 0), _arg(cpu, 1)));
    on(0xe23e3a35,
        (cpu, _) => _atrac.nextDecodePosition(_arg(cpu, 0), _arg(cpu, 1)));
    on(0x31668baa, (cpu, _) => _atrac.channel(_arg(cpu, 0), _arg(cpu, 1)));
    on(0xa554a158, (cpu, _) => _atrac.bitrate(_arg(cpu, 0), _arg(cpu, 1)));
    on(0xfaa4f89b, // GetLoopStatus(id, count, status)
        (cpu, _) =>
            _atrac.loopStatus(_arg(cpu, 0), _arg(cpu, 1), _arg(cpu, 2)));
    on(0x5d268707, // GetStreamDataInfo(id, write, available, offset)
        (cpu, _) => _atrac.streamDataInfo(
            _arg(cpu, 0), _arg(cpu, 1), _arg(cpu, 2), _arg(cpu, 3)));
    on(0x7db31251, // AddStreamData(id, bytes)
        (cpu, _) => _atrac.addStreamData(_arg(cpu, 0), _arg(cpu, 1)));
    on(0x0fae370e, // SetHalfwayBufferAndGetID(buffer, read, size)
        (cpu, _) => _atrac.setHalfwayBufferAndGetId(
            _arg(cpu, 0), _arg(cpu, 1), _arg(cpu, 2)));
    on(0x3f6e26b5, // SetHalfwayBuffer(id, buffer, read, size)
        (cpu, _) => _atrac.setHalfwayBuffer(
            _arg(cpu, 0), _arg(cpu, 1), _arg(cpu, 2), _arg(cpu, 3)));
    on(0xe88f759b, // GetInternalErrorInfo(id, error)
        (cpu, _) => _atrac.internalError(_arg(cpu, 0), _arg(cpu, 1)));
    // GetBufferInfoForResetting(id, sample, info), under the identifiers
    // of both spellings of its name
    for (final nid in [0xca3ca3d2, 0x2dd3e298]) {
      on(nid,
          (cpu, _) => _atrac.bufferInfoForResetting(_arg(cpu, 0), _arg(cpu, 2)));
    }
    on(0x83e85ea0, // GetSecondBufferInfo
        (cpu, _) => PspAtrac.errorSecondBufferNotNeeded);

    // sceSasCore: the software synthesizer. The first argument of every
    // call is the guest's work area; this kernel keeps one synthesizer.
    on(0x42778a9f,
        (cpu, _) => _sas.init(_arg(cpu, 1), _arg(cpu, 2), _arg(cpu, 3)));
    on(0xa3589d81, (cpu, _) {
      _sas.mix(_arg(cpu, 1));
      return 0;
    });
    on(0x50a14dfc, (cpu, _) {
      _sas.mix(_arg(cpu, 1), mixLeft: _arg(cpu, 2), mixRight: _arg(cpu, 3));
      return 0;
    });
    on(0x99944089, (cpu, _) =>
        _sas.setVoice(_arg(cpu, 1), _arg(cpu, 2), _arg(cpu, 3), _arg(cpu, 4)));
    on(0xb7660a23, (cpu, _) => _sas.setNoise(_arg(cpu, 1), _arg(cpu, 2)));
    on(0xad84d37f, (cpu, _) => _sas.setPitch(_arg(cpu, 1), _arg(cpu, 2)));
    on(0x440ca7d8, (cpu, _) =>
        _sas.setVolume(_arg(cpu, 1), _arg(cpu, 2), _arg(cpu, 3)));
    on(0x76f01aca, (cpu, _) => _sas.keyOn(_arg(cpu, 1)));
    on(0xa0cf2fa4, (cpu, _) => _sas.keyOff(_arg(cpu, 1)));
    on(0x019b25eb, (cpu, _) => _sas.setAdsr(_arg(cpu, 1), _arg(cpu, 2),
        [for (var i = 3; i < 7; i++) _arg(cpu, i)]));
    on(0x9ec3676a, (cpu, _) => _sas.setAdsrMode(_arg(cpu, 1), _arg(cpu, 2),
        [for (var i = 3; i < 7; i++) _arg(cpu, i)]));
    on(0x5f9529f6,
        (cpu, _) => _sas.setSustainLevel(_arg(cpu, 1), _arg(cpu, 2)));
    on(0xcbcd4f79, (cpu, _) =>
        _sas.setSimpleAdsr(_arg(cpu, 1), _arg(cpu, 2), _arg(cpu, 3)));
    on(0x74ae582a, (cpu, _) => _sas.envelopeHeight(_arg(cpu, 1)));
    on(0x68a46b95, (cpu, _) => _sas.endFlags);
    on(0x2c8e6ab3, (cpu, _) => _sas.pauseFlags);
    on(0x787d04d5,
        (cpu, _) => _sas.setPause(_arg(cpu, 1), _arg(cpu, 2) != 0));
    on(0xbd11b7c2, (cpu, _) => _sas.grain);
    on(0xd1e0a01e, (cpu, _) => _sas.setGrain(_arg(cpu, 1)));
    on(0xe175ef66, (cpu, _) => _sas.outputMode);
    on(0xe855bf76, (cpu, _) {
      _sas.outputMode = _arg(cpu, 1);
      return 0;
    });
    // Reverb type, parameters, effect volume and per-voice send: reverb
    // is not emulated.
    for (final nid in [0x33d4ab37, 0x267a6dd2, 0xd5a229c9, 0xf983b186]) {
      on(nid, (cpu, _) => 0);
    }
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
    return _queueBlock(cpu, channel, _arg(cpu, 2), _arg(cpu, 1), null,
        blocking: blocking);
  }

  /// Queues one block of [channel] from [at] behind the blocks already
  /// queued; a blocking call waits until the block has played out.
  int? _queueBlock(Allegrex cpu, _AudioChannel channel, int at, int volume,
      int? rightVolume,
      {required bool blocking}) {
    final frames = channel.sampleCount;
    final start =
        channel.nextAt > _audioAt(cpu) ? channel.nextAt : _audioAt(cpu);
    channel.nextAt = start + frames;
    if (at != 0) {
      _mixBlock(channel, start, volume, at, rightVolume: rightVolume);
    }
    final rest = channel.nextAt - _audioAt(cpu);
    // A blocking output waits while the channel still holds an earlier
    // block: the new block is queued behind the playing one, so it
    // returns when that one ends and the new one starts to play.
    final wait = start - _audioAt(cpu);
    if (!blocking || wait <= 0 || _inCallback) return rest > 0 ? rest : 0;
    current!.status = PspThreadStatus.waitDelay;
    current!.wakeAt = cpu.clocks + wait * _cpuHz ~/ _audioRate;
    if (current!.wakeAt < _nextDelayWake) _nextDelayWake = current!.wakeAt;
    _schedule(cpu);
    return null;
  }

  int? _audioOutputPanned(Allegrex cpu) {
    final index = _arg(cpu, 0);
    if (index < 0 || index >= 8) return 0x80260002;
    final channel = _audioChannels[index];
    if (!channel.reserved) return 0x80260002;
    // The panned output call always blocks until the block has played.
    return _queueBlock(cpu, channel, _arg(cpu, 3), _arg(cpu, 1), _arg(cpu, 2),
        blocking: true);
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

  // The system setting identifiers of the language and the confirm
  // button, and the values of the integer settings. The failure code of
  // an unknown setting is from public documentation, not checked against
  // hardware.
  static const _paramLanguage = 8, _paramButton = 9;
  static const _systemParams = {
    2: 0, // ad hoc channel: automatic
    3: 0, // wireless power saving: off
    4: 0, // date format: year, month, day
    5: 0, // time format: 24 hours
    6: 540, // time zone: minutes from UTC
    7: 0, // daylight saving: off
    _paramLanguage: 0, // Japanese
    _paramButton: 0, // the circle button confirms
  };
  static const _systemParamFail = 0x80110103;

  /// ReleaseWaitThread: ends the wait of a blocked thread, whose call
  /// returns [_releasedWait]. A thread that does not wait is an error.
  int? _releaseWaitThread(Allegrex cpu, PspImport? _) {
    final thread = threads[_arg(cpu, 0)];
    if (thread == null || identical(thread, current)) return 0x80020198;
    switch (thread.status) {
      case PspThreadStatus.ready:
      case PspThreadStatus.running:
      case PspThreadStatus.dead:
      case PspThreadStatus.dormant:
        return _notWaiting;
    }
    _discWaits.remove(thread.id);
    thread
      ..status = PspThreadStatus.ready
      ..cbWait = false
      ..pendingResult = _releasedWait;
    return 0;
  }

  // The error codes of a released wait and of a thread that does not
  // wait, from the public lists of kernel error codes; not checked
  // against hardware.
  static const _releasedWait = 0x800201aa;
  static const _notWaiting = 0x800201a4;

  int? _startThread(Allegrex cpu, PspImport? _) {
    final thread = threads[_arg(cpu, 0)];
    // An exited thread that was not deleted is dormant again and starts
    // anew.
    if (thread == null ||
        thread.status != PspThreadStatus.dormant &&
            thread.status != PspThreadStatus.dead) {
      return 0x80020198;
    }
    final argSize = _arg(cpu, 1), argAt = _arg(cpu, 2);
    _prepareK0Area(thread);
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

  /// Waits for the start of the [count]th vblank from now; a count below
  /// one waits for the next. The count stays in waitCount.
  /// The Memory Stick queries of sceIoDevctl. The output pointer is in
  /// t0. The stick is always inserted and reports 1 GB free, as 32768
  /// clusters of 64 sectors of 512 bytes; the free space query takes a
  /// pointer to the pointer of its five-word answer as its input.
  int _memoryStickDevctl(Allegrex cpu, int command) {
    switch (command) {
      case 0x02025806 || 0x02425823: // inserted: 1
        final out = cpu.r[8];
        if (out != 0) mem.write32(out, 1);
      case 0x02425818: // free space
        final inAt = _arg(cpu, 2);
        final at = inAt != 0 ? mem.read32(inAt) : 0;
        if (at != 0) {
          mem.write32(at, 32768); // clusters
          mem.write32(at + 4, 32768); // free clusters
          mem.write32(at + 8, 32768);
          mem.write32(at + 12, 512); // bytes per sector
          mem.write32(at + 16, 64); // sectors per cluster
        }
    }
    return 0;
  }

  int? _waitVblank(Allegrex cpu, PspImport? _,
      [int count = 1, int result = 0]) {
    if (_inCallback) return result;
    current!.status = PspThreadStatus.waitVblank;
    current!.waitCount = count.toSigned(32) < 1 ? 1 : count;
    current!.waitBits = result;
    _schedule(cpu);
    return null;
  }

  static const _unknownEventFlag = 0x800201a9;

  /// Whether [pattern] meets the wait for [bits] in [mode]: all bits
  /// (mode bit 0 clear) or any of them (set).
  static bool _eventMatches(int pattern, int bits, int mode) =>
      mode & 1 == 0 ? pattern & bits == bits : pattern & bits != 0;

  /// Applies the clear modes of a satisfied wait: 0x20 clears the waited
  /// bits, 0x10 the whole pattern.
  static int _eventCleared(int pattern, int bits, int mode) {
    if (mode & 0x10 != 0) return 0;
    if (mode & 0x20 != 0) return pattern & ~bits;
    return pattern;
  }

  /// WaitEventFlag and PollEventFlag. A timeout is not counted: the wait
  /// lasts until the bits arrive.
  int? _waitEventFlag(Allegrex cpu, {required bool poll}) {
    final id = _arg(cpu, 0);
    final flag = _eventFlags[id];
    if (flag == null) return _unknownEventFlag;
    final bits = _arg(cpu, 1), mode = _arg(cpu, 2), outAt = _arg(cpu, 3);
    if (bits == 0) return 0x800201b5;
    if (_eventMatches(flag.pattern, bits, mode)) {
      if (outAt != 0) mem.write32(outAt, flag.pattern);
      flag.pattern = _eventCleared(flag.pattern, bits, mode);
      return 0;
    }
    if (poll || _inCallback) {
      if (outAt != 0) mem.write32(outAt, flag.pattern);
      return 0x800201af;
    }
    current!
      ..status = PspThreadStatus.waitEvent
      ..waitEvent = id
      ..waitBits = bits
      ..waitMode = mode
      ..waitOutAt = outAt;
    _schedule(cpu);
    return null;
  }

  int? _setEventFlag(Allegrex cpu, PspImport? _) {
    final id = _arg(cpu, 0);
    final flag = _eventFlags[id];
    if (flag == null) return _unknownEventFlag;
    flag.pattern |= _arg(cpu, 1);
    for (final thread in threads.values) {
      if (thread.status != PspThreadStatus.waitEvent ||
          thread.waitEvent != id ||
          !_eventMatches(flag.pattern, thread.waitBits, thread.waitMode)) {
        continue;
      }
      if (thread.waitOutAt != 0) mem.write32(thread.waitOutAt, flag.pattern);
      flag.pattern =
          _eventCleared(flag.pattern, thread.waitBits, thread.waitMode);
      thread.status = PspThreadStatus.ready;
      thread.pendingResult = 0;
    }
    _preempt(cpu);
    return 0;
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

  int? _lockMutex(Allegrex cpu, {required bool blocking}) {
    final mutex = _mutexes[_arg(cpu, 0)];
    if (mutex == null) return 0x800201c3;
    final count = _arg(cpu, 1) <= 0 ? 1 : _arg(cpu, 1);
    final self = current?.id ?? 0;
    if (mutex.count == 0 || mutex.owner == self) {
      mutex.owner = self;
      mutex.count += count;
      return 0;
    }
    if (!blocking || _inCallback) return 0x800201c4;
    final timeout = _arg(cpu, 2);
    if (timeout != 0 && mem.read32(timeout) == 0) return 0x800201b9;
    current!.status = PspThreadStatus.waitSema;
    current!.waitSema = _arg(cpu, 0);
    current!.waitCount = count;
    _schedule(cpu);
    return null;
  }

  int? _unlockMutex(Allegrex cpu, PspImport? _) {
    final id = _arg(cpu, 0);
    final mutex = _mutexes[id];
    if (mutex == null) return 0x800201c3;
    final count = _arg(cpu, 1) <= 0 ? 1 : _arg(cpu, 1);
    if (mutex.count == 0 || mutex.owner != (current?.id ?? 0)) {
      return 0x800201c5;
    }
    mutex.count -= count;
    if (mutex.count > 0) return 0;
    mutex.count = 0;
    mutex.owner = 0;
    for (final thread in threads.values) {
      if (thread.status == PspThreadStatus.waitSema && thread.waitSema == id) {
        mutex.owner = thread.id;
        mutex.count = thread.waitCount;
        thread.status = PspThreadStatus.ready;
        thread.pendingResult = 0;
        break;
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
      // A thread that has not started and one that has exited are both
      // dormant (0x10); 0x20 is the killed status.
      PspThreadStatus.dead || PspThreadStatus.dormant => 0x10,
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

  // kernel error codes of the pools, as recalled from the public SDK
  // error list; only the success paths are checked against games
  static const _unknownFpl = 0x8002019d;
  static const _noMemory = 0x800200d9;

  /// sceKernelCreateFpl(name, partition, attr, blockSize, count, option):
  /// the blocks come from the heap arena, each rounded up to a word.
  int? _createFpl(Allegrex cpu, PspImport? _) {
    final blockSize = (_arg(cpu, 3) + 3) & ~3;
    final count = _arg(cpu, 4);
    if (blockSize <= 0 || count <= 0) return 0x800201bc;
    final addr = _reserve(blockSize * count, 0x100);
    if (addr < 0) return _noMemory;
    final id = _nextId++;
    _fpls[id] = _Fpl(addr, blockSize, count);
    return id;
  }

  /// sceKernelAllocateFpl(uid, data, timeout) and its CB and try forms:
  /// writes the address of a free block to data
  int? _allocateFpl(Allegrex cpu, PspImport? _) {
    final fpl = _fpls[_arg(cpu, 0)];
    if (fpl == null) return _unknownFpl;
    final index = fpl.used.indexOf(false);
    if (index < 0) return _noMemory;
    fpl.used[index] = true;
    mem.write32(_arg(cpu, 1), fpl.addr + index * fpl.blockSize);
    return 0;
  }

  /// sceKernelFreeFpl(uid, data)
  int? _freeFpl(Allegrex cpu, PspImport? _) {
    final fpl = _fpls[_arg(cpu, 0)];
    if (fpl == null) return _unknownFpl;
    final offset = _arg(cpu, 1) - fpl.addr;
    final index = offset ~/ fpl.blockSize;
    if (offset < 0 ||
        offset % fpl.blockSize != 0 ||
        index >= fpl.used.length ||
        !fpl.used[index]) {
      return 0x800201bd;
    }
    fpl.used[index] = false;
    return 0;
  }

  /// sceKernelAllocPartitionMemory(partition, name, type, size, addr):
  /// the aligned types (3 and 4) take the alignment from addr.
  int? _allocBlock(Allegrex cpu, PspImport? _) {
    final type = _arg(cpu, 2), size = _arg(cpu, 3);
    var align = 0x100;
    if (type == 3 || type == 4) {
      final want = cpu.r[8] & 0xffffffff;
      if (want != 0 && want & (want - 1) == 0 && want > align) align = want;
    }
    final addr = _reserve(size, align);
    if (addr < 0) return _noMemory;
    final id = _nextId++;
    _blocks[id] = _Block(addr, (size + 0xff) & ~0xff);
    return id;
  }

  /// The ranges of the arena in use, as (address, end) by address: the
  /// partition blocks, which include the loaded modules, and the pools.
  List<(int, int)> _arenaRanges() => [
        for (final block in _blocks.values)
          (block.addr, block.addr + block.size),
        for (final fpl in _fpls.values)
          (fpl.addr, fpl.addr + fpl.blockSize * fpl.used.length),
      ]..sort((a, b) => a.$1 - b.$1);

  /// Reserves [size] bytes at an address aligned to [align] in the user
  /// arena, or returns -1. Heap memory and thread stacks share the user
  /// partition: the arena grows up from the module image, stacks grow
  /// down from its top, and the arena may not cross the stack frontier.
  /// The lowest gap that fits is taken, so released memory is used
  /// again; [_heapAt] is the top of the arena.
  int _reserve(int size, int align) {
    size = (size + 0xff) & ~0xff;
    var at = (_heapFloor + align - 1) & -align;
    for (final (start, end) in _arenaRanges()) {
      if (end <= at) continue;
      if (start >= at + size) break;
      at = (end + align - 1) & -align;
    }
    if (at < _heapFloor || at + size > _stackAt) return -1;
    if (at + size > _heapAt) _heapAt = at + size;
    return at;
  }

  /// The free memory of the arena: (total, largest span).
  (int, int) _arenaFree() {
    var total = 0, largest = 0, at = _heapFloor;
    void gap(int end) {
      final size = (end - at) & ~0xff;
      if (size > 0) {
        total += size;
        if (size > largest) largest = size;
      }
    }

    for (final (start, end) in _arenaRanges()) {
      if (start > at) gap(start);
      if (end > at) at = end;
    }
    gap(_stackAt);
    return (total, largest);
  }

  /// Points the stubs of [image] at system calls, then rewrites every
  /// stub of every module whose function another module exports into a
  /// jump to that function.
  void _linkImports(PspModuleImage image) {
    for (final import in image.imports) {
      import.code = _nextImportCode++;
      _byCode[import.code] = import;
      mem.write32(import.stubAddr, 0x0000000c | (import.code << 6));
      mem.write32(import.stubAddr + 4, 0x03e00008);
    }
    for (final user in _images) {
      for (final import in user.imports) {
        for (final owner in _images) {
          if (identical(owner, user)) continue;
          final target = owner.exports[(import.library, import.nid)];
          if (target == null) continue;
          mem.write32(
              import.stubAddr, 0x08000000 | ((target >> 2) & 0x3ffffff));
          mem.write32(import.stubAddr + 4, 0);
          break;
        }
      }
    }
  }

  /// Loads a module file into memory above the heap. Files that are not
  /// plain modules (the encrypted ones) are accepted without being loaded.
  int _loadModuleImage(Uint8List body) {
    if (!PspElf.isElf(body) || body.length < 52) return _moduleIdBase + 0x1000;
    final size = (PspElf.memorySize(body) + 0xff) & ~0xff;
    final base = _reserve(size, 0x100);
    if (base < 0) return _noMemory;
    final PspModuleImage image;
    try {
      image = PspElf.load(mem, body, loadBase: base);
    } on FormatException {
      return _moduleIdBase + 0x1000;
    }
    // The module keeps its memory as a block that no call names.
    _blocks[_nextId++] = _Block(base, size);
    _images.add(image);
    _linkImports(image);
    return _moduleIdBase + _images.length - 1;
  }

  int? _loadModuleById(Allegrex cpu, PspImport? _) {
    final file = _files[_arg(cpu, 0)];
    final node = file?.node;
    if (node == null) return _moduleIdBase + 0x1000;
    final body = disc?.readBytes(node.entry, 0, node.entry.size);
    if (body == null) return 0x80010005;
    return _loadModuleImage(body);
  }

  int? _loadModuleByPath(Allegrex cpu, PspImport? _) {
    final (device, rel) = _resolve(mem.readString(_arg(cpu, 0), 256));
    if (device != 'disc0' && device != 'umd0') return _moduleIdBase + 0x1000;
    final node = disc?.lookup(rel);
    if (node == null || node.isDirectory) return 0x80010002;
    final body = disc?.readBytes(node.entry, 0, node.entry.size);
    if (body == null) return 0x80010005;
    return _loadModuleImage(body);
  }

  /// Runs the start function of a loaded module, which is the export the
  /// nameless entry lists under 0xd632acdb or else the file's entry point.
  int? _startLoadedModule(Allegrex cpu, PspImport? _) {
    final id = _arg(cpu, 0);
    final index = id - _moduleIdBase;
    if (index <= 0 || index >= _images.length) return 0;
    final image = _images[index];
    final start = image.exports[('', 0xd632acdb)] ?? image.entry;
    // A module without a start function has no valid entry point either.
    final phys = PspMemory.physical(start);
    if (!image.segments.any((s) => phys >= s.start && phys < s.end)) return id;
    final statusAt = _arg(cpu, 3);
    final saved = cpu.r[28];
    cpu.r[28] = image.gp;
    final result = _runGuest(cpu, start, _arg(cpu, 1), _arg(cpu, 2), 0);
    cpu.r[28] = saved;
    if (statusAt != 0) mem.write32(statusAt, result);
    return id;
  }

  static const _linesPerFrame = 286;

  /// The horizontal sync lines since the start, from the clock.
  int _hcount(Allegrex cpu) =>
      cpu.clocks * _linesPerFrame * displayHz ~/ _cpuHz;

  int? _readCtrlWait(Allegrex cpu, bool negative) {
    final count = _readCtrl(cpu, null, negative);
    return _arg(cpu, 0) == 0 ? count : _waitVblank(cpu, null, 1, count!);
  }

  int? _readCtrl(Allegrex cpu, PspImport? _, [bool negative = false]) {
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
    mem.write32(at + 4, negative ? ~buttons & 0xffffffff : buttons);
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
    return colon < 0 ? null : _canonicalDevice(path.substring(0, colon));
  }

  /// The device name with its aliases folded: `umd:` and `umd1:` name the
  /// same disc block device as `umd0:`.
  static String _canonicalDevice(String device) {
    final lower = device.toLowerCase();
    return lower == 'umd' || lower == 'umd1' ? 'umd0' : lower;
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
    return (_canonicalDevice(joined.substring(0, colon)),
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
      // the umd device without a path is the disc as a block device,
      // addressed in sectors from the start of the file system
      if (device == 'umd0' && (rel.isEmpty || rel == '/')) {
        final whole = disc?.wholeDisc;
        if (whole == null) return 0x80010002;
        final fd = _nextFd++;
        _files[fd] = _OpenFile.disc(path, whole, unit: 2048);
        return fd;
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
    if (fd != null && fd >= 0) _asyncDone(fd, fd);
    return fd;
  }

  int? _ioRead(Allegrex cpu, PspImport? _) => _readFile(cpu, true);

  /// [length] units of [file] on the disc from its position, or null while
  /// the drive has not loaded them
  Uint8List? _readDisc(_OpenFile file, PspDiscNode node, int length) =>
      disc?.readBytes(
          node.entry, file.position * file.unit, length * file.unit);

  /// Reads from an open file. A disc read whose sectors the drive has
  /// not loaded yet suspends the calling thread instead of reporting a
  /// short read: the drive loads in the background, and the scheduler
  /// retries the read as emulated time passes, the way a real read
  /// waits for the disc. After about 200 ms of emulated time without
  /// new sectors the read gives up and reports zero bytes. Asynchronous
  /// reads never suspend; they report what is available at once.
  int? _readFile(Allegrex cpu, bool mayBlock) {
    final fd = _arg(cpu, 0);
    final file = _files[fd];
    if (file == null) return 0;
    final at = _arg(cpu, 1), length = _arg(cpu, 2);
    final node = file.node;
    if (node != null) {
      final data = _readDisc(file, node, length);
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
      file.position += data.length ~/ file.unit;
      return data.length ~/ file.unit;
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

  /// Counts a failed attempt of [wait]. The time limit runs from the
  /// last attempt that found more of the data loaded, so a long read
  /// that the drive keeps delivering does not give up.
  void _countProgress(_DiscWait wait) {
    final loaded = disc?.lastLoaded ?? 0;
    if (loaded > wait.loaded) {
      wait.loaded = loaded;
      wait.attempts = 0;
    } else {
      wait.attempts++;
    }
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
      final data = node == null ? null : _readDisc(file!, node, wait!.length);
      if (data != null) {
        mem.writeBytes(wait!.at, data);
        file!.position += data.length ~/ file.unit;
        thread.pendingResult = data.length ~/ file.unit;
      } else if (wait != null && wait.attempts < 200) {
        _countProgress(wait);
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
    final file = _files[fd];
    if (file == null) return 0x80010002;
    final node = file.node;
    if (node != null && _readDisc(file, node, _arg(cpu, 2)) == null) {
      _asyncPending[fd] = _DiscWait(fd, _arg(cpu, 1), _arg(cpu, 2));
      _async.remove(fd);
      final retryAt = cpu.clocks + _cpuHz ~/ 1000;
      if (retryAt < _nextDelayWake) _nextDelayWake = retryAt;
      return 0;
    }
    _asyncDone(fd, _readFile(cpu, false) ?? 0);
    return 0;
  }

  /// Finishes the pending asynchronous disc reads whose sectors arrived;
  /// called from [wakeDue].
  void _retryAsyncReads(Allegrex cpu) {
    for (final fd in _asyncPending.keys.toList()) {
      final wait = _asyncPending[fd]!;
      final file = _files[fd];
      final node = file?.node;
      final data = node == null ? null : _readDisc(file!, node, wait.length);
      int result;
      if (data != null) {
        mem.writeBytes(wait.at, data);
        file!.position += data.length ~/ file.unit;
        result = data.length ~/ file.unit;
      } else if (node != null && wait.attempts < 200) {
        _countProgress(wait);
        if (cpu.clocks + _cpuHz ~/ 1000 < _nextDelayWake) {
          _nextDelayWake = cpu.clocks + _cpuHz ~/ 1000;
        }
        continue;
      } else {
        result = 0;
      }
      _asyncPending.remove(fd);
      _asyncDone(fd, result);
      for (final thread in threads.values) {
        if (thread.status == PspThreadStatus.waitAsync &&
            thread.waitSema == fd) {
          _writeAsyncResult(thread.waitOutAt, _async.remove(fd) ?? 0);
          thread.status = PspThreadStatus.ready;
          thread.pendingResult = 0;
        }
      }
    }
  }

  void _writeAsyncResult(int at, int result) {
    if (at == 0) return;
    mem.write32(at, result & 0xffffffff);
    mem.write32(at + 4, (result >> 32) & 0xffffffff);
  }

  /// sceIoWaitAsync: blocks until the call on the file has finished.
  int? _ioWaitAsync(Allegrex cpu, PspImport? _) {
    final fd = _arg(cpu, 0);
    if (_closedAsync.contains(fd)) return _ioPollAsync(cpu, null);
    if (!_files.containsKey(fd)) return _badFileDescriptor;
    if (_asyncPending.containsKey(fd) && !_inCallback) {
      current!
        ..status = PspThreadStatus.waitAsync
        ..waitSema = fd
        ..waitOutAt = _arg(cpu, 1);
      _schedule(cpu);
      return null;
    }
    return _ioPollAsync(cpu, null);
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
    _asyncDone(fd, _ioWrite(cpu, null) ?? 0);
    return 0;
  }

  int? _ioCloseAsync(Allegrex cpu, PspImport? _) {
    final fd = _arg(cpu, 0);
    if (!_files.containsKey(fd)) return _badFileDescriptor;
    _ioClose(cpu, null);
    _closedAsync.add(fd);
    _async[fd] = 0;
    return 0;
  }

  int? _ioClose(Allegrex cpu, PspImport? _) {
    final fd = _arg(cpu, 0);
    final file = _files.remove(fd);
    if (file != null && file.dirty) memStick.flush();
    _dirs.remove(fd);
    _async.remove(fd);
    _asyncPending.remove(fd);
    _asyncCallbacks.remove(fd);
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
    if (file == null) {
      // a 64-bit error: the code in v0 and its sign in v1
      cpu.r[2] = _badFileDescriptor;
      cpu.r[3] = 0xffffffff;
      return null;
    }
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
    _asyncDone(fd, _ioLseek32(cpu, null) ?? 0);
    return 0;
  }

  int? _ioLseekAsync(Allegrex cpu, PspImport? _) {
    final fd = _arg(cpu, 0);
    final file = _files[fd];
    if (file == null) return 0x80010002;
    final offset =
        (cpu.r[7] & 0xffffffff) << 32 | (cpu.r[6] & 0xffffffff);
    _asyncDone(fd, _seek(file, offset, cpu.r[8]));
    return 0;
  }

  static const _badFileDescriptor = 0x80010009;

  int? _ioPollAsync(Allegrex cpu, PspImport? _) {
    final fd = _arg(cpu, 0);
    if (!_closedAsync.remove(fd) && !_files.containsKey(fd)) {
      return _badFileDescriptor;
    }
    if (_asyncPending.containsKey(_arg(cpu, 0))) return 1; // still busy
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
  /// on the stick, all three timestamps are the entry's date, and the
  /// first private word is a disc file's first sector, which games use
  /// to read the file through the raw disc device.
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
    mem.write32(at + 64, ent.lba);
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
    writer.int32(_fpls.length);
    for (final MapEntry(key: id, value: fpl) in _fpls.entries) {
      writer.int32(id);
      writer.int32(fpl.addr);
      writer.int32(fpl.blockSize);
      writer.int32(fpl.used.length);
      for (final used in fpl.used) {
        writer.boolean(used);
      }
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
    writer.int32(_compiledSdkVersion);
    writer.int32(_compilerVersion);
    writer.boolean(_interruptsEnabled);
    writer.int32(_pendingHandlers.length);
    for (final (func, id, arg) in _pendingHandlers) {
      writer.int32(func);
      writer.int32(id);
      writer.int32(arg);
    }
    writer.int32(_subIntrs.length);
    for (final MapEntry(key: (interrupt, sub), value: handler)
        in _subIntrs.entries) {
      writer.int32(interrupt);
      writer.int32(sub);
      writer.int32(handler.func);
      writer.int32(handler.arg);
      writer.boolean(handler.enabled);
    }
    _sas.saveState(writer);
    writer.boolean(_output2.reserved);
    writer.int32(_output2.sampleCount);
    writer.int64(_output2.nextAt);
    writer.int32(_eventFlags.length);
    for (final MapEntry(key: id, value: flag) in _eventFlags.entries) {
      writer.ints([id, flag.pattern, flag.attr]);
    }
    _mpeg.saveState(writer);
    writer.int32(_puts.length);
    for (final MapEntry(key: id, value: put) in _puts.entries) {
      writer.ints([id, put.want, put.done, put.returnAt]);
    }
    writer.int32(_callbacks.length);
    for (final MapEntry(key: id, value: c) in _callbacks.entries) {
      writer.ints([id, c.thread, c.func, c.common, c.count, c.arg]);
    }
    for (final thread in threads.values) {
      writer.ints([
        thread.wakeupCount, thread.waitEvent, thread.waitBits, //
        thread.waitMode, thread.waitOutAt,
      ]);
    }
    _saveFiles(writer);
    _atrac.saveState(writer);
    writer.ints([_savedata.status, _savedata.param, _savedata.mode]);
    writer.int32(_heapFloor);
    // The mutexes, the message boxes with their messages, the asynchronous
    // reads that wait for the disc and the callbacks of the asynchronous
    // files.
    writer.ints([
      for (final MapEntry(key: id, value: m) in _mutexes.entries)
        ...[id, m.owner, m.count],
    ]);
    writer.int32(_mbxs.length);
    for (final MapEntry(key: id, value: mbx) in _mbxs.entries) {
      writer.ints([id, ...mbx.messages]);
    }
    writer.ints([
      for (final w in _asyncPending.values)
        ...[w.fd, w.at, w.length, w.attempts, w.loaded],
    ]);
    writer.ints([
      for (final MapEntry(key: fd, value: (id, arg)) in _asyncCallbacks.entries)
        ...[fd, id, arg],
    ]);
    writer.ints([..._closedAsync]);
    // the clocks and the dialogs that are open
    writer.ints([_cpuMhz, _busMhz, _msgDialog.status, _keyboard.status]);
    _saveModules(writer);
  }

  /// Saves the modules loaded after the main one, whose stubs point at
  /// system call codes given when they were loaded: the image and its
  /// imports with their codes and its exports. The main module is linked
  /// again the same way when the program starts, and the stubs themselves
  /// are in memory.
  void _saveModules(StateWriter writer) {
    writer.int32(_nextImportCode);
    writer.int32(_images.length - 1);
    for (final image in _images.skip(1)) {
      writer.string(image.name);
      writer.ints([
        image.entry, image.gp, image.base, image.end, //
        for (final s in image.segments) ...[s.start, s.end],
      ]);
      writer.int32(image.imports.length);
      for (final import in image.imports) {
        writer.string(import.library);
        writer.ints([import.nid, import.stubAddr, import.code]);
      }
      writer.int32(image.exports.length);
      for (final MapEntry(key: (library, nid), value: at)
          in image.exports.entries) {
        writer.string(library);
        writer.ints([nid, at]);
      }
    }
  }

  void _loadModules(StateReader reader) {
    _nextImportCode = reader.int32();
    final main = _images.first;
    _images
      ..clear()
      ..add(main);
    _byCode.removeWhere((_, import) => !main.imports.contains(import));
    for (var n = reader.int32(); n > 0; n--) {
      final name = reader.string();
      final x = reader.ints();
      final imports = <PspImport>[];
      for (var i = reader.int32(); i > 0; i--) {
        final library = reader.string();
        final y = reader.ints();
        final import = PspImport(library, y[0], y[1])..code = y[2];
        imports.add(import);
        _byCode[import.code] = import;
      }
      final exports = <(String, int), int>{};
      for (var i = reader.int32(); i > 0; i--) {
        final library = reader.string();
        final y = reader.ints();
        exports[(library, y[0])] = y[1];
      }
      _images.add(PspModuleImage(name, x[0], x[1], x[2], x[3], imports, [
        for (var i = 4; i + 1 < x.length; i += 2) (start: x[i], end: x[i + 1]),
      ], exports));
    }
  }

  /// Saves the open files: a disc or memory stick file by its path, which
  /// a load looks up again, and a file of another device with its
  /// contents. Then the asynchronous results and the suspended disc reads.
  void _saveFiles(StateWriter writer) {
    writer.int32(_nextFd);
    writer.int32(_files.length);
    for (final MapEntry(key: fd, value: file) in _files.entries) {
      final kind = file.node != null
          ? 1
          : file.msNode != null
              ? 2
              : 0;
      writer.ints([fd, kind, file.access, file.append ? 1 : 0, file.unit, //
        file.position, file.dirty ? 1 : 0]);
      writer.string(file.path);
      writer.bytes(kind == 0 ? file.content : const <int>[]);
    }
    writer.ints([for (final e in _async.entries) ...[e.key, e.value]]);
    writer.ints([
      for (final MapEntry(key: id, value: w) in _discWaits.entries)
        ...[id, w.fd, w.at, w.length, w.attempts]
    ]);
  }

  void _loadFiles(StateReader reader) {
    _nextFd = reader.int32();
    final count = reader.int32();
    for (var i = 0; i < count; i++) {
      final x = reader.ints();
      final path = reader.string();
      final content = reader.bytes();
      final (fd, kind, access, append, unit) = (x[0], x[1], x[2], x[3], x[4]);
      final _OpenFile file;
      if (kind == 1) {
        final (_, rel) = _resolve(path);
        final node = unit == 2048 ? disc?.wholeDisc : disc?.lookup(rel);
        if (node == null) continue;
        file = _OpenFile.disc(path, node, unit: unit);
      } else if (kind == 2) {
        final (_, rel) = _resolve(path);
        final node = memStick.lookup(rel);
        if (node == null) continue;
        file = _OpenFile.stick(path, node, access, append != 0);
      } else {
        file = _OpenFile(path)..content.addAll(content);
      }
      file
        ..position = x[5]
        ..dirty = x[6] != 0;
      _files[fd] = file;
    }
    final asyncs = reader.ints();
    for (var i = 0; i + 1 < asyncs.length; i += 2) {
      _async[asyncs[i]] = asyncs[i + 1];
    }
    final waits = reader.ints();
    for (var i = 0; i + 4 < waits.length; i += 5) {
      _discWaits[waits[i]] =
          _DiscWait(waits[i + 1], waits[i + 2], waits[i + 3])
            ..attempts = waits[i + 4];
    }
  }

  void loadState(StateReader reader) {
    final legacy = reader.version == 4;
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
    _fpls.clear();
    final fplCount = reader.version >= 6 ? reader.int32() : 0;
    for (var i = 0; i < fplCount; i++) {
      final id = reader.int32();
      final fpl = _Fpl(reader.int32(), reader.int32(), reader.int32());
      for (var j = 0; j < fpl.used.length; j++) {
        fpl.used[j] = reader.boolean();
      }
      _fpls[id] = fpl;
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
    final hasStartupState = reader.version >= 6;
    _compiledSdkVersion = hasStartupState ? reader.int32() : 0;
    _compilerVersion = hasStartupState ? reader.int32() : 0;
    _interruptsEnabled = !hasStartupState || reader.boolean();
    _pendingHandlers.clear();
    final callbackCount = hasStartupState ? reader.int32() : 0;
    for (var i = 0; i < callbackCount; i++) {
      _pendingHandlers
          .addLast((reader.int32(), reader.int32(), reader.int32()));
    }
    _subIntrs.clear();
    final subIntrCount = hasStartupState ? reader.int32() : 0;
    for (var i = 0; i < subIntrCount; i++) {
      final key = (reader.int32(), reader.int32());
      _subIntrs[key] = _SubIntr(reader.int32(), reader.int32())
        ..enabled = reader.boolean();
    }
    _eventFlags.clear();
    _callbacks.clear();
    _output2
      ..reserved = false
      ..sampleCount = 0
      ..format = 0
      ..nextAt = 0;
    if (reader.version >= 7) {
      _sas.loadState(reader);
      _output2.reserved = reader.boolean();
      _output2.sampleCount = reader.int32();
      _output2.nextAt = reader.int64();
      final flagCount = reader.int32();
      for (var i = 0; i < flagCount; i++) {
        final x = reader.ints();
        _eventFlags[x[0]] = _EventFlag(x[1], x[2]);
      }
      _mpeg.loadState(reader);
      _puts.clear();
      final putCount = reader.int32();
      for (var i = 0; i < putCount; i++) {
        final x = reader.ints();
        _puts[x[0]] = _Put(x[1], x[2], x[3]);
      }
      final callbackCount = reader.int32();
      for (var i = 0; i < callbackCount; i++) {
        final x = reader.ints();
        _callbacks[x[0]] = _Callback(x[1], x[2], x[3])
          ..count = x[4]
          ..arg = x[5];
      }
      for (final thread in threads.values) {
        final x = reader.ints();
        thread
          ..wakeupCount = x[0]
          ..waitEvent = x[1]
          ..waitBits = x[2]
          ..waitMode = x[3]
          ..waitOutAt = x[4];
      }
    }
    _files.clear();
    _dirs.clear();
    _async.clear();
    _closedAsync.clear();
    _asyncPending.clear();
    _asyncCallbacks.clear();
    _discWaits.clear();
    if (reader.version >= 7) {
      _loadFiles(reader);
      _atrac.loadState(reader);
    } else {
      _sas.init(256, PspSas.voiceCount, 0);
    }
    _savedata
      ..status = PspSavedataDialog.statusNone
      ..param = 0
      ..mode = -1;
    if (reader.version >= 8) {
      final x = reader.ints();
      _savedata
        ..status = x[0]
        ..param = x[1]
        ..mode = x[2];
    }
    _heapFloor = reader.version >= 9 ? reader.int32() : _heapAt;
    _mutexes.clear();
    _mbxs.clear();
    if (reader.version >= 9) {
      final mutexes = reader.ints();
      for (var i = 0; i + 2 < mutexes.length; i += 3) {
        _mutexes[mutexes[i]] = _Mutex()
          ..owner = mutexes[i + 1]
          ..count = mutexes[i + 2];
      }
      for (var n = reader.int32(); n > 0; n--) {
        final x = reader.ints();
        _mbxs[x[0]] = _Mbx()..messages.addAll(x.skip(1));
      }
      final pending = reader.ints();
      for (var i = 0; i + 4 < pending.length; i += 5) {
        _asyncPending[pending[i]] =
            _DiscWait(pending[i], pending[i + 1], pending[i + 2])
              ..attempts = pending[i + 3]
              ..loaded = pending[i + 4];
      }
      final callbacks = reader.ints();
      for (var i = 0; i + 2 < callbacks.length; i += 3) {
        _asyncCallbacks[callbacks[i]] = (callbacks[i + 1], callbacks[i + 2]);
      }
      _closedAsync.addAll(reader.ints());
      final misc = reader.ints();
      _cpuMhz = misc[0];
      _busMhz = misc[1];
      _msgDialog.status = misc[2];
      _keyboard.status = misc[3];
      _loadModules(reader);
    }
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

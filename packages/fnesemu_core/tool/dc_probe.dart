import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/disc_bootstrap.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/pad_source.dart';

import 'cdrom_drive.dart';
import 'headless/session.dart' show savePng, wavBytes;
import 'local_disc.dart';

/// Runs user-owned boot assets without copying or modifying their source files.
Future<void> main(List<String> args) async {
  final coreBringUp = args.contains('--core-bring-up');
  final attachAfterState = args.contains('--attach-disc-after-state');
  final bypassVerification =
      coreBringUp || args.contains('--bypass-bios-verification');
  final bypassAicaDsp = args.contains('--bypass-aica-dsp');
  final fallbackAicaDsp = coreBringUp || args.contains('--fallback-aica-dsp');
  final byteAddressAdpcm = args.contains('--byte-address-adpcm');
  final approximateFilter =
      coreBringUp || args.contains('--approximate-aica-filter');
  final stopOnSleep = args.contains('--stop-on-sleep');
  final clearErrors = args.contains('--clear-errors');
  final traceTa = args.contains('--trace-ta');
  final stopOnLowRamCode = args.contains('--stop-on-low-ram-code');
  final stopOnInterrupt = args.contains('--stop-on-interrupt');
  final traceExecution = args.contains('--trace-execution');
  final traceDisc = args.contains('--trace-disc');
  final bootDisc = args.contains('--boot-disc-unscrambled');
  final skipLicense = args.contains('--skip-license-screen');
  final directDiscEntry = args.contains('--direct-disc-entry');
  final secondBootstrap = args.contains('--second-bootstrap');
  if (skipLicense && !bootDisc) {
    throw ArgumentError(
        '--skip-license-screen requires --boot-disc-unscrambled');
  }
  if (directDiscEntry && !bootDisc) {
    throw ArgumentError('--direct-disc-entry requires --boot-disc-unscrambled');
  }
  if (secondBootstrap && !bootDisc) {
    throw ArgumentError('--second-bootstrap requires --boot-disc-unscrambled');
  }
  final watchDiscEntry = bootDisc || args.contains('--watch-disc-entry');
  final quiesceBiosIrqs = bootDisc || args.contains('--quiesce-bios-irqs');
  final pressArg = args.where((arg) => arg.startsWith('--press=')).firstOrNull;
  final pressName = pressArg?.substring('--press='.length);
  final driveFormatArg =
      args.where((arg) => arg.startsWith('--drive-format=')).firstOrNull;
  final driveFormat = driveFormatArg == null
      ? null
      : int.parse(driveFormatArg.substring('--drive-format='.length),
          radix: 16);
  if (driveFormat != null &&
      (!bypassVerification ||
          ![0x10, 0x20, 0x30, 0x80].contains(driveFormat))) {
    throw ArgumentError(
        'Diagnostic drive format requires the explicit boot bypass');
  }
  final stopAtArg =
      args.where((arg) => arg.startsWith('--stop-at=')).firstOrNull;
  final stopAt = stopAtArg == null
      ? null
      : int.parse(stopAtArg.substring('--stop-at='.length), radix: 16);
  final watchRamArg =
      args.where((arg) => arg.startsWith('--watch-ram=')).firstOrNull;
  final watchRam = watchRamArg == null
      ? null
      : int.parse(watchRamArg.substring('--watch-ram='.length), radix: 16);
  if (watchRam != null &&
      (watchRam < 0 || watchRam > 0xfffffc || watchRam & 3 != 0)) {
    throw ArgumentError('--watch-ram requires an aligned RAM offset');
  }
  final gpioArg =
      args.where((arg) => arg.startsWith('--gpio-high=')).firstOrNull;
  final gpioHigh = gpioArg == null
      ? 0
      : int.parse(gpioArg.substring('--gpio-high='.length), radix: 16);
  final linkArg =
      args.where((arg) => arg.startsWith('--gpio-link=')).firstOrNull;
  final gpioLink = linkArg == null
      ? 0
      : int.parse(linkArg.substring('--gpio-link='.length), radix: 16);
  final scaleArg =
      args.where((arg) => arg.startsWith('--clock-scale=')).firstOrNull;
  final clockScale = scaleArg == null
      ? 1
      : int.parse(scaleArg.substring('--clock-scale='.length));
  if (clockScale < 1 || clockScale > 1024) {
    throw ArgumentError.value(clockScale, 'clock-scale');
  }
  final captureArg =
      args.where((arg) => arg.startsWith('--capture=')).firstOrNull;
  final capture = captureArg?.substring('--capture='.length);
  final saveArg =
      args.where((arg) => arg.startsWith('--save-state=')).firstOrNull;
  final loadArg =
      args.where((arg) => arg.startsWith('--load-state=')).firstOrNull;
  final savePath = saveArg?.substring('--save-state='.length);
  final loadPath = loadArg?.substring('--load-state='.length);
  args = args
      .where((arg) =>
          arg != '--bypass-bios-verification' &&
          arg != '--core-bring-up' &&
          arg != '--attach-disc-after-state' &&
          arg != '--bypass-aica-dsp' &&
          arg != '--fallback-aica-dsp' &&
          arg != '--byte-address-adpcm' &&
          arg != '--approximate-aica-filter' &&
          arg != '--stop-on-sleep' &&
          arg != '--clear-errors' &&
          arg != '--trace-ta' &&
          arg != '--stop-on-low-ram-code' &&
          arg != '--stop-on-interrupt' &&
          arg != '--trace-execution' &&
          arg != '--trace-disc' &&
          arg != '--boot-disc-unscrambled' &&
          arg != '--skip-license-screen' &&
          arg != '--direct-disc-entry' &&
          arg != '--second-bootstrap' &&
          arg != '--watch-disc-entry' &&
          arg != '--quiesce-bios-irqs' &&
          arg != pressArg &&
          arg != driveFormatArg &&
          arg != stopAtArg &&
          arg != watchRamArg &&
          arg != captureArg &&
          arg != gpioArg &&
          arg != linkArg &&
          arg != scaleArg &&
          arg != saveArg &&
          arg != loadArg)
      .toList();
  if (args.length < 2 || args.length > 4) {
    stderr.writeln(
        'Usage: dart run tool/dc_probe.dart [OPTIONS] BOOT_ROM FLASH [INSTRUCTIONS [DISC_IMAGE]]\n'
        'Options: --core-bring-up (core-owned provisional BIOS startup profile)\n'
        '  --attach-disc-after-state (insert media after restoring a no-disc BIOS state)\n'
        '  --approximate-aica-filter (unverified graph-based low-pass model)\n'
        '  --fallback-aica-dsp (bypass only statically unsupported DSP programs)\n'
        '         --bypass-bios-verification --gpio-link=HEX --gpio-high=HEX\n'
        '         --bypass-aica-dsp --byte-address-adpcm --drive-format=HEX\n'
        '         --clock-scale=N --capture=DIR --stop-on-sleep --clear-errors --trace-ta\n'
        '         --load-state=PATH --save-state=PATH --trace-disc --press=BUTTONS\n'
        '         --boot-disc-unscrambled (explicit diagnostic boot from initialized BIOS)\n'
        '         --skip-license-screen (enter the original IP.BIN bootstrap at 0x8c00b800)\n'
        '         --direct-disc-entry (explicitly skip IP.BIN and enter 0x8c010000)\n'
        '         --second-bootstrap (run original IP.BIN bootstrap 2 at 0x8c00e000)\n'
        '         --watch-disc-entry (report a branch to 0x8c010000)\n'
        '         --watch-ram=HEX --stop-at=HEX --stop-on-low-ram-code\n'
        '         --stop-on-interrupt --trace-execution\n'
        '         --quiesce-bios-irqs (mask previous BIOS HOLLY interrupt sources)');
    exitCode = 64;
    return;
  }
  final limit = args.length >= 3 ? int.parse(args[2]) : 1000000;
  if (limit < 1) throw ArgumentError.value(limit, 'instructions');
  final core = Dc(bootBringUp: coreBringUp);
  final padState = PadState();
  core.input = padState;
  final pressedButtons = [
    for (final name in pressName?.split(',') ?? <String>[])
      core.buttons.firstWhere(
          (button) => button.name.toLowerCase() == name.trim().toLowerCase())
  ];
  core.bus.g1.bypassBiosVerification = bypassVerification;
  core.bus.aica.sound.diagnosticByteAddressAdpcm =
      byteAddressAdpcm || coreBringUp;
  core.bus.aica.sound.diagnosticFilterApproximation = approximateFilter;
  core.bus.gpio.drivenMask = core.bus.gpio.drivenValues = gpioHigh;
  final pcm = BytesBuilder(copy: false);
  var samples = 0, nonzeroSamples = 0, sampleRate = 44100, channels = 2;
  core.onAudio((buffer) {
    sampleRate = buffer.sampleRate;
    channels = buffer.channels;
    samples += buffer.buffer.length;
    for (final sample in buffer.buffer) {
      if (sample != 0) nonzeroSamples++;
      if (capture != null) {
        final value = (sample.clamp(-1.0, 1.0) * 32767).round();
        pcm.addByte(value & 255);
        pcm.addByte((value >> 8) & 255);
      }
    }
  });
  try {
    core.setBiosFiles([
      File(args[0]).readAsBytesSync(),
      File(args[1]).readAsBytesSync(),
    ]);
    _ProbeDrive? drive;
    if (args.length == 4) {
      drive = _ProbeDrive(trace: traceDisc);
      await drive.insert(localDisc(args[3]));
      if (!drive.status.isReady) {
        throw FormatException('Cannot read disc image', args[3]);
      }
      if (!attachAfterState) core.setCdromDrive(drive);
    }
    if (loadPath != null) {
      core.loadState(File(loadPath).readAsBytesSync());
      if (clearErrors) core.bus.systemBus.write(8, 4, 0xffffffff);
      core.stopReason = null; // Retry the previously unsupported guest access.
    }
    if (attachAfterState) {
      if (drive == null || loadPath == null) {
        throw ArgumentError(
            '--attach-disc-after-state requires a no-disc BIOS state and disc');
      }
      core.setCdromDrive(drive);
    }
    if (traceDisc) {
      core.bus.opticalDrive.onTrace = (phase, bytes) {
        stdout.writeln(jsonEncode({
          'opticalDrivePhase': phase,
          'bytes': [
            for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')
          ],
        }));
      };
    }
    core.bus.opticalDrive.diagnosticFormatOverride = driveFormat;
    core.bus.aica.dsp.diagnosticBypassProgram = bypassAicaDsp;
    core.bus.aica.dsp.diagnosticBypassUnsupportedProgram = fallbackAicaDsp;
    if (quiesceBiosIrqs && !bootDisc) {
      for (final group in [0x10, 0x20, 0x30]) {
        for (final source in [0, 4, 8]) {
          core.bus.systemBus.write(group + source, 4, 0);
        }
      }
    }
    Uint8List? expectedDiscPrefix;
    if (bootDisc) {
      if (drive == null || loadPath == null) {
        throw ArgumentError(
            'Diagnostic disc boot requires a BIOS state and disc');
      }
      final boot = await core.bootUnscrambledDisc(
          entry: secondBootstrap
              ? 0x8c00e000
              : directDiscEntry
                  ? 0x8c010000
                  : skipLicense
                      ? 0x8c00b800
                      : 0x8c008300);
      expectedDiscPrefix =
          boot.program.sublist(0, boot.program.length.clamp(2, 64) & ~1);
      stdout.writeln(jsonEncode({
        'diagnosticBootstrap': secondBootstrap
            ? 'unscrambled ISO program through original IP.BIN bootstrap 2'
            : directDiscEntry
                ? 'unscrambled ISO program; IP.BIN execution skipped'
                : skipLicense
                    ? 'unscrambled ISO program through IP.BIN bootstrap; license stage skipped'
                    : 'unscrambled ISO program through IP.BIN entry',
        'bootAreaPresent': boot.bootAreaPresent,
        'bootProgram': boot.name,
        'bootProgramBytes': boot.program.length,
        'bootProgramLba': boot.programLba,
        'hostLoadedSectors': drive.requested.length,
      }));
      drive.requested.clear();
    } else if (watchDiscEntry && drive != null) {
      final boot = await loadDcBootstrap(drive, waitForSector: drive.settle);
      expectedDiscPrefix =
          boot.program.sublist(0, boot.program.length.clamp(2, 64) & ~1);
      stdout.writeln(jsonEncode({
        'discEntryReferenceBytes': expectedDiscPrefix.length,
        'hostLoadedSectors': drive.requested.length,
      }));
      drive.requested.clear();
    }
    final recent = <String>[];
    final traceCache = <int, (int, int, String)>{};
    var executed = 0;
    final watchedMemory = ByteData.sublistView(core.bus.ram);
    final driveCalls = <(int, int, int, int)>[];
    var watchedValue =
        watchRam == null ? 0 : watchedMemory.getUint32(watchRam, Endian.little);
    var enteredDiscProgram = false;
    var discEntryAddressReached = false;
    Object? previousTaConfiguration;
    final watch = Stopwatch()..start();
    for (; executed < limit; executed++) {
      final buttonIndex = executed ~/ 2000000;
      if (buttonIndex < pressedButtons.length) {
        if (executed % 2000000 == 0) {
          padState.press(0, pressedButtons[buttonIndex]);
        } else if (executed % 2000000 == 1000000) {
          padState.release(0, pressedButtons[buttonIndex]);
        }
      }
      if (gpioLink != 0) {
        final gpio = core.bus.gpio;
        final control = gpio.read(0x2c, 4), data = gpio.read(0x30, 2);
        var driven = false, high = true, pullup = false;
        for (var pin = 0; pin < 16; pin++) {
          if (gpioLink & (1 << pin) == 0) continue;
          if (control & (1 << (pin * 2)) != 0) {
            driven = true;
            if (data & (1 << pin) == 0) high = false;
          } else if (control & (2 << (pin * 2)) == 0) {
            pullup = true;
          }
        }
        gpio.drivenMask = gpioHigh | gpioLink;
        gpio.drivenValues =
            (gpioHigh & ~gpioLink) | ((driven ? high : pullup) ? gpioLink : 0);
      }
      final pc = core.programCounter(0);
      if (traceDisc) {
        if (driveCalls.isNotEmpty &&
            pc == driveCalls.last.$4 &&
            !core.cpu.inDelaySlot) {
          final call = driveCalls.removeLast();
          if (call.$1 != 2) {
            final pointer = call.$3 & 0x1fffffff;
            stdout.writeln(jsonEncode({
              'driveSyscallReturn': call.$1,
              'argument': call.$2,
              'result': core.cpu.r[0].toRadixString(16),
              if (call.$1 == 1 &&
                  pointer >= 0x0c000000 &&
                  pointer <= 0x0cfffff0)
                'completion': [
                  for (var i = 0; i < 16; i += 4)
                    core.bus.read32(call.$3 + i, peek: true)
                ],
            }));
          }
        }
        final vector = core.bus.read32(0x8c0000bc, peek: true);
        if ((pc & 0x1fffffff) == (vector & 0x1fffffff) &&
            core.cpu.r[6] == 0 &&
            core.cpu.r[7] < 16) {
          final function = core.cpu.r[7];
          driveCalls.add((function, core.cpu.r[4], core.cpu.r[5], core.cpu.pr));
          if (function != 2) {
            stdout.writeln(jsonEncode({
              'driveSyscall': function,
              'argument': core.cpu.r[4],
              'buffer': core.cpu.r[5]
            }));
          }
        }
      }
      if (pc == stopAt) break;
      if (stopOnLowRamCode &&
          pc < 0xc0000000 &&
          (pc & 0x1fffffff) >= 0x0c000000 &&
          (pc & 0x1fffffff) < 0x0c001000) {
        stdout
            .writeln(jsonEncode({'stoppedOnLowRamCode': pc.toRadixString(16)}));
        break;
      }
      if (watchDiscEntry &&
          !enteredDiscProgram &&
          (pc & 0x1fffffff) == 0x0c010000) {
        final prefix = expectedDiscPrefix;
        var matches = prefix != null;
        if (prefix != null) {
          for (var i = 0; i < prefix.length; i += 2) {
            if (core.bus.peekInstruction16(pc + i,
                    privileged: core.cpu.privileged) !=
                (prefix[i] | (prefix[i + 1] << 8))) {
              matches = false;
              break;
            }
          }
        }
        if (!discEntryAddressReached || matches) {
          stdout.writeln(jsonEncode({
            matches ? 'enteredDiscProgramAt' : 'discEntryAddressAt': executed,
            'discEntryPrefixMatches': matches,
            'discEntryOpcode': core.bus
                .peekInstruction16(pc, privileged: core.cpu.privileged)
                .toRadixString(16),
          }));
        }
        discEntryAddressReached = true;
        enteredDiscProgram = matches;
      }
      final opcode =
          core.bus.peekInstruction16(pc, privileged: core.cpu.privileged);
      final cached = traceCache[pc];
      final line =
          cached != null && cached.$1 == opcode && cached.$2 == core.cpu.fpscr
              ? cached.$3
              : core.disasm(0, pc).$1;
      if (cached == null ||
          cached.$1 != opcode ||
          cached.$2 != core.cpu.fpscr) {
        traceCache[pc] = (opcode, core.cpu.fpscr, line);
      }
      recent.add(line);
      if (traceExecution) stdout.writeln(line);
      if (recent.length > 16) recent.removeAt(0);
      final result = core.exec(false);
      if (result.stopped) break;
      if (clockScale > 1) {
        try {
          core.bus.tickMasterClocks(result.elapsedClocks * (clockScale - 1));
        } on DcUnsupported catch (error) {
          core.stopReason = error.toString();
          break;
        }
      }
      if (stopOnSleep && core.cpu.sleeping) break;
      if (stopOnInterrupt &&
          !core.cpu.instructionExecuted &&
          core.cpu.pc == core.cpu.vbr + 0x600) {
        break;
      }
      if (watchRam != null) {
        final value = watchedMemory.getUint32(watchRam, Endian.little);
        if (value != watchedValue) {
          stdout.writeln(jsonEncode({
            'ramChangedAt': executed,
            'ramOffset': watchRam.toRadixString(16),
            'old': watchedValue.toRadixString(16),
            'value': value.toRadixString(16),
            'pc': pc.toRadixString(16),
            'ccr': core.bus.cache.ccr.toRadixString(16),
            'registers': [
              for (final value in core.cpu.r) value.toRadixString(16)
            ],
            'recent': recent,
          }));
          watchedValue = value;
        }
      }
      if (traceTa) {
        final ta = core.bus.gpu.ta;
        final configuration =
            (ta.objectBase, ta.parameterBase, ta.globalClip, ta.allocation);
        if (configuration != previousTaConfiguration) {
          previousTaConfiguration = configuration;
          stdout.writeln(jsonEncode({
            'taConfigurationAt': executed,
            'pc': pc.toRadixString(16),
            'objectBase': ta.objectBase,
            'parameterBase': ta.parameterBase,
            'clip': ta.globalClip,
            'allocation': ta.allocation,
            'currentParameter': ta.currentParameter,
          }));
        }
      }
      if (drive?.hasPendingReads ?? false) await drive!.settle();
      if (executed != 0 && executed % 10000000 == 0) {
        final frame = core.imageBuffer();
        stdout.writeln(jsonEncode({
          'progressInstructions': executed,
          'pc': core.cpu.pc.toRadixString(16),
          'sleeping': core.cpu.sleeping,
          'imageWidth': frame.width,
          'imageHeight': frame.height,
          'nonzeroAudioSamples': nonzeroSamples,
        }));
        if (capture != null && frame.width > 0) {
          Directory(capture).createSync(recursive: true);
          savePng(frame, '$capture/frame.png');
          savePng(frame, '$capture/frame-$executed.png');
        }
      }
    }
    for (final button in pressedButtons) {
      padState.release(0, button);
    }
    stdout.writeln(jsonEncode({
      'instructions': executed,
      'clocks': core.cpuClocks,
      'elapsedMs': watch.elapsedMilliseconds,
      'pc': core.programCounter(0).toRadixString(16),
      'stop': core.stopReason,
      'limitReached': executed >= limit,
      'biosVerificationBypassed': bypassVerification,
      'aicaDspBypassed': bypassAicaDsp || core.bus.aica.dsp.programBypassed,
      'aicaDspFallbackEnabled': fallbackAicaDsp,
      'aicaDspUnsupportedReason': core.bus.aica.dsp.programUnsupportedReason,
      'coreBootBringUp': coreBringUp,
      'byteAddressAdpcm': byteAddressAdpcm || coreBringUp,
      'aicaFilterApproximated': approximateFilter,
      'aicaArmInstructions': core.bus.aica.executedInstructions,
      'aicaArmReset': core.bus.aica.armReset,
      'aicaSoundActive': core.bus.aica.sound.active,
      'aicaMasterControl': core.bus.aica.sound.control,
      'aicaDspHasProgram': core.bus.aica.dsp.hasProgram,
      'diagnosticDriveFormat': driveFormat,
      'diagnosticDiscBootstrap': bootDisc,
      'skippedLicenseScreen': skipLicense,
      'directDiscEntry': directDiscEntry,
      'secondBootstrap': secondBootstrap,
      'quiescedBiosIrqs': quiesceBiosIrqs,
      'enteredDiscProgram': enteredDiscProgram,
      'discEntryAddressReached': discEntryAddressReached,
      'gpioDrivenHigh': gpioHigh,
      'gpioLinkedPins': gpioLink,
      'peripheralClockScale': clockScale,
      'resumedFromState': loadPath,
      'clearedErrorStatus': clearErrors,
      'imageWidth': core.imageBuffer().width,
      'imageHeight': core.imageBuffer().height,
      'audioSamples': samples,
      'nonzeroAudioSamples': nonzeroSamples,
      'sleeping': core.cpu.sleeping,
      'tmuStart': core.bus.tmu.read(4, 1),
      'tmuControl0': core.bus.tmu.read(16, 2),
      'tmuCounter0': core.bus.tmu.read(12, 4),
      'ipra': core.bus.intc.read(4),
      'videoRunning': core.bus.gpu.spg.running,
      'videoOutputControl': core.bus.gpu.read(0xe8, 4),
      'framebufferReadControl': core.bus.gpu.read(0x44, 4),
      'framebufferReadStart': core.bus.gpu.read(0x50, 4),
      'opticalDriveStatus': core.bus.opticalDrive.status,
      'globalTileClip': core.bus.gpu.ta.globalClip,
      if (drive != null) 'discSectors': drive.status.toc.totalSectors,
      if (drive != null) 'discTracks': drive.status.toc.trackCount,
      if (drive != null) 'discRequestedSectors': drive.requested.length,
      if (drive != null && drive.requested.isNotEmpty)
        'discLastRequestedLba': drive.requested.last,
      if (pressedButtons.isNotEmpty)
        'pressedButtons': [for (final button in pressedButtons) button.name],
      'recent': recent,
    }));
    if (savePath != null) {
      final temporary = File('$savePath.tmp');
      temporary.writeAsBytesSync(core.saveState());
      if (File(savePath).existsSync()) {
        File(savePath).copySync('$savePath.previous');
      }
      temporary.renameSync(savePath);
    }
    if (capture != null) {
      Directory(capture).createSync(recursive: true);
      savePng(core.imageBuffer(), '$capture/frame.png');
      savePng(core.bus.gpu.image(), '$capture/framebuffer.png');
      if (pcm.length > 0) {
        File('$capture/audio.wav')
            .writeAsBytesSync(wavBytes(pcm.takeBytes(), sampleRate, channels));
      }
    }
    stdout.writeln(core.dump());
    if (stopOnSleep) {
      for (var address = 0x8c000000; address < 0x8c000020; address += 2) {
        stdout.writeln(core.disasm(0, address).$1);
      }
    }
    if (core.stopReason != null) exitCode = 2;
  } finally {
    core.dispose();
  }
}

class _ProbeDrive extends SimpleCdromDrive {
  _ProbeDrive({required this.trace});
  final bool trace;
  final requested = <int>{};

  @override
  Uint8List? read(int lba) {
    if (requested.add(lba) && trace) {
      stdout.writeln(jsonEncode({'discReadLba': lba}));
    }
    return super.read(lba);
  }
}

import 'dart:collection';
import 'dart:typed_data';

import '../../cdrom_drive.dart';
import '../../state.dart';
import 'fault.dart';
import 'optical_audio.dart';

// signature bytes, as character codes
const dcDriveVendor = '\x53\x45';

/// Functional SPI PIO/DMA device, from SPI Specifications Rev. 1.31 and System Architecture.
/// Command phase delays are nominal scheduling placeholders, not drive timing.
class DcOpticalDrive {
  DcOpticalDrive({required this.onInterrupt, this.bypassBootChecks}) {
    reset();
  }
  final void Function(bool) onInterrupt;
  final bool Function()? bypassBootChecks;
  // Explicit probe-only assumption; not a classification of the attached media.
  int? diagnosticFormatOverride;
  void Function(String phase, List<int> bytes)? onTrace;
  CdromDrive _drive = EmptyCdromDrive();
  final audio = DcOpticalAudio();

  final _pendingDriveEvents = Queue<CdromDriveEvent>();
  bool _driveBound = false, _savedSeeking = false, _savedSeekError = false;
  bool _restoredAudioFailure = false;
  int _savedDriveId = 0, _restoredSeekResult = -1;
  CdromDriveStatus get driveStatus => _drive.status;

  void _captureDriveEvents() {
    if (!_driveBound) return;
    final media = _drive.status;
    _savedDriveId = media.discId;
    _savedSeeking = media.isSeeking;
    _savedSeekError = media.seekError;
    while (true) {
      final event = _drive.takeEvent();
      if (event == null) break;
      _pendingDriveEvents.add(event);
    }
  }

  bool get hasSubcodeProvider => _drive is CdromSubcodeDrive;

  void validateDriveAfterLoad(CdromDriveStatus media) {
    final current = _discId == _savedDriveId && _mediaState == media.state;
    final changing = _pendingDriveEvents.any((event) =>
        event.type == CdromDriveEventType.trayOpened ||
        event.type == CdromDriveEventType.trayClosed ||
        event.discId == _savedDriveId);
    if (_seekTarget >= 0 &&
        current &&
        !changing &&
        _savedSeeking &&
        _restoredSeekResult < 0 &&
        _seekTarget >= media.toc.totalSectors) {
      throw const StateMismatch(
          'Optical drive pending seek exceeds attached media');
    }
  }

  /// Called only after the owning core validates the attached media identity.
  /// Host mount generations differ between otherwise identical core instances.
  void rebindDriveAfterLoad() {
    final media = _drive.status, previous = _savedDriveId;
    validateDriveAfterLoad(media);
    final current = _discId == previous && _mediaState == media.state;
    final invalidating = _pendingDriveEvents.any((event) =>
        event.type == CdromDriveEventType.trayOpened ||
        event.type == CdromDriveEventType.trayClosed ||
        event.discId == previous);
    _discId = _discId == previous ? media.discId : media.discId ^ 1;
    final events = [
      for (final event in _pendingDriveEvents)
        CdromDriveEvent(event.type,
            event.discId == previous ? media.discId : media.discId ^ 1)
    ];
    _pendingDriveEvents
      ..clear()
      ..addAll(events);
    _savedDriveId = media.discId;
    if (current &&
        !invalidating &&
        audio.playing &&
        !_savedSeeking &&
        _savedSeekError) {
      _restoredAudioFailure = true;
    }
    _drive.clearEvents();
    if (_seekTarget >= 0 &&
        current &&
        !invalidating &&
        _restoredSeekResult < 0) {
      if (_savedSeeking) {
        _drive.seek(_seekTarget);
      } else {
        _restoredSeekResult = _savedSeekError ? 1 : 0;
      }
    }
  }

  (int, int) sampleAudio() {
    if (_restoredAudioFailure) {
      _restoredAudioFailure = false;
      if (audio.playing) {
        audio.fail();
        return (0, 0);
      }
    }
    final media = _drive.status;
    final advancing =
        audio.playing && media.isReady && !media.isSeeking && !media.seekError;
    final result = audio.sample(_drive);
    if (advancing) _fad = audio.fad;
    return result;
  }

  final _packet = Uint8List(12), _sense = Uint8List(10), _mode = Uint8List(32);
  Uint8List _buffer = Uint8List(0);
  int _status = 0, _error = 1, _features = 0, _reason = 1, _sectorCount = 1;
  int _byteCount = 0xeb14, _select = 0, _control = 0, _limit = 0;
  int _position = 0, _phaseEnd = 0, _packetPosition = -1, _modeStart = -1;
  int _remaining = 0, _action = 0, _ata = 0, _fad = 150, _readCount = 0;
  int _readFlags = 0, _discId = 0, _readFad = 150, _attentionAsc = 0x29;
  int _seekTarget = -1, _nextReadFad = -1;
  int _subcodeFormat = -1, _subcodeFad = 150;
  int pioTransferMode = 0, dmaTransferMode = 0;
  bool _dmaRequested = false, _dmaActive = false;
  bool _standby = false, _seekHome = false, _reading = false;
  int _pauseClocks = 0;
  static const masterHz = 200000000;

  /// Invalidates G1 staging when reset, media or failed commands replace a stream.
  int dmaEpoch = 0;
  bool get dmaActive => _dmaActive;
  int get dmaAvailable => _dmaActive && _status & 8 != 0 && _reason == 2
      ? _buffer.length - _position
      : 0;

  /// Consumes exactly count bytes when the DMA stream has enough ready data.
  Uint8List? takeDmaBytes(int count) {
    _mediaEvents();
    if (count < 1 || count > dmaAvailable) return null;
    final result =
        Uint8List.fromList(_buffer.sublist(_position, _position + count));
    _position += count;
    if (_position == _buffer.length) {
      if (_readCount != 0) {
        _schedule(4);
      } else {
        _finish();
      }
    }
    return result;
  }

  bool _signature = true, _seekComplete = false;
  CdromDriveState _mediaState = CdromDriveState.empty;
  bool _irq = false, _waitingSector = false, _unitAttention = true;
  // The completed packet plus an unscheduled busy phase encodes manual opening.
  // These fields already participate in save/load; no host request is retained.
  bool get _opening =>
      _ata == 0xa0 &&
      _packet[0] == 0x16 &&
      _packetPosition == -1 &&
      _status == 0x80 &&
      _action == 0 &&
      _remaining == 0;
  bool get _paused =>
      _mediaState == CdromDriveState.ready &&
      !_opening &&
      !_standby &&
      !audio.playing &&
      _seekTarget < 0 &&
      _action != 5 &&
      !_reading &&
      _subcodeFormat < 0;
  int get _standbyPeriod => ((_mode[4] << 8) | _mode[5]) * masterHz;
  int get clocksToEvent {
    if (!_paused || _standbyPeriod == 0) return _remaining;
    final left = _standbyPeriod - _pauseClocks;
    final deadline = left > 0 ? left : 1;
    return _remaining == 0 || deadline < _remaining ? deadline : _remaining;
  }

  void _tickPause(int clocks) {
    if (!_paused || _standbyPeriod == 0) {
      _pauseClocks = 0;
      return;
    }
    _pauseClocks += clocks;
    if (_pauseClocks < _standbyPeriod) return;
    _pauseClocks = 0;
    _standby = true;
    _fad = 150;
    audio.reset();
  }

  int get status => _status;
  bool get interrupt => _irq && _control & 2 == 0;

  void saveState(StateWriter writer) {
    _captureDriveEvents();
    writer.section('dc.opticalDrive');
    for (final bytes in [_packet, _sense, _mode, _buffer]) {
      writer.bytes(bytes);
    }
    writer.ints([
      _status,
      _error,
      _features,
      _reason,
      _sectorCount,
      _byteCount,
      _select,
      _control,
      _limit,
      _position,
      _phaseEnd,
      _packetPosition,
      _modeStart,
      _remaining,
      _action,
      _ata,
      _fad,
      _readCount,
      _readFlags,
      _discId,
      _readFad,
      _attentionAsc,
      _seekTarget,
      _nextReadFad,
      _subcodeFormat,
      _subcodeFad,
      pioTransferMode,
      dmaTransferMode,
      _pauseClocks,
      dmaEpoch,
      _mediaState.index
    ]);
    for (final flag in [
      _dmaRequested,
      _dmaActive,
      _standby,
      _seekHome,
      _reading,
      _signature,
      _seekComplete,
      _irq,
      _waitingSector,
      _unitAttention
    ]) {
      writer.boolean(flag);
    }
    writer.section('dc.opticalDrive.drive-observation');
    writer.ints([_savedDriveId, _restoredSeekResult]);
    writer.boolean(_savedSeeking);
    writer.boolean(_savedSeekError);
    writer.boolean(_restoredAudioFailure);
    writer.int32(_pendingDriveEvents.length);
    for (final event in _pendingDriveEvents) {
      writer.ints([event.type.index, event.discId]);
    }
    audio.saveState(writer);
  }

  /// The owning machine restores media identity and external drive state.
  /// Loading does not poll host events, seek, read sectors or acknowledge IRQs.
  void loadState(StateReader reader) {
    reader.section('dc.opticalDrive');
    final packet = reader.bytes(), sense = reader.bytes();
    final mode = reader.bytes(), buffer = reader.bytes();
    final v = reader.ints();
    final flags = [for (var i = 0; i < 10; i++) reader.boolean()];
    reader.section('dc.opticalDrive.drive-observation');
    final observation = reader.ints();
    final seeking = reader.boolean(), seekError = reader.boolean();
    final audioFailure = reader.boolean();
    final eventCount = reader.int32(), events = <CdromDriveEvent>[];
    if (observation.length != 2 ||
        observation[0] < 0 ||
        observation[1] < -1 ||
        observation[1] > 1 ||
        eventCount < 0) {
      throw const StateMismatch('Optical drive observation state');
    }
    for (var i = 0; i < eventCount; i++) {
      final event = reader.ints();
      if (event.length != 2 ||
          event[0] < 0 ||
          event[0] >= CdromDriveEventType.values.length ||
          event[1] < 0) {
        throw const StateMismatch('Optical drive pending drive event');
      }
      events
          .add(CdromDriveEvent(CdromDriveEventType.values[event[0]], event[1]));
    }
    final restoredAudio = DcOpticalAudio()..loadState(reader);
    if (packet.length != 12 ||
        sense.length != 10 ||
        mode.length != 32 ||
        v.length != 31) {
      throw const StateMismatch('Optical drive component layout');
    }
    for (final i in [0, 1, 2, 3, 4, 6, 15, 18, 21, 26, 27]) {
      if (v[i] < 0 || v[i] > 255) {
        throw const StateMismatch('Optical drive task register state');
      }
    }
    if (v[5] < 0 ||
        v[5] > 0xffff ||
        v[7] & ~2 != 0 ||
        v[8] < 0 ||
        v[8] > 0xffff ||
        v[9] < 0 ||
        v[9] > buffer.length ||
        v[10] < 0 ||
        (v[0] & 8 != 0 &&
            v[11] < 0 &&
            (v[10] > buffer.length || v[9] > v[10])) ||
        v[11] < -1 ||
        v[11] > 10 ||
        (v[11] >= 0 && v[11].isOdd) ||
        v[12] < -1 ||
        v[12] > 10 ||
        (v[12] >= 0 && (v[12].isOdd || v[12] + buffer.length > 10)) ||
        v[13] < 0 ||
        v[13] > 80 ||
        v[14] < 0 ||
        v[14] > 5 ||
        v[16] < 0 ||
        v[17] < 0 ||
        v[17] > 0xffffff ||
        v[19] < 0 ||
        v[20] < 0 ||
        v[22] < -1 ||
        v[23] < -1 ||
        ![-1, 0, 1, 2, 3].contains(v[24]) ||
        v[25] < 0 ||
        v[28] < 0 ||
        v[29] < 0 ||
        v[30] < 0 ||
        v[30] >= CdromDriveState.values.length) {
      throw const StateMismatch('Optical drive command state');
    }
    // Audio has already been validated in isolation; retain its object identity.
    final audioWriter = StateWriter('dc.drive.transfer', 1, 0);
    restoredAudio.saveState(audioWriter);
    final audioReader =
        StateReader(audioWriter.take(), 'dc.drive.transfer', 1, 0);
    audio.loadState(audioReader);
    audioReader.end();
    _packet.setAll(0, packet);
    _sense.setAll(0, sense);
    _mode.setAll(0, mode);
    _driveIdentity();
    _buffer = buffer;
    _status = v[0];
    _error = v[1];
    _features = v[2];
    _reason = v[3];
    _sectorCount = v[4];
    _byteCount = v[5];
    _select = v[6];
    _control = v[7];
    _limit = v[8];
    _position = v[9];
    _phaseEnd = v[10];
    _packetPosition = v[11];
    _modeStart = v[12];
    _remaining = v[13];
    _action = v[14];
    _ata = v[15];
    _fad = v[16];
    _readCount = v[17];
    _readFlags = v[18];
    _discId = v[19];
    _readFad = v[20];
    _attentionAsc = v[21];
    _seekTarget = v[22];
    _nextReadFad = v[23];
    _subcodeFormat = v[24];
    _subcodeFad = v[25];
    pioTransferMode = v[26];
    dmaTransferMode = v[27];
    _pauseClocks = v[28];
    dmaEpoch = v[29];
    _mediaState = CdromDriveState.values[v[30]];
    _dmaRequested = flags[0];
    _dmaActive = flags[1];
    _standby = flags[2];
    _seekHome = flags[3];
    _reading = flags[4];
    _signature = flags[5];
    _seekComplete = flags[6];
    _irq = flags[7];
    _waitingSector = flags[8];
    _unitAttention = flags[9];
    _savedDriveId = observation[0];
    _restoredSeekResult = observation[1];
    _savedSeeking = seeking;
    _savedSeekError = seekError;
    _restoredAudioFailure = audioFailure;
    _pendingDriveEvents
      ..clear()
      ..addAll(events);
  }

  void attach(CdromDrive drive) {
    _drive = drive;
    _driveBound = true;
    reset();
  }

  void _signal(bool value) {
    _irq = value;
    onInterrupt(interrupt);
  }

  void reset() {
    audio.reset();
    _standby = _seekHome = _reading = false;
    _pauseClocks = 0;
    dmaEpoch++;
    _dmaActive = _dmaRequested = false;
    _drive.clearEvents();
    _pendingDriveEvents.clear();
    _restoredAudioFailure = false;
    _restoredSeekResult = -1;
    final media = _drive.status;
    _savedDriveId = media.discId;
    _savedSeeking = media.isSeeking;
    _savedSeekError = media.seekError;
    _discId = media.discId;
    _mediaState = media.state;
    _status = 0;
    _error = 1;
    _features = _select = _control = 0;
    pioTransferMode = dmaTransferMode = 0;
    _signature = true;
    _seekComplete = false;
    _reason = _sectorCount = 1;
    _byteCount = 0xeb14;
    _remaining = _action = _readCount = _position = _phaseEnd = 0;
    _packetPosition = _modeStart = -1;
    _buffer = Uint8List(0);
    _subcodeFormat = -1;
    _waitingSector = false;
    _unitAttention = true;
    _fad = _readFad = 150;
    _seekTarget = _nextReadFad = -1;
    _mode.fillRange(0, 32, 0);
    _mode[5] = 0xb4;
    _mode[6] = 0x19;
    _mode[9] = 8;
    _driveIdentity();
    _sense.fillRange(0, 10, 0);
    _sense[0] = 0xf0;
    _sense[2] = 6;
    _attentionAsc = media.isReady ? 0x28 : 0x29;
    _sense[8] = _attentionAsc;
    _signal(false);
  }

  void _driveIdentity() {
    // Read-only 6.43 identity profile from an independent drive-information tool's hardware output.
    // The version describes this compatibility profile, not executed drive firmware.
    _mode.fillRange(10, 32, 32);
    _mode.setAll(10, dcDriveVendor.codeUnits);
    _mode.setAll(18, 'Rev 6.43'.codeUnits);
    _mode.setAll(26, '990408'.codeUnits);
  }

  int get _driveStatus => _opening
      ? 0
      : switch (_mediaState) {
          CdromDriveState.ready => _seekTarget >= 0
              ? 4
              : _standby
                  ? 2
                  : audio.scanning
                      ? 5
                      : audio.playing
                          ? 3
                          : 1,
          CdromDriveState.trayOpen => 6,
          CdromDriveState.empty => 7,
          CdromDriveState.loading => 0,
          CdromDriveState.error => 9,
        };
  int get _format => _opening
      ? 0
      : diagnosticFormatOverride ??
          (_drive.status.toc.tracks.any((t) => !t.isAudio)
              ? (_drive.status.toc.isXa == true ? 0x20 : 0x10)
              : 0);

  void _schedule(int action) {
    _action = action;
    _remaining =
        80; // Functional 400 ns phase interval on the nominal master clock.
    _status = 0x80;
  }

  void _finish(
      {int key = 0, int asc = 0, int qualifier = 0, bool abort = false}) {
    if (key != 0 || abort) dmaEpoch++;
    _dmaActive = _dmaRequested = false;
    _restoredSeekResult = -1;
    _remaining = _action = _readCount = 0;
    _reading = false;
    _subcodeFormat = -1;
    _waitingSector = false;
    _seekTarget = _nextReadFad = -1;
    _seekHome = false;
    _packetPosition = _modeStart = -1;
    _status = (key == 0 && !abort ? 0x40 : 0x41) | (_seekComplete ? 0x10 : 0);
    _reason = 3;
    _byteCount = 0;
    _error = (key << 4) | (abort ? 4 : 0);
    if (key != 0) {
      _sense.fillRange(0, 10, 0);
      _sense[0] = 0xf0;
      _sense[2] = key;
      _sense[5] = (_fad >> 16) & 255;
      _sense[6] = (_fad >> 8) & 255;
      _sense[7] = _fad & 255;
      _sense[8] = asc;
      _sense[9] = qualifier;
    }
    _signal(true);
  }

  bool _ready() {
    if (_unitAttention) {
      _unitAttention = false;
      _finish(key: 6, asc: _attentionAsc);
      return false;
    }
    if (_mediaState == CdromDriveState.ready) return true;
    _finish(
        key: 2,
        asc: _mediaState == CdromDriveState.error
            ? 0x57
            : _mediaState == CdromDriveState.loading
                ? 4
                : 0x3a,
        qualifier: _mediaState == CdromDriveState.loading ? 1 : 0);
    return false;
  }

  void _mediaEvents() {
    final media = _drive.status;
    var changed = media.discId != _discId || media.state != _mediaState;
    while (true) {
      final event = _pendingDriveEvents.isNotEmpty
          ? _pendingDriveEvents.removeFirst()
          : _drive.takeEvent();
      if (event == null) break;
      if (event.type == CdromDriveEventType.trayOpened ||
          event.type == CdromDriveEventType.trayClosed ||
          event.discId == media.discId) {
        changed = true;
      }
    }
    if (!changed) return;
    final opened = _opening && media.isTrayOpen;
    _restoredAudioFailure = false;
    _standby = _seekHome = false;
    _pauseClocks = 0;
    audio.reset();
    _discId = media.discId;
    _mediaState = media.state;
    _unitAttention = true;
    _attentionAsc = 0x28;
    _seekComplete = false;
    _fad = 150;
    _finish(key: opened ? 0 : 6, asc: 0x28);
  }

  /// Samples asynchronous host state at the current emulated time.
  void prepare() {
    _mediaEvents();
    _pollSeek();
    if (_waitingSector) _loadSector();
    if (_subcodeFormat >= 0) _loadSubcode();
  }

  void _pollSeek() {
    if (_seekTarget < 0) return;
    final media = _drive.status;
    if (_restoredSeekResult < 0 && media.isSeeking) return;
    final error =
        _restoredSeekResult < 0 ? media.seekError : _restoredSeekResult == 1;
    _restoredSeekResult = -1;
    if (error) {
      if (audio.playing) {
        audio.fail();
      } else {
        audio.reset();
      }
      _finish(key: 4, asc: 0x15);
      return;
    }
    _fad = _seekTarget + 150;
    _standby = _seekHome;
    _seekComplete = true;
    _finish();
  }

  void _beginSeek(int lba, {bool home = false}) {
    _restoredAudioFailure = false;
    _restoredSeekResult = -1;
    _pauseClocks = 0;
    _standby = false;
    _seekHome = home;
    _seekTarget = lba;
    _seekComplete = false;
    _status = 0x80;
    _drive.seek(lba);
    _pollSeek();
  }

  void tickMasterClocks(int clocks, {bool prepared = false}) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    if (clocks == 0) return;
    if (!prepared) prepare();
    if (_waitingSector) {
      _pauseClocks = 0;
      return;
    }
    while (_remaining != 0 && clocks >= _remaining) {
      _tickPause(_remaining);
      clocks -= _remaining;
      final action = _action;
      _remaining = _action = 0;
      switch (action) {
        case 1:
          _executeAta();
        case 2:
          _executePacket();
        case 3:
          _dataPhase();
        case 4:
          _loadSector();
        case 5:
          _status = 0;
      }
    }
    _tickPause(clocks);
    if (_remaining != 0) _remaining -= clocks;
  }

  int read(int offset, int size, {bool sideEffects = true}) {
    if (sideEffects) {
      _mediaEvents();
      _pollSeek();
    }
    if (offset == 0x80) {
      if (size != 2) {
        throw const DcUnsupported('Optical drive data requires word access');
      }
      if (_dmaActive || _status & 8 == 0 || _reason != 2) {
        throw const DcUnsupported(
            'Optical drive data read outside PIO input phase');
      }
      final low = _buffer[_position];
      final high = _position + 1 < _phaseEnd ? _buffer[_position + 1] : 0;
      if (sideEffects) {
        _position += _phaseEnd - _position >= 2 ? 2 : 1;
        if (_position == _phaseEnd) {
          if (_position < _buffer.length) {
            _schedule(3);
          } else if (_readCount != 0) {
            _schedule(4);
          } else {
            _finish();
          }
        }
      }
      return low | (high << 8);
    }
    if (size != 1) {
      throw const DcUnsupported('Optical drive task file requires byte access');
    }
    if (offset == 0x18 || offset == 0x9c) {
      final result = _status;
      if (offset == 0x9c && sideEffects) _signal(false);
      return result;
    }
    return switch (offset) {
      0x84 => _error,
      0x88 => _reason,
      0x8c => _signature ? 1 : _format | _driveStatus,
      0x90 => _byteCount & 255,
      0x94 => _byteCount >> 8,
      0x98 => _select,
      _ => throw DcUnsupported(
          'unimplemented optical drive register read: $offset'),
    };
  }

  void write(int offset, int size, int value) {
    _mediaEvents();
    if (offset == 0x80) {
      if (size != 2) {
        throw const DcUnsupported('Optical drive data requires word access');
      }
      if (_status & 8 == 0) {
        throw const DcUnsupported('Optical drive data write without DRQ');
      }
      if (_packetPosition >= 0) {
        _packet[_packetPosition++] = value & 255;
        _packet[_packetPosition++] = (value >> 8) & 255;
        if (_packetPosition == 12) {
          _packetPosition = -1;
          _schedule(2);
        }
      } else if (_modeStart >= 0) {
        _buffer[_position++] = value & 255;
        if (_position < _phaseEnd) _buffer[_position++] = (value >> 8) & 255;
        if (_position == _phaseEnd) {
          if (_position < _buffer.length) {
            _schedule(3);
          } else {
            _setMode();
          }
        }
      } else {
        throw const DcUnsupported(
            'Optical drive data write outside PIO output phase');
      }
      return;
    }
    if (size != 1) {
      throw const DcUnsupported('Optical drive task file requires byte access');
    }
    value &= 255;
    if (offset == 0x18) {
      if (value & 4 != 0)
        throw const DcUnsupported('Optical drive ATA SRST protocol');
      _control = value & 2;
      onInterrupt(interrupt);
      return;
    }
    if (offset == 0x9c) {
      if (value == 8) {
        final select = _select, pio = pioTransferMode, dma = dmaTransferMode;
        reset();
        _select = select;
        pioTransferMode = pio;
        dmaTransferMode = dma;
        _sense[8] = _attentionAsc = 0x29;
        _schedule(5);
        return;
      }
      if (value == 0) {
        _finish(abort: true);
        return;
      }
      if (_status & 0x88 != 0 || _waitingSector) {
        _finish(key: 4, asc: 0x4e);
        return;
      }
      _signature = false;
      _ata = value;
      _signal(false);
      _schedule(1);
      return;
    }
    if (_status & 0x88 != 0) {
      throw const DcUnsupported('Optical drive task file write while busy');
    }
    switch (offset) {
      case 0x84:
        _features = value;
      case 0x88:
        _sectorCount = value;
      case 0x8c:
        return; // Sector Number is device status in SPI, not an address.
      case 0x90:
        _byteCount = (_byteCount & 0xff00) | value;
      case 0x94:
        _byteCount = (_byteCount & 255) | (value << 8);
      case 0x98:
        _select = value;
      default:
        throw DcUnsupported(
            'unimplemented optical drive register write: $offset');
    }
  }

  void _executeAta() {
    onTrace?.call('ata', [_ata]);
    switch (_ata) {
      case 0xa0:
        dmaEpoch++;
        _dmaRequested = _features & 1 != 0;
        _limit = _byteCount;
        _packetPosition = 0;
        _reason = 1;
        _status = 0x48 | (_seekComplete ? 0x10 : 0);
      case 0x90:
        _finish();
      case 0xef:
        if (_features & 0x7f != 3) {
          _finish(abort: true);
          return;
        }
        final kind = _sectorCount >> 3;
        if (kind != 0 && kind != 1 && kind != 2 && kind != 4) {
          _finish(abort: true);
          return;
        }
        if (kind < 2) {
          pioTransferMode = _sectorCount;
        } else {
          dmaTransferMode = _sectorCount;
        }
        _finish(); // Bus-cycle timing is not modeled.
      case 0xa1:
        final identify = Uint8List(80)..fillRange(0x10, 0x40, 32);
        identify.setAll(0x10, dcDriveVendor.codeUnits);
        identify.setAll(0x20, 'CD-ROM DRIVE'.codeUnits);
        identify.setAll(0x30, '6.43'.codeUnits);
        _limit = 80;
        _send(identify);
      default:
        _finish(abort: true);
    }
  }

  void _send(List<int> bytes) {
    _buffer = Uint8List.fromList(bytes);
    _position = 0;
    _modeStart = -1;
    if (_buffer.isEmpty) {
      _finish();
      return;
    }
    _dataPhase();
  }

  void _dataPhase() {
    if (_dmaActive) {
      _phaseEnd = _buffer.length;
      _byteCount = 0;
      _reason = 2;
      _status = 0x48 | (_seekComplete ? 0x10 : 0);
      _signal(false); // DMA requests do not issue per-block SPI interrupts.
      return;
    }
    if (_limit == 0) {
      throw const DcUnsupported(
          'Optical drive nonempty PIO transfer with zero byte count');
    }
    _phaseEnd = _position +
        (_buffer.length - _position < _limit
            ? _buffer.length - _position
            : _limit);
    _byteCount = _phaseEnd - _position;
    _reason = _modeStart >= 0 ? 0 : 2;
    _status = 0x48 | (_seekComplete ? 0x10 : 0);
    _signal(true);
  }

  void _slice(List<int> bytes, int start, int length) {
    if (start & 1 != 0 ||
        start > bytes.length ||
        start + length > bytes.length) {
      _finish(key: 5, asc: 0x24);
      return;
    }
    _send(bytes.sublist(start, start + length));
  }

  void _executePacket() {
    onTrace?.call('packet', _packet.toList(growable: false));
    if (_packet[0] == 0x71) {
      onTrace?.call('startup-response-window', [_limit & 255, _limit >> 8]);
    }
    final command = _packet[0];
    if (command != 0x13) {
      _sense.fillRange(0, 10, 0);
      _sense[0] = 0xf0;
      if (_unitAttention) {
        _sense[2] = 6;
        _sense[8] = _attentionAsc;
      }
    }
    switch (command) {
      case 0:
        if (_ready()) _finish();
      case 0x10:
        final track = _track(_fad - 150);
        _slice([
          _driveStatus,
          _format | audio.repeatRemaining,
          track == null
              ? 0
              : track.isAudio
                  ? 0x10
                  : 0x14,
          track?.number ?? 0,
          track == null ? 0 : 1,
          (_fad >> 16) & 255,
          (_fad >> 8) & 255,
          _fad & 255,
          0,
          0
        ], _packet[2], _packet[4]);
      case 0x11:
        _slice(_mode, _packet[2], _packet[4]);
      case 0x12:
        final start = _packet[2], length = _packet[4];
        if (start & 1 != 0 || start + length > 10) {
          _finish(key: 5, asc: 0x24);
          return;
        }
        if (length == 0) {
          _finish();
          return;
        }
        _modeStart = start;
        _buffer = Uint8List(length);
        _position = 0;
        _dataPhase();
      case 0x13:
        _unitAttention = false;
        _slice(_sense, 0, _packet[4]);
      case 0x14:
        if (!_ready()) return;
        if (_packet[1] & 1 != 0) {
          if (diagnosticFormatOverride != 0x80) {
            throw const DcUnsupported('Optical drive high-density TOC');
          }
          // Explicit virtual area backed by the unchanged source data tracks.
          // No claim is made about a physical optical drive high-density layout.
          onTrace?.call('virtual-data-area', [1]);
        }
        _slice(_toc(), 0, (_packet[3] << 8) | _packet[4]);
      case 0x15:
        if (!_ready()) return;
        if (_packet[2] > 99) {
          _finish(key: 5, asc: 0x24);
          return;
        }
        if (_packet[4] == 0) {
          _finish();
          return;
        }
        final session = _session(_packet[2]);
        if (session == null) {
          _finish(key: 5, asc: 0x24);
          return;
        }
        final length =
            _packet[4] < session.length ? _packet[4] : session.length;
        _send(session.sublist(0, length));
      case 0x30:
      case 0x31:
        if (!_ready()) return;
        final flags = _packet[1];
        if (flags & 1 != 0 && (_packet[3] >= 60 || _packet[4] >= 75)) {
          _finish(key: 5, asc: 0x24);
          return;
        }
        final start = flags & 1 != 0
            ? (_packet[2] * 60 + _packet[3]) * 75 + _packet[4]
            : (_packet[2] << 16) | (_packet[3] << 8) | _packet[4];
        _readCount = command == 0x30
            ? (_packet[8] << 16) | (_packet[9] << 8) | _packet[10]
            : (_packet[6] << 8) | _packet[7];
        if (command == 0x31) {
          if (flags & 1 != 0 && (_packet[9] >= 60 || _packet[10] >= 75)) {
            _finish(key: 5, asc: 0x24);
            return;
          }
          final next = flags & 1 != 0
              ? (_packet[8] * 60 + _packet[9]) * 75 + _packet[10]
              : (_packet[8] << 16) | (_packet[9] << 8) | _packet[10];
          if (next < 150 || next >= _drive.status.toc.totalSectors + 150) {
            _finish(key: 5, asc: 0x21);
            return;
          }
          _nextReadFad = next;
        }
        _readFlags = flags;
        if (_readCount == 0) {
          _finish();
          return;
        }
        if (start < 150 ||
            start - 150 + _readCount > _drive.status.toc.totalSectors) {
          _finish(key: 5, asc: 0x21);
          return;
        }
        audio.reset();
        _pauseClocks = 0;
        _reading = true;
        _standby = false;
        _dmaActive = _dmaRequested;
        _fad = _readFad = start;
        _seekComplete = false;
        _loadSector();
      case 0x21:
        if (!_ready()) return;
        final type = _packet[1];
        if (type == 3) {
          audio.reset();
          _beginSeek(0, home: true);
          return;
        }
        if (type == 4) {
          _pauseClocks = 0;
          _standby = false;
          audio.pause();
          _finish();
          return;
        }
        if ((type != 1 && type != 2) ||
            (type == 2 && (_packet[3] >= 60 || _packet[4] >= 75))) {
          _finish(key: 5, asc: 0x24);
          return;
        }
        final target = type == 1
            ? (_packet[2] << 16) | (_packet[3] << 8) | _packet[4]
            : (_packet[2] * 60 + _packet[3]) * 75 + _packet[4];
        if (target < 150 || target >= _drive.status.toc.totalSectors + 150) {
          _finish(key: 5, asc: 0x21);
          return;
        }
        audio.reset();
        _beginSeek(target - 150);
      case 0x20:
        if (!_ready()) return;
        final type = _packet[1] & 7;
        if (type == 7) {
          if (!audio.resume()) {
            _finish(key: 5, asc: 0x24);
          } else {
            _pauseClocks = 0;
            _finish();
          }
          return;
        }
        if ((type != 1 && type != 2) ||
            (type == 2 &&
                (_packet[3] >= 60 ||
                    _packet[4] >= 75 ||
                    _packet[9] >= 60 ||
                    _packet[10] >= 75))) {
          _finish(key: 5, asc: 0x24);
          return;
        }
        int point(int offset) => type == 1
            ? (_packet[offset] << 16) |
                (_packet[offset + 1] << 8) |
                _packet[offset + 2]
            : (_packet[offset] * 60 + _packet[offset + 1]) * 75 +
                _packet[offset + 2];
        final start = point(2), requestedEnd = point(8);
        final leadOut = _drive.status.toc.totalSectors + 150;
        final end = requestedEnd == 0 || requestedEnd > leadOut
            ? leadOut
            : requestedEnd;
        if (start < 150 || start >= leadOut || end <= start) {
          _finish(key: 5, asc: 0x21);
          return;
        }
        audio.start(start, end, _packet[6] & 15);
        _beginSeek(start - 150);
      case 0x40:
        if (!_ready()) return;
        final format = _packet[1] & 15;
        if (format >= 4) {
          _finish(key: 5, asc: 0x24);
          return;
        }
        final allocation = (_packet[3] << 8) | _packet[4];
        if (allocation == 0) {
          _finish();
          return;
        }
        if (allocation <= 4) {
          _sendSubcode([
            0,
            audio.status,
            0,
            format == 0
                ? 100
                : format == 1
                    ? 14
                    : 24
          ]);
          return;
        }
        if (_drive is! CdromSubcodeDrive) {
          throw const DcUnsupported(
              'Optical drive does not expose subcode metadata');
        }
        _subcodeFormat = format;
        _subcodeFad = _fad;
        _status = 0x80;
        _loadSubcode();
      case 0x22:
        if (!_ready()) return;
        if (!audio.scan(reverse: _packet[2] & 1 != 0, speed: _packet[3])) {
          _finish(key: 5, asc: 0x24);
          return;
        }
        _standby = false;
        _pauseClocks = 0;
        _finish();
      case 0x16:
        // SPI section 8, CD_OPEN: a top-loading drive waits for manual opening.
        // Stop the spindle/audio without ejecting or inventing a host event.
        audio.reset();
        dmaEpoch++;
        _dmaActive = _dmaRequested = false;
        _restoredAudioFailure = false;
        _restoredSeekResult = -1;
        _standby = _seekHome = _reading = _waitingSector = false;
        _pauseClocks = 0;
        _seekTarget = _nextReadFad = -1;
        _subcodeFormat = -1;
        _seekComplete = false;
        _fad = 150;
        _buffer = Uint8List(0);
        _position = _phaseEnd = _byteCount = 0;
        _status = 0x80;
        if (_mediaState == CdromDriveState.trayOpen) _finish();
      case 0x70:
      case 0x71:
        // Undocumented startup request: acceptance is an explicit bring-up bypass.
        // No drive verification algorithm is implemented.
        if (bypassBootChecks?.call() ?? false) {
          onTrace?.call('startup-check-bypassed', [command]);
          if (command == 0x71) {
            // The original BIOS extracts a byte from a length-delimited record
            // and tests its bit 4. This minimal pass record is not authentication.
            final response = Uint8List(1024);
            response[1] = 3;
            response[2] = 0x10;
            _send(response);
          } else {
            _finish();
          }
        } else {
          _finish(key: 5, asc: 0x20);
        }
      default:
        _finish(key: 5, asc: 0x20);
    }
  }

  void _sendSubcode(List<int> bytes) {
    final allocation = (_packet[3] << 8) | _packet[4];
    final length = allocation < bytes.length ? allocation : bytes.length;
    if (length >= 2) bytes[1] = audio.takeStatus();
    _subcodeFormat = -1;
    _send(bytes.sublist(0, length));
  }

  void _loadSubcode() {
    final result = (_drive as CdromSubcodeDrive).readSubcode(_subcodeFad - 150);
    if (result == null) return;
    if (!result.readable) {
      _finish(key: 3, asc: 0x11);
      return;
    }
    if (result.raw != null && result.raw!.length != 96) {
      throw const DcUnsupported('Optical drive invalid raw P-W subcode length');
    }
    if (_subcodeFormat == 0) {
      final raw = result.raw;
      if (raw == null || raw.length != 96) {
        throw const DcUnsupported(
            'Optical drive missing or invalid raw P-W subcode');
      }
      _sendSubcode([0, audio.status, 0, 100, ...raw]);
      return;
    }
    if (_subcodeFormat >= 2) {
      _sendIdentifier(result);
      return;
    }
    final position = result.position ??
        (result.raw == null
            ? null
            : CdromSubcode.fromRaw(result.raw!).position);
    final absolute = position?.discFrames ?? _subcodeFad;
    if (position == null ||
        position.control < 0 ||
        position.control > 15 ||
        position.track < 0 ||
        (position.track > 99 && position.track != 0xaa) ||
        position.index < 0 ||
        position.index > 99 ||
        position.trackFrames < 0 ||
        position.trackFrames > 0xffffff ||
        absolute < 0 ||
        absolute > 0xffffff) {
      throw const DcUnsupported(
          'Optical drive missing or invalid Q position subcode');
    }
    _sendSubcode([
      0,
      audio.status,
      0,
      14,
      (position.control << 4) | 1,
      position.track,
      position.index,
      (position.trackFrames >> 16) & 255,
      (position.trackFrames >> 8) & 255,
      position.trackFrames & 255,
      0,
      (absolute >> 16) & 255,
      (absolute >> 8) & 255,
      absolute & 255,
    ]);
  }

  void _sendIdentifier(CdromSubcode subcode) {
    final catalog = _subcodeFormat == 2;
    final supplied = catalog ? subcode.catalog : subcode.recording;
    final decoded = supplied == null && subcode.raw != null
        ? CdromSubcode.fromRaw(subcode.raw!)
        : null;
    final identifier =
        supplied ?? (catalog ? decoded?.catalog : decoded?.recording);
    if (identifier == null || identifier.frame < 0 || identifier.frame >= 75) {
      throw const DcUnsupported(
          'Optical drive missing or invalid subcode identifier');
    }
    final value = identifier.value;
    final pattern = catalog ? r'^[0-9]{13}$' : r'^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$';
    if (value.isNotEmpty &&
        (value.length != (catalog ? 13 : 12) ||
            !RegExp(pattern).hasMatch(value))) {
      throw const DcUnsupported(
          'Optical drive malformed subcode identifier characters');
    }
    final bytes = List<int>.filled(24, 0);
    bytes[1] = audio.status;
    bytes[3] = 24;
    bytes[4] = _subcodeFormat;
    bytes[8] =
        value.isEmpty || (catalog && value == '0000000000000') ? 0 : 0x80;
    // The detailed SPI byte tables take precedence over conflicting ISRC prose.
    final characters =
        value.isEmpty ? (catalog ? '0000000000000' : '000000000000') : value;
    bytes.setRange(9, 9 + characters.length, characters.codeUnits);
    bytes[catalog ? 23 : 22] = identifier.frame;
    _sendSubcode(bytes);
  }

  Uint8List? _session(int number) {
    final toc = _drive.status.toc, sessions = _drive.status.toc.sessions;
    if (sessions == null) {
      throw const DcUnsupported(
          'Optical drive does not expose session metadata');
    }
    if (sessions.isEmpty ||
        sessions.length > 99 ||
        toc.totalSectors + 150 > 0xffffff) {
      throw const DcUnsupported('Optical drive invalid session metadata');
    }
    var previousTrack = 0, previousLba = -1;
    for (var i = 0; i < sessions.length; i++) {
      final session = sessions[i];
      if (session.number != i + 1 ||
          session.firstTrack <= previousTrack ||
          session.firstTrack > 99 ||
          session.startLba <= previousLba ||
          session.startLba >= toc.totalSectors ||
          !toc.tracks.any((track) =>
              track.number == session.firstTrack &&
              track.startLba == session.startLba)) {
        throw const DcUnsupported(
            'Optical drive inconsistent session boundary');
      }
      previousTrack = session.firstTrack;
      previousLba = session.startLba;
    }
    if (number > sessions.length) return null;
    final fad =
        (number == 0 ? toc.totalSectors : sessions[number - 1].startLba) + 150;
    return Uint8List.fromList([
      _driveStatus & 15,
      0,
      number == 0 ? sessions.length : sessions[number - 1].firstTrack,
      (fad >> 16) & 255,
      (fad >> 8) & 255,
      fad & 255,
    ]);
  }

  CdromTrack? _track(int lba) {
    for (final track in _drive.status.toc.tracks.reversed) {
      if (lba >= track.startLba && lba < track.startLba + track.sectors) {
        return track;
      }
    }
    return null;
  }

  Uint8List _toc() {
    final toc = _drive.status.toc;
    final bytes = Uint8List(408)..fillRange(0, 408, 255);
    for (final track in toc.tracks) {
      if (track.number < 1 || track.number > 99) {
        throw const DcUnsupported('Optical drive invalid track number');
      }
      final offset = (track.number - 1) * 4, fad = track.startLba + 150;
      bytes[offset] = track.isAudio ? 1 : 0x41;
      bytes[offset + 1] = (fad >> 16) & 255;
      bytes[offset + 2] = (fad >> 8) & 255;
      bytes[offset + 3] = fad & 255;
    }
    if (toc.tracks.isEmpty) return bytes;
    final first = toc.tracks.first, last = toc.tracks.last;
    bytes.setRange(396, 404, [
      first.isAudio ? 1 : 0x41,
      first.number,
      0,
      0,
      last.isAudio ? 1 : 0x41,
      last.number,
      0,
      0
    ]);
    final end = toc.totalSectors + 150;
    bytes.setRange(404, 408, [
      last.isAudio ? 1 : 0x41,
      (end >> 16) & 255,
      (end >> 8) & 255,
      end & 255
    ]);
    return bytes;
  }

  void _loadSector() {
    final lba = _readFad - 150;
    _fad = _readFad;
    final raw = _drive.read(lba);
    if (raw == null) {
      _waitingSector = true;
      _status = 0x80;
      return;
    }
    _subcodeFormat = -1;
    _waitingSector = false;
    if (raw.length != 2352) {
      _finish(key: 3, asc: 0x11);
      return;
    }
    final output = _sectorData(raw, audio: _track(lba)?.isAudio ?? false);
    if (output == null) return;
    _readCount--;
    _seekComplete = true;
    _fad = _readFad++;
    _send(output);
    if (_readCount == 0 && _nextReadFad >= 0) {
      final next = _nextReadFad;
      _nextReadFad = -1;
      // The speculative result is checked only by a later explicit read.
      _drive.read(next - 150);
    }
  }

  List<int>? _sectorData(Uint8List raw, {required bool audio}) {
    final type = (_readFlags >> 1) & 7, select = _readFlags & 0xf0;
    List<int>? invalid() {
      _finish(key: 5, asc: 0x24);
      return null;
    }

    if (type == 7 ||
        (type == 1 && !audio) ||
        (type == 2 && (audio || raw[15] != 1)) ||
        (type > 2 && audio)) {
      return invalid();
    }
    if (audio) return raw;
    final nonXa = type == 6;
    if (nonXa || raw[15] == 2) {
      final isXa = _drive.status.toc.isXa;
      if (isXa == null) {
        throw const DcUnsupported(
            'Optical drive does not expose XA disc identity');
      }
      if (nonXa == isXa) return invalid();
    } else if (type > 2) {
      return invalid();
    }
    if (!nonXa && raw[15] != 1 && raw[15] != 2) {
      throw DcUnsupported('Optical drive sector mode ${raw[15]}');
    }
    final xa = !nonXa && raw[15] == 2;
    final form2 = xa && raw[18] & 0x20 != 0;
    if ((type == 4 && form2) || (type == 5 && !form2)) return invalid();
    if (select & 0x10 != 0) return raw;
    if (!xa) {
      final end = nonXa ? 2352 : 2064;
      return switch (select) {
        0x20 => raw.sublist(16, end),
        0x80 => raw.sublist(12, 16),
        0xa0 => raw.sublist(12, end),
        _ => invalid(),
      };
    }
    if (![0x20, 0x40, 0x60, 0x80, 0xc0, 0xe0].contains(select) &&
        !(type == 3 && select == 0xa0)) {
      return invalid();
    }
    if (select & 0x60 != 0) {
      for (var i = 0; i < 4; i++) {
        if (raw[16 + i] != raw[20 + i]) {
          throw const DcUnsupported(
              'Optical drive inconsistent XA subheader copies');
        }
      }
    }
    if (type == 3 && select & 0x20 != 0) {
      if (!form2) {
        // SPI prints 28 dummy bytes for Form 1, inconsistent with 2336 bytes.
        throw const DcUnsupported(
            'Optical drive ambiguous Mode 2 aggregate padding');
      }
      // Mode 2 data implicitly includes the subheader; dummy contents are a policy.
      return [...raw.sublist(select & 0x80 != 0 ? 12 : 16, 2348), 0, 0, 0, 0];
    }
    final start = select & 0x80 != 0
        ? 12
        : select & 0x40 != 0
            ? 16
            : 24;
    final end = select & 0x20 != 0
        ? (form2 ? 2348 : 2072)
        : select & 0x40 != 0
            ? 24
            : 16;
    return raw.sublist(start, end);
  }

  void _setMode() {
    final next = Uint8List.fromList(_mode);
    next.setRange(_modeStart, _modeStart + _buffer.length, _buffer);
    if (next[0] != 0 ||
        next[1] != 0 ||
        next[2] > 7 ||
        next[3] != 0 ||
        next[6] & ~0x39 != 0 ||
        next[7] != 0 ||
        next[8] != 0) {
      _finish(key: 5, asc: 0x26);
      return;
    }
    if (_mode[4] != next[4] || _mode[5] != next[5]) _pauseClocks = 0;
    _mode.setAll(0, next);
    _finish();
  }
}

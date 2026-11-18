import 'dart:async';

import 'package:uuid/uuid.dart';

import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/backend/features/devices/devices_service.dart';
import 'package:licoup/src/contracts/devices/devices_models.dart';
import 'package:licoup/src/contracts/devices/devices_notice_repository.dart';

typedef DevicesClipboardWriter = Future<bool> Function(String text);
typedef DevicesTimerFactory =
    Timer Function(Duration delay, void Function() callback);

/// Owns the Devices surface: enrollment with a LicoArc station, pairing with
/// another desktop, paired peers, and agent messages sent to a peer's agent.
///
/// Every CLI mutation runs through one serial lane, so a status read never
/// lands before a preceding mutation. While a pairing is pending or a sent
/// message has no result yet, the controller re-reads the CLI state after
/// [progressInterval]; the persistent CLI host receives pairing replies and
/// results itself, and this re-read only projects what it already holds.
final class DevicesController extends ApplicationStateOwner {
  DevicesController({
    required DevicesService service,
    required DevicesNoticeRepository noticeRepository,
    required DevicesClipboardWriter writeClipboard,
    this.progressInterval = const Duration(seconds: 3),
    DevicesTimerFactory? createTimer,
    String Function()? newIntentId,
  }) : _service = service,
       _noticeRepository = noticeRepository,
       _writeClipboard = writeClipboard,
       _createTimer = createTimer ?? Timer.new,
       _newIntentId = newIntentId ?? const Uuid().v4;

  final DevicesService _service;
  final DevicesNoticeRepository _noticeRepository;
  final DevicesClipboardWriter _writeClipboard;
  final DevicesTimerFactory _createTimer;
  final String Function() _newIntentId;
  final Duration progressInterval;

  Future<void> _tail = Future<void>.value();
  int _pendingOperations = 0;
  Timer? _progressTimer;
  DevicesStatus _status = DevicesStatus.unknown;
  bool _loaded = false;
  DevicePairingOffer? _offer;
  List<DeviceMessageResult> _results = const <DeviceMessageResult>[];
  final Set<String> _outstandingCommandIds = <String>{};
  String _errorCode = '';
  bool _legacyNoticeAcknowledged = false;
  bool _noticeWritable = true;

  DevicesStatus get status => _status;

  /// Whether the CLI state has been read at least once.
  bool get loaded => _loaded;
  bool get busy => _pendingOperations > 0;
  DevicePairingOffer? get offer => _offer;
  List<DeviceMessageResult> get results => _results;
  Set<String> get outstandingCommandIds =>
      Set<String>.unmodifiable(_outstandingCommandIds);
  String get errorCode => _errorCode;

  /// Whether the one-time "pair your devices again" notice should show.
  bool get showLegacyPairingNotice =>
      _status.legacyPairingsDetected && !_legacyNoticeAcknowledged;

  /// Reads the notice acknowledgement. An unreadable record is preserved:
  /// the notice shows and a later dismissal stays in memory.
  Future<void> loadNoticeAcknowledgement() async {
    try {
      _legacyNoticeAcknowledged = await _noticeRepository
          .readLegacyPairingNoticeAcknowledged();
    } on Object {
      _legacyNoticeAcknowledged = false;
      _noticeWritable = false;
    }
    publishChange();
  }

  Future<void> acknowledgeLegacyPairingNotice() async {
    if (_legacyNoticeAcknowledged) return;
    _legacyNoticeAcknowledged = true;
    publishChange();
    if (!_noticeWritable) return;
    try {
      await _noticeRepository.writeLegacyPairingNoticeAcknowledged();
    } on Object {
      // The dismissal holds for this session; the record is retried on the
      // next dismissal after a restart.
    }
  }

  Future<bool> refresh() => _enqueue(_readState);

  Future<bool> enroll({
    required String station,
    required String invitation,
    String caPem = '',
  }) {
    final normalizedStation = station.trim();
    final uri = Uri.tryParse(normalizedStation);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return Future.value(_reject('devices_station_invalid'));
    }
    if (invitation.trim().isEmpty) {
      return Future.value(_reject('devices_invitation_required'));
    }
    return _enqueue(() async {
      await _service.enroll(
        station: normalizedStation,
        invitation: invitation.trim(),
        caPem: caPem.trim().isEmpty ? null : caPem.trim(),
      );
      await _readState();
    });
  }

  Future<bool> offerPairing({String label = ''}) => _enqueue(() async {
    _offer = await _service.offerPairing(label: label.trim());
    await _readState();
  });

  Future<bool> claimPairing({required String code, String label = ''}) {
    if (code.trim().isEmpty) {
      return Future.value(_reject('devices_pairing_code_required'));
    }
    return _enqueue(() async {
      await _service.claimPairing(code: code.trim(), label: label.trim());
      await _readState();
    });
  }

  Future<bool> cancelPairing(String pairingId) => _enqueue(() async {
    await _service.cancelPairing(pairingId);
    if (_offer?.pairingId == pairingId) _offer = null;
    await _readState();
  });

  void dismissOffer() {
    if (_offer == null) return;
    _offer = null;
    publishChange();
  }

  Future<bool> copyPairingCode() async {
    final code = _offer?.code ?? '';
    if (code.isEmpty) return false;
    return _writeClipboard(code);
  }

  Future<bool> unpair(String peerId) => _enqueue(() async {
    await _service.unpair(peerId);
    await _readState();
  });

  Future<bool> sendMessage({
    required String peerId,
    required String agent,
    required String body,
  }) {
    if (!_status.peers.any((peer) => peer.peerId == peerId)) {
      return Future.value(_reject('devices_peer_required'));
    }
    if (agent.trim().isEmpty) {
      return Future.value(_reject('devices_message_agent_required'));
    }
    if (body.trim().isEmpty) {
      return Future.value(_reject('devices_message_body_required'));
    }
    return _enqueue(() async {
      final commandId = await _service.sendMessage(
        peerId: peerId,
        agent: agent.trim(),
        body: body.trim(),
        clientIntentId: _newIntentId(),
      );
      _outstandingCommandIds.add(commandId);
      await _readResults();
    });
  }

  Future<void> _readState() async {
    _status = await _service.status();
    _loaded = true;
    if (_offer != null &&
        !_status.pairings.any(
          (pairing) =>
              pairing.pairingId == _offer!.pairingId && pairing.state.pending,
        )) {
      _offer = null;
    }
    if (_status.enrolled && _status.peers.isNotEmpty) {
      await _readResults();
    }
  }

  Future<void> _readResults() async {
    _results = await _service.messageResults();
    _outstandingCommandIds.removeAll(
      _results.map((result) => result.commandId),
    );
  }

  bool _reject(String code) {
    _errorCode = code;
    publishChange();
    return false;
  }

  Future<bool> _enqueue(Future<void> Function() operation) {
    _pendingOperations += 1;
    _progressTimer?.cancel();
    _progressTimer = null;
    publishChange();
    final completer = Completer<bool>();
    _tail = _tail.then((_) async {
      var succeeded = false;
      try {
        await operation();
        _errorCode = '';
        succeeded = true;
      } on Object catch (error) {
        _errorCode = devicesFailureCode(error);
      } finally {
        _pendingOperations -= 1;
        _scheduleProgressRefresh();
        publishChange();
        completer.complete(succeeded);
      }
    });
    return completer.future;
  }

  void _scheduleProgressRefresh() {
    if (applicationStateDisposed ||
        _pendingOperations > 0 ||
        _progressTimer != null ||
        (!_status.hasPendingPairing && _outstandingCommandIds.isEmpty)) {
      return;
    }
    _progressTimer = _createTimer(progressInterval, () {
      _progressTimer = null;
      if (!applicationStateDisposed) unawaited(refresh());
    });
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _progressTimer = null;
    super.dispose();
  }
}

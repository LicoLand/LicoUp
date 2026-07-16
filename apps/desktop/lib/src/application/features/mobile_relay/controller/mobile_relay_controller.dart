import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/application/features/mobile_relay/policy/mobile_pairing_invite_codec.dart';
import 'package:flutter_client/src/application/features/mobile_relay/policy/mobile_pairing_policy.dart';
import 'package:flutter_client/src/application/features/mobile_relay/policy/mobile_relay_policy.dart';
import 'package:flutter_client/src/contracts/mobile_pairing_presentation.dart';
import 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:flutter_client/src/contracts/mobile_relay_control.dart';

typedef MobileRelayClipboardWriter = Future<void> Function(String text);
typedef MobileRelayTargetDiscovery =
    Future<void> Function(Map<String, dynamic>? pairingStatus);

/// Owns Mobile Relay configuration, pairing, polling, and command projection.
final class MobileRelayController extends ChangeNotifier {
  MobileRelayController({
    required MobileRelayGateway gateway,
    required MobileRelayOperationGate operationGate,
    required bool Function() isMobileRuntime,
    required bool Function() isAndroid,
    required bool Function() isIos,
    required MobileRelayClipboardWriter writeClipboard,
    required MobileRelayFeatureStatusSink onStatus,
    required Future<void> Function() ensureTargets,
    required MobileRelayTargetDiscovery discoverTargets,
  }) : _gateway = gateway,
       _operationGate = operationGate,
       _isMobileRuntime = isMobileRuntime,
       _isAndroid = isAndroid,
       _isIos = isIos,
       _writeClipboard = writeClipboard,
       _onStatus = onStatus,
       _ensureTargets = ensureTargets,
       _discoverTargets = discoverTargets;

  final MobileRelayGateway _gateway;
  final MobileRelayOperationGate _operationGate;
  final bool Function() _isMobileRuntime;
  final bool Function() _isAndroid;
  final bool Function() _isIos;
  final MobileRelayClipboardWriter _writeClipboard;
  final MobileRelayFeatureStatusSink _onStatus;
  final Future<void> Function() _ensureTargets;
  final MobileRelayTargetDiscovery _discoverTargets;

  MobileRelayConfig _config = MobileRelayConfig.defaults();
  Map<String, dynamic>? _actionResult;
  MobilePairingPresentation? _pairingPresentation;
  List<MobileRelayCommand> _commands = const [];
  List<Map<String, dynamic>> _secureExecutions = const [];
  final LinkedHashSet<String> _processedCommandIds = LinkedHashSet<String>();
  Timer? _timer;
  bool _polling = false;
  bool _authorizationRequired = false;

  MobileRelayConfig get config => MobileRelayPolicy.publicConfig(_config);
  Map<String, dynamic>? get actionResult => _actionResult;
  MobilePairingPresentation? get pairingPresentation => _pairingPresentation;
  List<MobileRelayCommand> get commands => _commands;
  List<Map<String, dynamic>> get secureExecutions => _secureExecutions;
  bool get busy => _operationGate.busy;
  bool get polling => _polling;
  bool get hasPollingTimer => _timer != null;
  bool get authorizationRequired => _authorizationRequired;

  Future<void> loadConfig({bool authorizeSecrets = false}) async {
    _replaceHydratedConfig(
      await _gateway.loadConfig(authorizeSecrets: authorizeSecrets),
    );
    notifyListeners();
  }

  void replaceConfig(MobileRelayConfig value) {
    _replaceHydratedConfig(value);
    notifyListeners();
  }

  void replaceActionResult(Map<String, dynamic>? value) {
    _actionResult = MobilePairingPolicy.actionProjection(value);
    _pairingPresentation = null;
    notifyListeners();
  }

  Future<void> configureGateway({
    required bool useCustomGateway,
    required String customGatewayUrl,
  }) async {
    final gateway = canonicalMobileRelayGatewayOrigin(customGatewayUrl);
    if (!useCustomGateway ||
        gateway == null ||
        mobileRelayGatewayIsEphemeralCustom(gateway)) {
      _report(
        '请先配置有效的移动中转网关。',
        'Configure a valid mobile relay gateway first.',
        errorCode: 'mobile_relay_gateway_required',
      );
      notifyListeners();
      return;
    }
    if (!_operationGate.tryAcquire()) return;
    _report('正在保存移动中转网关配置。', 'Saving the mobile relay gateway configuration.');
    notifyListeners();
    try {
      _replaceHydratedConfig(
        await _gateway.configureGateway(
          useCustomGateway: useCustomGateway,
          customGatewayUrl: gateway,
        ),
      );
      _report('已保存移动中转网关配置。', 'Mobile relay gateway configuration saved.');
    } catch (_) {
      _report(
        '移动中转网关配置失败。',
        'Failed to configure the mobile relay gateway.',
        errorCode: 'mobile_relay_gateway_configuration_failed',
      );
    } finally {
      _operationGate.release();
      notifyListeners();
    }
  }

  Future<void> createPairing() async {
    if (_isMobileRuntime()) {
      _report(
        '手机端不能创建桌面配对码。',
        'A desktop pairing code cannot be created on mobile.',
      );
      notifyListeners();
      return;
    }
    if (!_requireConfiguredGateway()) return;
    if (!_operationGate.tryAcquire()) return;
    _actionResult = null;
    _pairingPresentation = null;
    _config = _config.copyWith(lastPairingCode: '', lastPairingExpiresAt: '');
    _report('正在创建手机配对码。', 'Creating a phone pairing code.');
    notifyListeners();
    try {
      final rawResult = await _gateway.createPairing();
      _pairingPresentation = MobilePairingPolicy.presentation(rawResult);
      _actionResult = MobilePairingPolicy.actionProjection(rawResult);
      _replaceHydratedConfig(await _gateway.loadConfig());
      await _ensureTargets();
      startPolling();
      _report('已创建一次性手机配对码。', 'One-time phone pairing code created.');
    } catch (_) {
      _report(
        '手机配对码创建失败。',
        'Failed to create the phone pairing code.',
        errorCode: 'mobile_relay_pairing_create_failed',
      );
    } finally {
      _operationGate.release();
      notifyListeners();
    }
  }

  void dismissPairingPresentation() {
    final changed =
        _pairingPresentation != null ||
        _actionResult != null ||
        _config.lastPairingCode.isNotEmpty ||
        _config.lastPairingExpiresAt.isNotEmpty;
    _pairingPresentation = null;
    _actionResult = null;
    _config = _config.copyWith(lastPairingCode: '', lastPairingExpiresAt: '');
    if (changed) notifyListeners();
  }

  Future<bool> copyPairingCode(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return false;
    try {
      await _writeClipboard(trimmed);
      _report('配对码已复制。', 'Pairing code copied.');
      return true;
    } catch (_) {
      _report(
        '配对码复制失败。',
        'Failed to copy the pairing code.',
        errorCode: 'mobile_relay_pairing_copy_failed',
      );
      return false;
    } finally {
      notifyListeners();
    }
  }

  Future<void> refreshPairingStatus() async {
    if (!_config.hasPairing ||
        !_requireConfiguredGateway() ||
        !_operationGate.tryAcquire()) {
      return;
    }
    _report('正在刷新手机配对状态。', 'Refreshing phone pairing status.');
    notifyListeners();
    try {
      final rawResult = await _gateway.refreshPairingStatus();
      if (_pairingPresentation == null) {
        _actionResult = MobilePairingPolicy.actionProjection(rawResult);
      }
      _replaceHydratedConfig(await _gateway.loadConfig());
      _report(
        _config.paired ? '手机已配对。' : '等待手机配对。',
        _config.paired ? 'Phone paired.' : 'Waiting for phone pairing.',
      );
    } catch (_) {
      _report(
        '手机配对状态刷新失败。',
        'Failed to refresh phone pairing status.',
        errorCode: 'mobile_relay_pairing_refresh_failed',
      );
    } finally {
      _operationGate.release();
      notifyListeners();
    }
  }

  Future<void> claimPairingInvite(String inviteText) async {
    final trimmed = inviteText.trim();
    if (trimmed.isEmpty) return;
    late final Map<String, dynamic> invite;
    try {
      invite = MobilePairingInviteCodec.decode(trimmed);
    } on FormatException {
      _report(
        '设备配对信息无效。',
        'The device pairing invite is invalid.',
        errorCode: 'mobile_relay_pairing_invite_invalid',
      );
      notifyListeners();
      return;
    }
    final gateway = canonicalMobileRelayGatewayOrigin(
      (invite['gatewayUrl'] ?? '').toString(),
    );
    if (gateway == null || mobileRelayGatewayIsEphemeralCustom(gateway)) {
      _report(
        '配对信息缺少有效的移动中转网关。',
        'The pairing invite does not contain a valid mobile relay gateway.',
        errorCode: 'mobile_relay_gateway_required',
      );
      notifyListeners();
      return;
    }
    if (!_operationGate.tryAcquire()) return;
    _report('正在配对设备。', 'Pairing the device.');
    notifyListeners();
    try {
      final rawResult = await _gateway.claimPairing({
        ...invite,
        'gatewayUrl': gateway,
      });
      _actionResult = MobilePairingPolicy.actionProjection(rawResult);
      _pairingPresentation = null;
      _replaceHydratedConfig(await _gateway.loadConfig());
      final pairingStatus = await _refreshPairingStatusForDiscovery();
      await _discoverTargets(pairingStatus);
      _report('设备已配对。', 'Device paired.');
    } catch (_) {
      _report(
        '设备配对失败。',
        'Failed to pair the device.',
        errorCode: 'mobile_relay_pairing_claim_failed',
      );
    } finally {
      _operationGate.release();
      notifyListeners();
    }
  }

  Future<void> selectDevice(String deviceId) async {
    final normalized = deviceId.trim();
    if (normalized.isEmpty || !_operationGate.tryAcquire()) return;
    MobileRelayPairedDevice? selected;
    for (final device in _config.deviceTabs) {
      if (device.id == normalized || device.pairingId == normalized) {
        selected = device;
        break;
      }
    }
    if (selected == null ||
        !selected.isUsable ||
        selected.pairingId == _config.pairingId) {
      _operationGate.release();
      return;
    }
    final gateway = canonicalMobileRelayGatewayOrigin(selected.gatewayUrl);
    if (gateway == null || mobileRelayGatewayIsEphemeralCustom(gateway)) {
      _operationGate.release();
      _report(
        '配对设备缺少有效的移动中转网关。',
        'The paired device does not have a valid mobile relay gateway.',
        errorCode: 'mobile_relay_gateway_required',
      );
      notifyListeners();
      return;
    }
    _report('正在切换到 ${selected.label}。', 'Switching to ${selected.label}.');
    notifyListeners();
    try {
      _config = _config.copyWith(
        pcClientId: selected.id,
        pcClientName: selected.label,
        pairingId: selected.pairingId,
        mobileToken: selected.mobileToken,
        mobileTokenPresent:
            selected.credentialPresent || selected.mobileToken.isNotEmpty,
        paired: true,
        defaultGatewayUrl: '',
        useCustomGateway: true,
        customGatewayUrl: gateway,
      );
      await _gateway.saveConfig(_config);
      await _discoverTargets(null);
      _report('已切换到 ${selected.label}。', 'Switched to ${selected.label}.');
    } catch (_) {
      _report(
        '切换配对电脑失败。',
        'Failed to switch the paired computer.',
        errorCode: 'mobile_relay_device_switch_failed',
      );
    } finally {
      _operationGate.release();
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> pairingStatusForTargetDiscovery({
    Map<String, dynamic>? pairingStatus,
  }) async {
    if (pairingStatus != null) {
      return _config.hasPairing ? pairingStatus : null;
    }
    _replaceHydratedConfig(await _gateway.loadConfig());
    if (!_config.hasPairing || !_hasConfiguredGateway) return null;
    final status = await _gateway.refreshPairingStatus();
    _replaceHydratedConfig(await _gateway.loadConfig());
    notifyListeners();
    return status;
  }

  void startPolling() {
    if (!_config.hasPairing || !_requireConfiguredGateway()) return;
    _timer?.cancel();
    _timer = null;
    if (_isIos()) {
      _config = _config.copyWith(relayEnabled: false);
      notifyListeners();
      return;
    }
    _config = _config.copyWith(relayEnabled: true);
    if (!_isAndroid()) {
      final interval = Duration(
        seconds: _config.pollIntervalSeconds.clamp(3, 60),
      );
      _timer = Timer.periodic(interval, (_) => unawaited(pollOnce()));
    }
    unawaited(_saveConfigSilently());
    notifyListeners();
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
    _config = _config.copyWith(relayEnabled: false);
    unawaited(_saveConfigSilently());
    notifyListeners();
  }

  Future<void> pollOnce({bool showProgress = false}) async {
    if (_isMobileRuntime()) return;
    if (showProgress) {
      _authorizationRequired = false;
    } else if (_authorizationRequired) {
      return;
    }
    if (_polling ||
        !_config.hasPairing ||
        !_hasConfiguredGateway ||
        !_operationGate.tryAcquire()) {
      return;
    }
    _polling = true;
    var shouldNotify = showProgress;
    if (showProgress) {
      _report('正在同步手机中转命令。', 'Syncing mobile relay commands.');
      notifyListeners();
    }
    try {
      final rawResult = await _gateway.syncCommands(
        allowInteraction: showProgress,
      );
      _authorizationRequired = false;
      final rawCommands = MobileRelayPolicy.commands(rawResult['commands']);
      _commands = List<MobileRelayCommand>.unmodifiable(
        rawCommands.map(MobileRelayPolicy.publicCommand),
      );
      _secureExecutions = await _executeSecureCommands(rawCommands);
      if (_pairingPresentation == null) {
        _actionResult = MobileRelayPolicy.syncProjection(
          result: rawResult,
          commandCount: rawCommands.length,
          secureExecutionCount: _secureExecutions.length,
        );
      }
      shouldNotify =
          shouldNotify ||
          rawCommands.isNotEmpty ||
          _secureExecutions.isNotEmpty;
      if (rawCommands.isNotEmpty || showProgress) {
        final status = _syncStatus(
          rawCommands.length,
          _secureExecutions.length,
        );
        _report(status.$1, status.$2);
      }
    } on MobileRelayAuthorizationRequired {
      _authorizationRequired = true;
      _report(
        '手机中转等待本机授权，请手动同步。',
        'Mobile relay is waiting for local authorization; sync manually.',
        errorCode: 'mobile_relay_authorization_required',
      );
      shouldNotify = true;
    } catch (_) {
      _report(
        '手机中转同步失败。',
        'Failed to sync the mobile relay.',
        errorCode: 'mobile_relay_sync_failed',
      );
      shouldNotify = true;
    } finally {
      _polling = false;
      _operationGate.release();
      if (shouldNotify) notifyListeners();
    }
  }

  Future<List<Map<String, dynamic>>> _executeSecureCommands(
    List<MobileRelayCommand> commands,
  ) async {
    final executions = <Map<String, dynamic>>[];
    for (final command in commands) {
      final request = MobileRelayPolicy.executionRequest(command);
      if (request == null ||
          !MobileRelayPolicy.rememberCommand(
            _processedCommandIds,
            command.commandId,
          )) {
        continue;
      }
      try {
        final result = await _gateway.executeSecureMeshCommand(
          payload: request.payload,
          context: request.context,
        );
        executions.add(
          MobileRelayPolicy.executionProjection(
            commandId: command.commandId,
            succeeded: result['ok'] == true,
            errorCode: result['ok'] == true
                ? ''
                : MobileRelayPolicy.stableCode(result['errorCode']),
          ),
        );
      } catch (_) {
        executions.add(
          MobileRelayPolicy.executionProjection(
            commandId: command.commandId,
            succeeded: false,
            errorCode: 'secure_mesh_command_execution_failed',
          ),
        );
      }
    }
    return List<Map<String, dynamic>>.unmodifiable(executions);
  }

  Future<Map<String, dynamic>?> _refreshPairingStatusForDiscovery() async {
    if (!_isMobileRuntime() || !_config.hasPairing || !_hasConfiguredGateway) {
      return null;
    }
    try {
      final status = await _gateway.refreshPairingStatus();
      _replaceHydratedConfig(await _gateway.loadConfig());
      return status;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveConfigSilently() async {
    try {
      await _gateway.saveConfig(_config);
    } catch (_) {
      // Timer lifecycle persistence is best-effort; user-triggered operations
      // surface their own stable error codes.
    }
  }

  void _replaceHydratedConfig(MobileRelayConfig value) {
    _config = MobileRelayPolicy.mergeHydratedSecrets(_config, value);
  }

  bool get _hasConfiguredGateway {
    final gateway = canonicalMobileRelayGatewayOrigin(
      _config.effectiveGatewayUrl,
    );
    return gateway != null && !mobileRelayGatewayIsEphemeralCustom(gateway);
  }

  bool _requireConfiguredGateway() {
    if (_hasConfiguredGateway) return true;
    _report(
      '请先配置移动中转网关。',
      'Configure the mobile relay gateway first.',
      errorCode: 'mobile_relay_gateway_required',
    );
    notifyListeners();
    return false;
  }

  (String, String) _syncStatus(int commandCount, int executionCount) {
    if (commandCount == 0) {
      return ('手机中转已同步，暂无新命令。', 'Mobile relay synced; no new commands.');
    }
    if (executionCount == 0) {
      return (
        '已处理 $commandCount 条手机中转命令。',
        'Processed $commandCount mobile relay commands.',
      );
    }
    return (
      '已处理 $commandCount 条手机中转命令，执行 $executionCount 条 Secure Mesh 命令。',
      'Processed $commandCount mobile relay commands and executed $executionCount Secure Mesh commands.',
    );
  }

  void _report(String chinese, String english, {String errorCode = ''}) {
    _onStatus(
      MobileRelayFeatureStatus(
        chinese: chinese,
        english: english,
        caption: 'Mobile relay',
        errorCode: errorCode,
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

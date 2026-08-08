import 'package:flutter/foundation.dart';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/client_update_gateway.dart';
import 'package:licoup/src/contracts/client_update_models.dart';

final class ClientUpdateStatusUpdate {
  const ClientUpdateStatusUpdate({
    required this.chinese,
    required this.english,
    this.errorCode = '',
  });

  final String chinese;
  final String english;
  final String errorCode;
}

typedef ClientUpdateStatusSink = void Function(ClientUpdateStatusUpdate update);

/// Independently testable signed-update workflow.
final class ClientUpdateController extends ChangeNotifier {
  ClientUpdateController({
    required ClientUpdateGateway gateway,
    required AgentCommandRunner agentService,
    required ClientUpdateStatusSink onStatus,
  }) : _gateway = gateway,
       _agentService = agentService,
       _onStatus = onStatus;

  final ClientUpdateGateway _gateway;
  final AgentCommandRunner _agentService;
  final ClientUpdateStatusSink _onStatus;

  ClientUpdateStatus _status = const ClientUpdateStatus(
    phase: ClientUpdatePhase.idle,
    currentVersion: '',
    channel: 'stable',
  );
  String _manifestPath = '';
  String _publicKeysPath = '';
  String _channel = 'stable';
  String _revocationPath = '';
  String _artifactUrl = '';
  String _artifactReceiptId = '';
  bool _artifactDownloaded = false;
  bool _artifactVerified = false;
  bool _busy = false;
  bool _autoDownloadOverWifi = true;

  ClientUpdateStatus get status => _status;
  String get manifestPath => _manifestPath;
  String get publicKeysPath => _publicKeysPath;
  String get artifactReceiptId => _artifactReceiptId;
  bool get busy => _busy;
  bool get autoDownloadOverWifi => _autoDownloadOverWifi;

  Future<void> loadPreferences() async {
    _autoDownloadOverWifi = await _gateway.autoDownloadOverWifiEnabled();
    notifyListeners();
  }

  Future<void> setAutoDownloadOverWifi(bool enabled) async {
    await _gateway.setAutoDownloadOverWifiEnabled(enabled);
    _autoDownloadOverWifi = enabled;
    notifyListeners();
  }

  Future<void> prepareInBackground() async {
    try {
      await loadPreferences();
      await check();
      if (!_status.updateAvailable || !_autoDownloadOverWifi) return;
      if (!await _gateway.isWifiConnected()) {
        _report(
          '发现更新；连接 Wi-Fi 后将自动下载。',
          'Update available; download will start when Wi-Fi is connected.',
        );
        return;
      }
      await download();
      if (_status.phase == ClientUpdatePhase.downloaded) {
        await verify();
      }
    } catch (_) {
      // Startup update preparation is best-effort. Interactive checks still
      // report failures, while an unavailable platform service must not block
      // the rest of client initialization.
    }
  }

  Future<void> refresh({String channel = 'stable'}) async {
    if (!_begin()) return;
    _clearArtifactBinding();
    try {
      _status = await _gateway.status(
        agentService: _agentService,
        channel: channel,
      );
      _report('客户端更新状态已刷新。', 'Client update status refreshed.');
    } catch (_) {
      _status = ClientUpdateStatus(
        phase: ClientUpdatePhase.failed,
        currentVersion: _status.currentVersion,
        channel: channel,
        errorCode: 'client_update_status_failed',
      );
      _report(
        '客户端更新状态刷新失败。',
        'Client update status refresh failed.',
        errorCode: 'client_update_status_failed',
      );
    } finally {
      _end();
    }
  }

  Future<void> check({String channel = 'stable'}) async {
    if (_busy) return;
    _clearArtifactBinding();
    _begin();
    _status = _status.copyWith(
      phase: ClientUpdatePhase.checking,
      errorCode: '',
    );
    _report('正在检查已签名的客户端更新。', 'Checking for a signed client update.');
    notifyListeners();
    try {
      final remote = await _gateway.check(
        agentService: _agentService,
        channel: channel,
      );
      final checked = remote.status;
      if (checked.updateAvailable &&
          (checked.artifactReceiptId.isEmpty ||
              checked.artifactSha256.isEmpty ||
              checked.manifestSha256.isEmpty ||
              checked.targetId.isEmpty)) {
        throw StateError('client_update_check_missing_artifact_receipt');
      }
      _status = checked;
      _manifestPath = remote.manifestPath;
      _publicKeysPath = remote.publicKeysPath;
      _artifactUrl = remote.artifactUrl;
      _channel = channel.trim().isEmpty ? 'stable' : channel.trim();
      _revocationPath = '';
      _artifactReceiptId = checked.artifactReceiptId;
      _report(
        _status.updateAvailable
            ? '发现已签名更新：${_status.availableVersion}'
            : '当前已是最新已验证版本。',
        _status.updateAvailable
            ? 'Signed update available: ${_status.availableVersion}'
            : 'Already on the latest verified version.',
      );
    } catch (_) {
      _fail('client_update_check_failed');
      _report(
        '客户端更新检查失败。',
        'Client update check failed.',
        errorCode: 'client_update_check_failed',
      );
    } finally {
      _end();
    }
  }

  Future<void> download() async {
    if (_busy) return;
    if (!_hasCheckedArtifact ||
        _artifactUrl.isEmpty ||
        _status.totalBytes <= 0) {
      _report(
        '请先完成在线更新检查。',
        'Check for an online update first.',
        errorCode: 'client_update_download_invalid',
      );
      notifyListeners();
      return;
    }
    _begin();
    _status = _status.copyWith(phase: ClientUpdatePhase.downloading);
    notifyListeners();
    try {
      final downloaded = await _gateway.download(
        agentService: _agentService,
        manifestPath: _manifestPath,
        publicKeysPath: _publicKeysPath,
        artifactUrl: _artifactUrl,
        expectedBytes: _status.totalBytes,
        channel: _channel,
        revocationPath: _revocationPath,
      );
      _requireMatchingReceipt(downloaded, 'download');
      _status = downloaded;
      _artifactDownloaded = true;
      _artifactVerified = false;
      _report('更新包已暂存。', 'Update artifact staged.');
    } catch (_) {
      _artifactDownloaded = false;
      _artifactVerified = false;
      _fail('client_update_download_failed');
      _report(
        '更新包下载失败。',
        'Update artifact download failed.',
        errorCode: 'client_update_download_failed',
      );
    } finally {
      _end();
    }
  }

  Future<void> verify() async {
    if (_busy) return;
    if (!_artifactDownloaded) {
      _report(
        '请先完成更新检查与下载。',
        'Check and download an update first.',
        errorCode: 'client_update_verify_invalid',
      );
      notifyListeners();
      return;
    }
    _begin();
    _status = _status.copyWith(phase: ClientUpdatePhase.verifying);
    notifyListeners();
    try {
      final verified = await _gateway.verify(
        agentService: _agentService,
        manifestPath: _manifestPath,
        publicKeysPath: _publicKeysPath,
        channel: _channel,
        revocationPath: _revocationPath,
      );
      _requireMatchingReceipt(verified, 'verify');
      _status = verified;
      _artifactVerified = true;
      _report(
        '更新包签名与摘要校验通过。',
        'Update artifact signature and digest verified.',
      );
    } catch (_) {
      _artifactVerified = false;
      _fail('client_update_verify_failed');
      _report(
        '更新包校验失败。',
        'Update artifact verification failed.',
        errorCode: 'client_update_verify_failed',
      );
    } finally {
      _end();
    }
  }

  Future<void> apply() async {
    if (_busy) return;
    if (!_artifactVerified) {
      _report(
        '请先完成更新校验。',
        'Verify an update first.',
        errorCode: 'client_update_apply_invalid',
      );
      notifyListeners();
      return;
    }
    _begin();
    try {
      final applied = await _gateway.apply(
        agentService: _agentService,
        manifestPath: _manifestPath,
        publicKeysPath: _publicKeysPath,
        channel: _channel,
        revocationPath: _revocationPath,
      );
      _requireMatchingReceipt(applied, 'apply');
      _status = applied;
      _report(
        '更新已安装，客户端正在重新启动。',
        'Update installed; the client is restarting.',
      );
    } catch (_) {
      _fail('client_update_apply_failed');
      _report(
        '更新安装计划失败。',
        'Update install planning failed.',
        errorCode: 'client_update_apply_failed',
      );
    } finally {
      _end();
    }
  }

  bool get _hasCheckedArtifact =>
      _manifestPath.isNotEmpty &&
      _publicKeysPath.isNotEmpty &&
      _artifactReceiptId.isNotEmpty &&
      _status.updateAvailable;

  void _requireMatchingReceipt(ClientUpdateStatus next, String phase) {
    if (next.artifactReceiptId.isEmpty ||
        next.artifactReceiptId != _artifactReceiptId ||
        next.artifactSha256.isEmpty) {
      throw StateError('client_update_${phase}_receipt_mismatch');
    }
  }

  void _clearArtifactBinding() {
    _artifactReceiptId = '';
    _artifactUrl = '';
    _artifactDownloaded = false;
    _artifactVerified = false;
  }

  bool _begin() {
    if (_busy) return false;
    _busy = true;
    notifyListeners();
    return true;
  }

  void _end() {
    _busy = false;
    notifyListeners();
  }

  void _fail(String code) {
    _status = _status.copyWith(
      phase: ClientUpdatePhase.failed,
      errorCode: code,
    );
  }

  void _report(String chinese, String english, {String errorCode = ''}) {
    _onStatus(
      ClientUpdateStatusUpdate(
        chinese: chinese,
        english: english,
        errorCode: errorCode,
      ),
    );
  }
}

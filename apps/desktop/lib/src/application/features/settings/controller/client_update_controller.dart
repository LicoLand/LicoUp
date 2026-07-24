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
  String _artifactReceiptId = '';
  bool _artifactDownloaded = false;
  bool _artifactVerified = false;
  bool _busy = false;

  ClientUpdateStatus get status => _status;
  String get manifestPath => _manifestPath;
  String get publicKeysPath => _publicKeysPath;
  String get artifactReceiptId => _artifactReceiptId;
  bool get busy => _busy;

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

  Future<void> check({
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
  }) async {
    if (_busy) return;
    _clearArtifactBinding();
    if (manifestPath.trim().isEmpty || publicKeysPath.trim().isEmpty) {
      _report(
        '需要已签名的更新清单与公钥文件。',
        'A signed update manifest and public keys file are required.',
        errorCode: 'client_update_check_invalid',
      );
      notifyListeners();
      return;
    }
    _begin();
    _status = _status.copyWith(
      phase: ClientUpdatePhase.checking,
      errorCode: '',
    );
    _report('正在检查已签名的客户端更新。', 'Checking for a signed client update.');
    notifyListeners();
    try {
      final checked = await _gateway.check(
        agentService: _agentService,
        manifestPath: manifestPath,
        publicKeysPath: publicKeysPath,
        channel: channel,
        revocationPath: revocationPath,
      );
      if (checked.updateAvailable &&
          (checked.artifactReceiptId.isEmpty ||
              checked.artifactSha256.isEmpty ||
              checked.manifestSha256.isEmpty ||
              checked.targetId.isEmpty)) {
        throw StateError('client_update_check_missing_artifact_receipt');
      }
      _status = checked;
      _manifestPath = manifestPath.trim();
      _publicKeysPath = publicKeysPath.trim();
      _channel = channel.trim().isEmpty ? 'stable' : channel.trim();
      _revocationPath = revocationPath.trim();
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

  Future<void> download({required String sourcePath}) async {
    if (_busy) return;
    if (!_hasCheckedArtifact || sourcePath.trim().isEmpty) {
      _report(
        '请先完成更新检查并选择本地更新包。',
        'Check an update and select its local artifact first.',
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
        sourcePath: sourcePath,
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

  Future<void> planApply() async {
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
      final planned = await _gateway.applyDryRun(
        agentService: _agentService,
        manifestPath: _manifestPath,
        publicKeysPath: _publicKeysPath,
        channel: _channel,
        revocationPath: _revocationPath,
      );
      _requireMatchingReceipt(planned, 'apply');
      _status = planned;
      _report(
        '已生成更新安装计划（未实际执行）。',
        'Update install plan prepared (not executed).',
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

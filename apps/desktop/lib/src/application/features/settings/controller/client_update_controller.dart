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

/// Independently testable signed-update workflow for the GitHub release
/// source and the local manifest flow. The staging and state roots live under
/// the client data directory so installed clients never depend on the
/// process working directory.
final class ClientUpdateController extends ChangeNotifier {
  ClientUpdateController({
    required ClientUpdateGateway gateway,
    required AgentCommandRunner agentService,
    required ClientUpdateStatusSink onStatus,
    Future<String> Function()? dataDirectory,
  }) : _gateway = gateway,
       _agentService = agentService,
       _onStatus = onStatus,
       _dataDirectory = dataDirectory;

  final ClientUpdateGateway _gateway;
  final AgentCommandRunner _agentService;
  final ClientUpdateStatusSink _onStatus;
  final Future<String> Function()? _dataDirectory;

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
  String _source = 'github';
  String _repo = kClientUpdateGithubRepo;
  String _stagingRoot = '';
  String _stateRoot = '';
  bool _rootsResolved = false;
  bool _artifactDownloaded = false;
  bool _artifactVerified = false;
  bool _busy = false;

  ClientUpdateStatus get status => _status;
  String get manifestPath => _manifestPath;
  String get publicKeysPath => _publicKeysPath;
  String get artifactReceiptId => _artifactReceiptId;
  String get source => _source;
  String get repo => _repo;
  bool get busy => _busy;

  String get sourceAddress => clientUpdatePublicSourceAddress(
    repo: _repo,
    githubReleaseUrl: _status.githubReleaseUrl,
  );

  bool get canCheckUpdate => !_busy;
  bool get canDownloadUpdate =>
      !_busy &&
      _status.updateAvailable &&
      !_artifactDownloaded &&
      _status.phase == ClientUpdatePhase.updateAvailable;
  bool get canApplyUpdate =>
      !_busy &&
      _artifactVerified &&
      (_status.phase == ClientUpdatePhase.verified ||
          _status.phase == ClientUpdatePhase.applyPlanned);

  /// Reads the running product version from native client-update identity
  /// without treating a status failure as a user-facing check failure.
  Future<void> hydrateIdentity({String channel = 'stable'}) async {
    if (!_begin()) return;
    _channel = channel.trim().isEmpty ? 'stable' : channel.trim();
    await _resolveRoots();
    try {
      final next = await _gateway.status(
        agentService: _agentService,
        channel: _channel,
        source: 'local',
        repo: _repo,
        stateRoot: _stateRoot,
        currentVersion: _status.currentVersion,
      );
      if (next.currentVersion.isNotEmpty) {
        _status = _status.copyWith(
          currentVersion: next.currentVersion,
          channel: next.channel.isEmpty ? _status.channel : next.channel,
        );
      }
    } catch (_) {
      // Identity hydrate must not paint a failed check.
    } finally {
      _end();
    }
  }

  /// One-click GitHub release source check that uses the bundled public keys
  /// and requires no local manifest or keys files.
  Future<void> checkGithub({String repo = kClientUpdateGithubRepo}) async {
    if (_busy) return;
    _clearArtifactBinding();
    _source = 'github';
    _repo = repo.trim().isEmpty ? kClientUpdateGithubRepo : repo.trim();
    if (_status.currentVersion.isEmpty) {
      await hydrateIdentity(channel: _channel);
      if (_busy) return;
    }
    await _runCheck(
      chinese: '正在从 GitHub 发布源检查已签名的客户端更新。',
      english:
          'Checking the signed client update from the GitHub release source.',
    );
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
    _source = 'local';
    _manifestPath = manifestPath.trim();
    _publicKeysPath = publicKeysPath.trim();
    _channel = channel.trim().isEmpty ? 'stable' : channel.trim();
    _revocationPath = revocationPath.trim();
    if (_status.currentVersion.isEmpty) {
      await hydrateIdentity(channel: _channel);
      if (_busy) return;
    }
    await _runCheck(
      chinese: '正在检查已签名的客户端更新。',
      english: 'Checking for a signed client update.',
    );
  }

  Future<void> _runCheck({
    required String chinese,
    required String english,
  }) async {
    _begin();
    _status = _status.copyWith(
      phase: ClientUpdatePhase.checking,
      errorCode: '',
      updateAvailable: false,
    );
    _report(chinese, english);
    notifyListeners();
    await _resolveRoots();
    try {
      final checked = await _gateway.check(
        agentService: _agentService,
        manifestPath: _manifestPath,
        publicKeysPath: _publicKeysPath,
        channel: _channel,
        revocationPath: _revocationPath,
        source: _source,
        repo: _repo,
        stagingRoot: _stagingRoot,
        stateRoot: _stateRoot,
        currentVersion: _status.currentVersion,
      );
      if (checked.updateAvailable &&
          (checked.artifactReceiptId.isEmpty ||
              checked.artifactSha256.isEmpty ||
              checked.manifestSha256.isEmpty ||
              checked.targetId.isEmpty)) {
        throw StateError('client_update_check_missing_artifact_receipt');
      }
      _status = _adopt(checked);
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

  /// Local flow: stage an artifact from a local file, then verify it.
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
    _source = 'local';
    await _downloadStaged(sourcePath: sourcePath);
  }

  /// GitHub flow: stream the signed artifact url from the cached manifest,
  /// then verify the staged file so apply can be enabled.
  Future<void> downloadGithub() async {
    if (_busy) return;
    if (!_hasCheckedArtifact || _source != 'github') {
      _report(
        '请先从 GitHub 发布源完成更新检查。',
        'Check the GitHub release source for an update first.',
        errorCode: 'client_update_download_invalid',
      );
      notifyListeners();
      return;
    }
    await _downloadStaged(sourcePath: '');
  }

  Future<void> _downloadStaged({required String sourcePath}) async {
    _begin();
    _status = _status.copyWith(phase: ClientUpdatePhase.downloading);
    notifyListeners();
    await _resolveRoots();
    try {
      final downloaded = await _gateway.download(
        agentService: _agentService,
        manifestPath: _manifestPath,
        publicKeysPath: _publicKeysPath,
        sourcePath: sourcePath,
        channel: _channel,
        revocationPath: _revocationPath,
        source: _source,
        repo: _repo,
        stagingRoot: _stagingRoot,
        stateRoot: _stateRoot,
        currentVersion: _status.currentVersion,
      );
      _requireMatchingReceipt(downloaded, 'download');
      _status = _adopt(downloaded);
      _artifactDownloaded = true;
      _artifactVerified = false;
      await _verifyUnlocked();
      _report('更新包已下载到本地并完成校验。', 'Update artifact downloaded and verified.');
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
    try {
      await _verifyUnlocked();
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

  Future<void> _verifyUnlocked() async {
    _status = _status.copyWith(phase: ClientUpdatePhase.verifying);
    notifyListeners();
    await _resolveRoots();
    final verified = await _gateway.verify(
      agentService: _agentService,
      manifestPath: _manifestPath,
      publicKeysPath: _publicKeysPath,
      channel: _channel,
      revocationPath: _revocationPath,
      source: _source,
      repo: _repo,
      stagingRoot: _stagingRoot,
      stateRoot: _stateRoot,
      currentVersion: _status.currentVersion,
    );
    _requireMatchingReceipt(verified, 'verify');
    _status = _adopt(verified);
    _artifactVerified = true;
  }

  Future<void> planApply() async {
    await _apply(execute: false);
  }

  /// Executes the live apply through the native script and invokes
  /// `exitClient` once the applied phase confirms so the detached updater
  /// script can replace the installation and relaunch the new version.
  Future<void> applyThenExit(void Function() exitClient) async {
    final applied = await _apply(execute: true);
    if (applied && _status.phase == ClientUpdatePhase.applied) {
      exitClient();
    }
  }

  Future<bool> _apply({required bool execute}) async {
    if (_busy) return false;
    if (!_artifactVerified) {
      _report(
        '请先完成更新校验。',
        'Verify an update first.',
        errorCode: 'client_update_apply_invalid',
      );
      notifyListeners();
      return false;
    }
    _begin();
    await _resolveRoots();
    try {
      final applied = await _gateway.apply(
        agentService: _agentService,
        execute: execute,
        manifestPath: _manifestPath,
        publicKeysPath: _publicKeysPath,
        channel: _channel,
        revocationPath: _revocationPath,
        source: _source,
        repo: _repo,
        stagingRoot: _stagingRoot,
        stateRoot: _stateRoot,
        currentVersion: _status.currentVersion,
      );
      _requireMatchingReceipt(applied, 'apply');
      _status = _adopt(applied);
      _report(
        execute ? '更新安装已调度，客户端即将重启。' : '已生成更新安装计划（未实际执行）。',
        execute
            ? 'Update install scheduled; the client will restart.'
            : 'Update install plan prepared (not executed).',
      );
      return true;
    } catch (_) {
      _fail('client_update_apply_failed');
      _report(
        execute ? '更新安装失败。' : '更新安装计划失败。',
        execute ? 'Update install failed.' : 'Update install planning failed.',
        errorCode: 'client_update_apply_failed',
      );
      return false;
    } finally {
      _end();
    }
  }

  Future<void> rollback() async {
    if (_busy) return;
    if (_artifactReceiptId.isEmpty) {
      _report(
        '没有可回滚的更新安装。',
        'There is no update install to roll back.',
        errorCode: 'client_update_rollback_invalid',
      );
      notifyListeners();
      return;
    }
    _begin();
    await _resolveRoots();
    try {
      final rolledBack = await _gateway.rollback(
        agentService: _agentService,
        manifestPath: _manifestPath,
        publicKeysPath: _publicKeysPath,
        channel: _channel,
        revocationPath: _revocationPath,
        source: _source,
        repo: _repo,
        stagingRoot: _stagingRoot,
        stateRoot: _stateRoot,
        currentVersion: _status.currentVersion,
      );
      _requireMatchingReceipt(rolledBack, 'rollback');
      _status = _adopt(rolledBack);
      _report('已调度回滚，客户端即将重启。', 'Rollback scheduled; the client will restart.');
    } catch (_) {
      _fail('client_update_rollback_failed');
      _report(
        '更新回滚失败。',
        'Update rollback failed.',
        errorCode: 'client_update_rollback_failed',
      );
    } finally {
      _end();
    }
  }

  bool get _hasCheckedArtifact =>
      (_manifestPath.isNotEmpty || _source == 'github') &&
      _artifactReceiptId.isNotEmpty &&
      _status.updateAvailable;

  ClientUpdateStatus _adopt(ClientUpdateStatus next) {
    if (next.currentVersion.isNotEmpty) return next;
    return next.copyWith(currentVersion: _status.currentVersion);
  }

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

  Future<void> _resolveRoots() async {
    if (_rootsResolved) return;
    final resolver = _dataDirectory;
    if (resolver != null) {
      final dataDir = await resolver();
      _stagingRoot = '$dataDir/client-update-staging';
      _stateRoot = '$dataDir/client-update-state';
    }
    _rootsResolved = true;
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
      updateAvailable: false,
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

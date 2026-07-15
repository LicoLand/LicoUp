part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientUpdateActions on ClientController {
  Future<void> refreshClientUpdateStatus({String channel = 'stable'}) async {
    if (isClientUpdateBusy) {
      return;
    }
    isClientUpdateBusy = true;
    lastError = '';
    _notifyStateChanged();
    try {
      clientUpdateStatus = await clientUpdateService.status(
        agentService: agentService,
        channel: channel,
      );
      _setLocalizedStatusMessage(
        '客户端更新状态已刷新。',
        'Client update status refreshed.',
      );
      statusCaption = 'Update';
    } catch (error) {
      debugPrint('Failed to refresh client update status: $error');
      lastError = 'client_update_status_failed';
      clientUpdateStatus = ClientUpdateStatus(
        phase: ClientUpdatePhase.failed,
        currentVersion: clientUpdateStatus.currentVersion,
        channel: channel,
        errorCode: 'client_update_status_failed',
      );
      _setLocalizedStatusMessage(
        '客户端更新状态刷新失败。',
        'Client update status refresh failed.',
      );
      statusCaption = 'Update';
    } finally {
      isClientUpdateBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> checkClientUpdate({
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
  }) async {
    if (isClientUpdateBusy) {
      return;
    }
    if (manifestPath.trim().isEmpty || publicKeysPath.trim().isEmpty) {
      lastError = 'client_update_check_invalid';
      _setLocalizedStatusMessage(
        '需要已签名的更新清单与公钥文件。',
        'A signed update manifest and public keys file are required.',
      );
      statusCaption = 'Update';
      _notifyStateChanged();
      return;
    }
    isClientUpdateBusy = true;
    lastError = '';
    clientUpdateStatus = clientUpdateStatus.copyWith(
      phase: ClientUpdatePhase.checking,
      errorCode: '',
    );
    _setLocalizedStatusMessage(
      '正在检查已签名的客户端更新。',
      'Checking for a signed client update.',
    );
    statusCaption = 'Update';
    _notifyStateChanged();
    try {
      clientUpdateStatus = await clientUpdateService.check(
        agentService: agentService,
        manifestPath: manifestPath,
        publicKeysPath: publicKeysPath,
        channel: channel,
        revocationPath: revocationPath,
      );
      clientUpdateManifestPath = manifestPath.trim();
      clientUpdatePublicKeysPath = publicKeysPath.trim();
      _setLocalizedStatusMessage(
        clientUpdateStatus.updateAvailable
            ? '发现已签名更新：${clientUpdateStatus.availableVersion}'
            : '当前已是最新已验证版本。',
        clientUpdateStatus.updateAvailable
            ? 'Signed update available: ${clientUpdateStatus.availableVersion}'
            : 'Already on the latest verified version.',
      );
      statusCaption = 'Update';
    } catch (error) {
      debugPrint('Failed to check client update: $error');
      lastError = 'client_update_check_failed';
      clientUpdateStatus = clientUpdateStatus.copyWith(
        phase: ClientUpdatePhase.failed,
        errorCode: 'client_update_check_failed',
      );
      _setLocalizedStatusMessage('客户端更新检查失败。', 'Client update check failed.');
      statusCaption = 'Update';
    } finally {
      isClientUpdateBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> downloadClientUpdateArtifact({
    required String sourcePath,
    int size = 0,
  }) async {
    if (isClientUpdateBusy) {
      return;
    }
    isClientUpdateBusy = true;
    lastError = '';
    clientUpdateStatus = clientUpdateStatus.copyWith(
      phase: ClientUpdatePhase.downloading,
    );
    _notifyStateChanged();
    try {
      clientUpdateStatus = await clientUpdateService.download(
        agentService: agentService,
        sourcePath: sourcePath,
        size: size,
      );
      clientUpdateStagedFileName = sourcePath
          .split(RegExp(r'[/\\]'))
          .last
          .trim();
      _setLocalizedStatusMessage('更新包已暂存。', 'Update artifact staged.');
      statusCaption = 'Update';
    } catch (error) {
      debugPrint('Failed to download client update: $error');
      lastError = 'client_update_download_failed';
      clientUpdateStatus = clientUpdateStatus.copyWith(
        phase: ClientUpdatePhase.failed,
        errorCode: 'client_update_download_failed',
      );
      _setLocalizedStatusMessage(
        '更新包下载失败。',
        'Update artifact download failed.',
      );
      statusCaption = 'Update';
    } finally {
      isClientUpdateBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> verifyClientUpdateArtifact({String sha256 = ''}) async {
    if (isClientUpdateBusy) {
      return;
    }
    if (clientUpdateManifestPath.isEmpty ||
        clientUpdatePublicKeysPath.isEmpty ||
        clientUpdateStagedFileName.isEmpty) {
      lastError = 'client_update_verify_invalid';
      _setLocalizedStatusMessage(
        '请先完成更新检查与下载。',
        'Check and download an update first.',
      );
      statusCaption = 'Update';
      _notifyStateChanged();
      return;
    }
    isClientUpdateBusy = true;
    lastError = '';
    clientUpdateStatus = clientUpdateStatus.copyWith(
      phase: ClientUpdatePhase.verifying,
    );
    _notifyStateChanged();
    try {
      clientUpdateStatus = await clientUpdateService.verify(
        agentService: agentService,
        manifestPath: clientUpdateManifestPath,
        publicKeysPath: clientUpdatePublicKeysPath,
        stagedFileName: clientUpdateStagedFileName,
        sha256: sha256,
      );
      _setLocalizedStatusMessage(
        '更新包签名与摘要校验通过。',
        'Update artifact signature and digest verified.',
      );
      statusCaption = 'Update';
    } catch (error) {
      debugPrint('Failed to verify client update: $error');
      lastError = 'client_update_verify_failed';
      clientUpdateStatus = clientUpdateStatus.copyWith(
        phase: ClientUpdatePhase.failed,
        errorCode: 'client_update_verify_failed',
      );
      _setLocalizedStatusMessage(
        '更新包校验失败。',
        'Update artifact verification failed.',
      );
      statusCaption = 'Update';
    } finally {
      isClientUpdateBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> planClientUpdateApply() async {
    if (isClientUpdateBusy) {
      return;
    }
    if (clientUpdateManifestPath.isEmpty ||
        clientUpdatePublicKeysPath.isEmpty ||
        clientUpdateStagedFileName.isEmpty) {
      lastError = 'client_update_apply_invalid';
      _setLocalizedStatusMessage('请先完成更新校验。', 'Verify an update first.');
      statusCaption = 'Update';
      _notifyStateChanged();
      return;
    }
    isClientUpdateBusy = true;
    lastError = '';
    _notifyStateChanged();
    try {
      clientUpdateStatus = await clientUpdateService.applyDryRun(
        agentService: agentService,
        manifestPath: clientUpdateManifestPath,
        publicKeysPath: clientUpdatePublicKeysPath,
        stagedFileName: clientUpdateStagedFileName,
      );
      _setLocalizedStatusMessage(
        '已生成更新安装计划（未实际执行）。',
        'Update install plan prepared (not executed).',
      );
      statusCaption = 'Update';
    } catch (error) {
      debugPrint('Failed to plan client update apply: $error');
      lastError = 'client_update_apply_failed';
      clientUpdateStatus = clientUpdateStatus.copyWith(
        phase: ClientUpdatePhase.failed,
        errorCode: 'client_update_apply_failed',
      );
      _setLocalizedStatusMessage(
        '更新安装计划失败。',
        'Update install planning failed.',
      );
      statusCaption = 'Update';
    } finally {
      isClientUpdateBusy = false;
      _notifyStateChanged();
    }
  }
}

part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientMobileRelayActions on ClientController {
  MobilePairingPresentation? get mobilePairingPresentation {
    final result = mobileRelayActionResult;
    final invite = _pairingInvite(result);
    final pairingCode = _pairingCode(result, invite);
    final inviteText = invite == null
        ? ''
        : _encodeMobilePairingInviteLink(invite);
    final presentation = MobilePairingPresentation(
      pairingCode: pairingCode,
      inviteText: inviteText,
    );
    return presentation.isEmpty ? null : presentation;
  }

  Future<void> configureMobileRelayGateway({
    required bool useCustomGateway,
    required String customGatewayUrl,
  }) async {
    if (isMobileRelayBusy) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    _setLocalizedStatusMessage(
      '正在保存移动中转网关配置。',
      'Saving the mobile relay gateway configuration.',
    );
    statusCaption = 'Mobile relay';
    _notifyStateChanged();
    try {
      mobileRelayConfig = await mobileRelayService.configureGateway(
        agentService: agentService,
        useCustomGateway: useCustomGateway,
        customGatewayUrl: customGatewayUrl,
      );
      _setLocalizedStatusMessage(
        '已保存移动中转网关配置。',
        'Mobile relay gateway configuration saved.',
      );
      statusCaption = 'Mobile relay';
    } catch (error) {
      debugPrint('Failed to configure mobile relay gateway: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '移动中转网关配置失败。',
        'Failed to configure the mobile relay gateway.',
      );
      statusCaption = 'Mobile relay';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> createMobilePairing() async {
    if (isMobileRelayBusy) {
      return;
    }
    if (_mobileClientRuntimePlatform) {
      _setLocalizedStatusMessage(
        '手机端不能创建桌面配对码。',
        'A desktop pairing code cannot be created on mobile.',
      );
      statusCaption = 'Mobile relay';
      _notifyStateChanged();
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    mobileRelayActionResult = null;
    mobileRelayConfig = mobileRelayConfig.copyWith(
      lastPairingCode: '',
      lastPairingExpiresAt: '',
    );
    _setLocalizedStatusMessage('正在创建手机配对码。', 'Creating a phone pairing code.');
    statusCaption = 'Mobile relay';
    _notifyStateChanged();
    try {
      mobileRelayActionResult = await mobileRelayService.createPairing(
        agentService: agentService,
      );
      mobileRelayConfig = await mobileRelayService.loadConfig(
        agentService: agentService,
      );
      syncMobileAgentAccountsWithDesktopRelay();
      await syncMobileProviderCredentialsFromDesktopRelay(silent: true);
      if (scannedTargets.isEmpty) {
        scannedTargets = await agentService.scanTargets();
        _selectDefaultConversationAgent();
      }
      startMobileRelayPolling();
      _setLocalizedStatusMessage(
        '已创建一次性手机配对码。',
        'One-time phone pairing code created.',
      );
      statusCaption = 'Mobile relay';
    } catch (error) {
      debugPrint('Failed to create mobile pairing: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '手机配对码创建失败。',
        'Failed to create the phone pairing code.',
      );
      statusCaption = 'Mobile relay';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  void dismissMobilePairingPresentation() {
    final hadPresentation =
        mobileRelayActionResult != null ||
        mobileRelayConfig.lastPairingCode.isNotEmpty ||
        mobileRelayConfig.lastPairingExpiresAt.isNotEmpty;
    mobileRelayActionResult = null;
    mobileRelayConfig = mobileRelayConfig.copyWith(
      lastPairingCode: '',
      lastPairingExpiresAt: '',
    );
    if (hadPresentation) {
      _notifyStateChanged();
    }
  }

  Future<bool> copyMobilePairingCode(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    try {
      await clientClipboardService.writeText(trimmed);
      _setLocalizedStatusMessage('配对码已复制。', 'Pairing code copied.');
      statusCaption = 'Mobile relay';
      return true;
    } catch (error) {
      debugPrint('Failed to copy mobile pairing code: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '配对码复制失败。',
        'Failed to copy the pairing code.',
      );
      statusCaption = 'Mobile relay';
      return false;
    } finally {
      _notifyStateChanged();
    }
  }

  Map<String, dynamic>? _pairingInvite(Map<String, dynamic>? result) {
    final invite = result?['mobileRelayPairingInvite'];
    if (invite is Map) {
      return Map<String, dynamic>.from(invite);
    }
    return null;
  }

  String _pairingCode(
    Map<String, dynamic>? result,
    Map<String, dynamic>? invite,
  ) {
    final resultCode = result?['pairingCode']?.toString().trim() ?? '';
    if (resultCode.isNotEmpty) {
      return resultCode;
    }
    return invite?['pairingCode']?.toString().trim() ?? '';
  }

  Future<void> refreshMobilePairingStatus() async {
    if (isMobileRelayBusy || !mobileRelayConfig.hasPairing) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    _setLocalizedStatusMessage(
      '正在刷新手机配对状态。',
      'Refreshing phone pairing status.',
    );
    statusCaption = 'Mobile relay';
    _notifyStateChanged();
    try {
      mobileRelayActionResult = await mobileRelayService.refreshPairingStatus(
        agentService: agentService,
      );
      mobileRelayConfig = await mobileRelayService.loadConfig(
        agentService: agentService,
      );
      syncMobileAgentAccountsWithDesktopRelay();
      await syncMobileProviderCredentialsFromDesktopRelay(silent: true);
      _setLocalizedStatusMessage(
        mobileRelayConfig.paired ? '手机已配对。' : '等待手机配对。',
        mobileRelayConfig.paired
            ? 'Phone paired.'
            : 'Waiting for phone pairing.',
      );
      statusCaption = 'Mobile relay';
    } catch (error) {
      debugPrint('Failed to refresh mobile pairing status: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '手机配对状态刷新失败。',
        'Failed to refresh phone pairing status.',
      );
      statusCaption = 'Mobile relay';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> claimMobilePairingInvite(String inviteText) async {
    if (isMobileRelayBusy) {
      return;
    }
    final trimmed = inviteText.trim();
    if (trimmed.isEmpty) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    _setLocalizedStatusMessage('正在配对设备。', 'Pairing the device.');
    statusCaption = 'Mobile relay';
    _notifyStateChanged();
    try {
      final invite = _decodeMobilePairingInvite(trimmed);
      mobileRelayActionResult = await mobileRelayService.claimPairing(
        agentService: agentService,
        invite: invite,
      );
      mobileRelayConfig = await mobileRelayService.loadConfig(
        agentService: agentService,
      );
      final pairingStatus = await _refreshMobilePairingStatusForProviderSync();
      syncMobileAgentAccountsWithDesktopRelay();
      await syncMobileProviderCredentialsFromDesktopRelay(silent: true);
      scannedTargets = await _scanMobileRelayTargets(
        pairingStatus: pairingStatus,
      );
      _selectDefaultConversationAgent();
      _setLocalizedStatusMessage('设备已配对。', 'Device paired.');
      statusCaption = 'Mobile relay';
    } catch (error) {
      debugPrint('Failed to claim mobile pairing invite: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage('设备配对失败。', 'Failed to pair the device.');
      statusCaption = 'Mobile relay';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> selectMobileRelayDevice(String deviceId) async {
    final trimmed = deviceId.trim();
    if (trimmed.isEmpty || isMobileRelayBusy) {
      return;
    }
    final devices = mobileRelayConfig.deviceTabs;
    MobileRelayPairedDevice? selected;
    for (final device in devices) {
      if (device.id == trimmed || device.pairingId == trimmed) {
        selected = device;
        break;
      }
    }
    if (selected == null || !selected.isUsable) {
      return;
    }
    if (selected.pairingId == mobileRelayConfig.pairingId) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    _setLocalizedStatusMessage(
      '正在切换到 ${selected.label}。',
      'Switching to ${selected.label}.',
    );
    statusCaption = 'Mobile relay';
    _notifyStateChanged();
    try {
      mobileRelayConfig = mobileRelayConfig.copyWith(
        pcClientId: selected.id,
        pcClientName: selected.label,
        pairingId: selected.pairingId,
        mobileToken: selected.mobileToken,
        mobileTokenPresent: true,
        paired: true,
        authorizedProviders: selected.authorizedProviders,
      );
      await mobileRelayService.saveConfig(
        agentService: agentService,
        config: mobileRelayConfig,
      );
      syncMobileAgentAccountsWithDesktopRelay();
      await syncMobileProviderCredentialsFromDesktopRelay(silent: true);
      scannedTargets = await _scanMobileRelayTargets();
      _selectDefaultConversationAgent();
      _setLocalizedStatusMessage(
        '已切换到 ${selected.label}。',
        'Switched to ${selected.label}.',
      );
      statusCaption = 'Mobile relay';
    } catch (error) {
      debugPrint('Failed to switch mobile relay device: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '切换配对电脑失败。',
        'Failed to switch the paired computer.',
      );
      statusCaption = 'Mobile relay';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  Future<Map<String, dynamic>?>
  _refreshMobilePairingStatusForProviderSync() async {
    if (!_mobileClientRuntimePlatform || !mobileRelayConfig.hasPairing) {
      return null;
    }
    try {
      final status = await mobileRelayService.refreshPairingStatus(
        agentService: agentService,
      );
      mobileRelayConfig = await mobileRelayService.loadConfig(
        agentService: agentService,
      );
      syncMobileAgentAccountsWithDesktopRelay();
      return status;
    } catch (error) {
      debugPrint('Failed to refresh mobile pairing providers: $error');
      return null;
    }
  }
}

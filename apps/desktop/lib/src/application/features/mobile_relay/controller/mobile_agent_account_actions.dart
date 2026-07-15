part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientMobileAgentAccountActions on ClientController {
  void syncMobileAgentAccountsWithDesktopRelay() {
    mobileAgentAccounts = mobileAgentAccountsWithDesktopRelay(
      mobileAgentAccounts,
      mobileRelayConfig,
    );
  }

  Future<void> addMobileAgentProvider(String providerId) async {
    final provider = mobileAgentProviderFor(providerId);
    lastError = '';
    _setLocalizedStatusMessage(
      '正在添加 ${provider.label}。',
      'Adding ${provider.label}.',
    );
    statusCaption = 'Mobile agents';
    _notifyStateChanged();
    try {
      mobileAgentAccounts = await mobileAgentAccountService.addProvider(
        portableData,
        provider.id,
      );
      syncMobileAgentAccountsWithDesktopRelay();
      _setLocalizedStatusMessage(
        '已添加 ${provider.label}，等待授权。',
        '${provider.label} added; authorization is pending.',
      );
      statusCaption = 'Mobile agents';
    } catch (error) {
      debugPrint('Failed to add mobile agent provider: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '${provider.label} 添加失败。',
        'Failed to add ${provider.label}.',
      );
      statusCaption = 'Mobile agents';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> setActiveMobileAgentAccount(String accountId) async {
    final resolved = accountId.trim();
    if (resolved.isEmpty) {
      return;
    }
    lastError = '';
    try {
      mobileAgentAccounts = await mobileAgentAccountService.setActiveAccount(
        portableData,
        resolved,
      );
      syncMobileAgentAccountsWithDesktopRelay();
      _setLocalizedStatusMessage('已切换当前账号。', 'Switched the active account.');
      statusCaption = 'Mobile agents';
    } catch (error) {
      debugPrint('Failed to set active mobile agent account: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage('切换账号失败。', 'Failed to switch the account.');
      statusCaption = 'Mobile agents';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> renameMobileAgentAccount({
    required String accountId,
    required String label,
  }) async {
    final resolved = accountId.trim();
    final nextLabel = label.trim();
    if (resolved.isEmpty || nextLabel.isEmpty) {
      return;
    }
    lastError = '';
    try {
      mobileAgentAccounts = await mobileAgentAccountService.renameAccount(
        portableData,
        resolved,
        nextLabel,
      );
      syncMobileAgentAccountsWithDesktopRelay();
      _setLocalizedStatusMessage('已重命名账号。', 'Account renamed.');
      statusCaption = 'Mobile agents';
    } catch (error) {
      debugPrint('Failed to rename mobile agent account: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage('重命名账号失败。', 'Failed to rename the account.');
      statusCaption = 'Mobile agents';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> updateMobileAgentAssistantGrants({
    required String accountId,
    required MobileAgentAssistantGrants grants,
  }) async {
    final resolved = accountId.trim();
    if (resolved.isEmpty) {
      return;
    }
    lastError = '';
    try {
      mobileAgentAccounts = await mobileAgentAccountService
          .updateAssistantGrants(portableData, resolved, grants);
      syncMobileAgentAccountsWithDesktopRelay();
      _setLocalizedStatusMessage('已更新助手授权。', 'Assistant grants updated.');
      statusCaption = 'Mobile agents';
    } catch (error) {
      debugPrint('Failed to update mobile agent assistant grants: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '助手授权更新失败。',
        'Failed to update assistant grants.',
      );
      statusCaption = 'Mobile agents';
    } finally {
      _notifyStateChanged();
    }
  }

  /// Rejects phone-assistant local-info or accessibility actions unless the
  /// selected account has the matching grant enabled.
  bool guardMobileAgentAssistantAction({
    required String accountId,
    required String action,
  }) {
    final resolved = accountId.trim();
    final normalizedAction = action.trim().toLowerCase();
    MobileAgentAccount? account;
    for (final candidate in mobileAgentAccounts) {
      if (candidate.id == resolved) {
        account = candidate;
        break;
      }
    }
    if (account == null) {
      lastError = '账号不存在，无法执行助手操作。';
      _setLocalizedStatusMessage(
        lastError,
        'The account does not exist for this assistant action.',
      );
      statusCaption = 'Mobile agents';
      _notifyStateChanged();
      return false;
    }
    if (!account.active) {
      lastError = '只能由当前选中的账号执行助手操作。';
      _setLocalizedStatusMessage(
        lastError,
        'Only the currently selected account may perform this assistant action.',
      );
      statusCaption = 'Mobile agents';
      _notifyStateChanged();
      return false;
    }
    final grants = account.assistantGrants;
    final allowed = switch (normalizedAction) {
      'local-info' || 'local_info' || 'device-info' => grants.localInfo,
      'accessibility' || 'a11y' => grants.accessibility,
      'file-context' || 'file_context' => grants.fileContext,
      'clipboard-context' || 'clipboard_context' => grants.clipboardContext,
      'notification-context' ||
      'notification_context' => grants.notificationContext,
      _ => false,
    };
    if (!allowed) {
      lastError = '当前账号未授权该助手能力。';
      _setLocalizedStatusMessage(
        lastError,
        'The selected account has not granted this assistant capability.',
      );
      statusCaption = 'Mobile agents';
      _notifyStateChanged();
      return false;
    }
    return true;
  }

  Future<void> deleteMobileAgentAccounts(Iterable<String> accountIds) async {
    final ids = accountIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) {
      return;
    }
    final deletableAccounts = mobileAgentAccounts
        .where(
          (account) => ids.contains(account.id) && !account.usesDesktopRelay,
        )
        .toList(growable: false);
    if (deletableAccounts.isEmpty) {
      return;
    }
    lastError = '';
    _setLocalizedStatusMessage('正在删除手机端供应商。', 'Removing the mobile provider.');
    statusCaption = 'Mobile agents';
    _notifyStateChanged();
    try {
      for (final account in deletableAccounts) {
        if (!account.credentialPresent) {
          continue;
        }
        final deleted = await mobileRelayService.deleteMobileProviderCredential(
          agentService: agentService,
          providerId: account.providerId,
          mobileAccountId: account.id,
        );
        if (deleted['ok'] != true || deleted['deleted'] != true) {
          throw StateError(
            (deleted['message'] ??
                    deleted['status'] ??
                    'credential delete failed')
                .toString(),
          );
        }
      }
      final deletedIds = deletableAccounts.map((account) => account.id).toSet();
      mobileAgentAccounts = await mobileAgentAccountService.removeAccounts(
        portableData,
        deletedIds,
      );
      final deletedEntryIds = {for (final id in deletedIds) 'account:$id'};
      if (deletedEntryIds.isNotEmpty) {
        mobileHomeLayout = mobileHomeLayout.copyWith(
          order: [
            for (final entryId in mobileHomeLayout.order)
              if (!deletedEntryIds.contains(entryId)) entryId,
          ],
          pinnedEntryIds: {
            for (final entryId in mobileHomeLayout.pinnedEntryIds)
              if (!deletedEntryIds.contains(entryId)) entryId,
          },
        );
        await mobileHomeLayoutService.save(portableData, mobileHomeLayout);
      }
      syncMobileAgentAccountsWithDesktopRelay();
      _setLocalizedStatusMessage('已删除手机端供应商。', 'Mobile provider removed.');
      statusCaption = 'Mobile agents';
    } catch (error) {
      debugPrint('Failed to delete mobile agent accounts: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '手机端供应商删除失败。',
        'Failed to remove the mobile provider.',
      );
      statusCaption = 'Mobile agents';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> configureMobileAgentApiKey({
    required String providerId,
    required String apiKey,
    String mobileAccountId = '',
  }) async {
    final provider = mobileAgentProviderFor(providerId);
    final trimmed = apiKey.trim();
    if (trimmed.isEmpty) {
      return;
    }
    lastError = '';
    _setLocalizedStatusMessage(
      '正在保存 ${provider.label} API Key。',
      'Saving the ${provider.label} API key.',
    );
    statusCaption = 'Mobile agents';
    _notifyStateChanged();
    try {
      final resolvedAccountId = await mobileAgentAccountService
          .resolveWritableAccountId(
            portableData,
            provider.id,
            accountId: mobileAccountId,
          );
      if (provider.authKind == MobileAgentAuthKind.apiKey) {
        final saved = await mobileRelayService.saveMobileProviderApiKey(
          agentService: agentService,
          providerId: provider.id,
          mobileAccountId: resolvedAccountId,
          apiKey: trimmed,
        );
        if (saved['ok'] == false) {
          throw StateError(
            (saved['message'] ?? saved['status'] ?? 'API Key save failed')
                .toString(),
          );
        }
      }
      mobileAgentAccounts = await mobileAgentAccountService
          .configureApiCredential(
            portableData,
            provider.id,
            trimmed,
            accountId: resolvedAccountId,
          );
      syncMobileAgentAccountsWithDesktopRelay();
      _setLocalizedStatusMessage(
        '${provider.label} API Key 已配置。',
        '${provider.label} API key configured.',
      );
      statusCaption = 'Mobile agents';
    } catch (error) {
      debugPrint('Failed to configure mobile agent API key: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '${provider.label} API Key 配置失败。',
        'Failed to configure the ${provider.label} API key.',
      );
      statusCaption = 'Mobile agents';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> authorizeMobileAgentOAuth(
    String providerId, {
    String mobileAccountId = '',
  }) async {
    final provider = mobileAgentProviderFor(providerId);
    if (!_mobileAgentProviderSupportsLocalOAuthLogin(provider)) {
      lastError =
          '${provider.label} 当前不支持手机端本地网页授权，请从配对电脑同步 OAuth 授权或使用 API Key。';
      _setLocalizedStatusMessage(
        lastError,
        '${provider.label} does not currently support local web authorization on mobile. Sync OAuth authorization from the paired computer or use an API key.',
      );
      statusCaption = 'Mobile agents';
      _notifyStateChanged();
      return;
    }
    final attempt = ++_mobileAgentOAuthAttempt;
    lastError = '';
    _setLocalizedStatusMessage(
      '正在打开 ${provider.label} OAuth 授权。',
      'Opening ${provider.label} OAuth authorization.',
    );
    statusCaption = 'Mobile agents';
    _notifyStateChanged();
    try {
      final resolvedAccountId = await mobileAgentAccountService
          .resolveWritableAccountId(
            portableData,
            provider.id,
            accountId: mobileAccountId,
          );
      _showMobileAgentOAuthAuthorizationWaiting(provider.id, resolvedAccountId);
      final result = await mobileRelayService.loginMobileProviderOAuth(
        agentService: agentService,
        providerId: provider.id,
        mobileAccountId: resolvedAccountId,
      );
      if (attempt != _mobileAgentOAuthAttempt) {
        return;
      }
      if (result['ok'] == false) {
        throw StateError(
          (result['message'] ?? result['status'] ?? 'OAuth login failed')
              .toString(),
        );
      }
      final completedAccountId =
          (result['mobileAccountId'] ??
                  result['accountId'] ??
                  resolvedAccountId)
              .toString()
              .trim();
      await _completeMobileAgentOAuthAuthorizationIfConversationReady(
        provider: provider,
        mobileAccountId: completedAccountId.isEmpty
            ? resolvedAccountId
            : completedAccountId,
        credentialHint: (result['credentialHint'] ?? 'OAuth').toString(),
      );
    } catch (error) {
      if (attempt != _mobileAgentOAuthAttempt) {
        return;
      }
      debugPrint('Failed to authorize mobile agent OAuth: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '${provider.label} OAuth 授权失败。',
        '${provider.label} OAuth authorization failed.',
      );
      statusCaption = 'Mobile agents';
    } finally {
      if (attempt == _mobileAgentOAuthAttempt) {
        _notifyStateChanged();
      }
    }
  }

  Future<void> completeMobileAgentOAuthCallback(
    String providerId,
    String callbackUrl, {
    String mobileAccountId = '',
  }) async {
    final provider = mobileAgentProviderFor(providerId);
    if (!_mobileAgentProviderSupportsLocalOAuthLogin(provider)) {
      lastError =
          '${provider.label} 当前不支持手机端本地网页授权，请从配对电脑同步 OAuth 授权或使用 API Key。';
      _setLocalizedStatusMessage(
        lastError,
        '${provider.label} does not currently support local web authorization on mobile. Sync OAuth authorization from the paired computer or use an API key.',
      );
      statusCaption = 'Mobile agents';
      _notifyStateChanged();
      return;
    }
    final attempt = ++_mobileAgentOAuthAttempt;
    lastError = '';
    _setLocalizedStatusMessage(
      '正在完成 ${provider.label} OAuth 回调。',
      'Completing the ${provider.label} OAuth callback.',
    );
    statusCaption = 'Mobile agents';
    _notifyStateChanged();
    try {
      final result = await mobileRelayService
          .completeMobileProviderOAuthCallback(
            agentService: agentService,
            providerId: provider.id,
            mobileAccountId: mobileAccountId,
            callbackUrl: callbackUrl,
          );
      if (attempt != _mobileAgentOAuthAttempt) {
        return;
      }
      if (result['ok'] == false) {
        throw StateError(
          (result['message'] ?? result['status'] ?? 'OAuth callback failed')
              .toString(),
        );
      }
      final completedAccountId =
          (result['mobileAccountId'] ?? result['accountId'] ?? mobileAccountId)
              .toString()
              .trim();
      await _completeMobileAgentOAuthAuthorizationIfConversationReady(
        provider: provider,
        mobileAccountId: completedAccountId.isEmpty
            ? mobileAccountId
            : completedAccountId,
        credentialHint: (result['credentialHint'] ?? 'OAuth').toString(),
      );
    } catch (error) {
      if (attempt != _mobileAgentOAuthAttempt) {
        return;
      }
      debugPrint('Failed to complete mobile agent OAuth callback: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '${provider.label} OAuth 回调失败。',
        '${provider.label} OAuth callback failed.',
      );
      statusCaption = 'Mobile agents';
    } finally {
      if (attempt == _mobileAgentOAuthAttempt) {
        _notifyStateChanged();
      }
    }
  }

  Future<void> completeMobileAgentOAuthCallbackFromClipboard(
    String providerId, {
    String mobileAccountId = '',
  }) async {
    String callbackUrl;
    try {
      callbackUrl = await clientClipboardService.readText();
    } catch (error) {
      debugPrint(
        'Failed to read mobile agent OAuth callback clipboard: $error',
      );
      lastError = error.toString();
      _setLocalizedStatusMessage(
        'OAuth 回调读取失败。',
        'Failed to read the OAuth callback.',
      );
      statusCaption = 'Mobile agents';
      _notifyStateChanged();
      return;
    }
    await completeMobileAgentOAuthCallback(
      providerId,
      callbackUrl,
      mobileAccountId: mobileAccountId,
    );
  }

  Future<void> refreshMobileAgentAccountStatus(
    MobileAgentAccount requestedAccount,
  ) async {
    MobileAgentAccount? account;
    for (final candidate in mobileAgentAccounts) {
      if (candidate.id == requestedAccount.id) {
        account = candidate;
        break;
      }
    }
    if (account == null) {
      lastError = '账号不存在，无法刷新状态。';
      _setLocalizedStatusMessage(
        lastError,
        'The account no longer exists, so its status cannot be refreshed.',
      );
      statusCaption = 'Mobile agents';
      _notifyStateChanged();
      return;
    }
    if (account.usesDesktopRelay) {
      await refreshMobilePairingStatus();
      return;
    }
    lastError = '';
    _setLocalizedStatusMessage('正在刷新账号状态。', 'Refreshing account status.');
    statusCaption = 'Mobile agents';
    _notifyStateChanged();
    try {
      final usesOAuth = _mobileProviderAccountUsesOAuthCredential(account);
      final result = usesOAuth
          ? await mobileRelayService.mobileProviderOAuthStatus(
              agentService: agentService,
              providerId: account.providerId,
              mobileAccountId: account.id,
            )
          : await mobileRelayService.mobileProviderCredentialStatus(
              agentService: agentService,
              providerId: account.providerId,
              mobileAccountId: account.id,
            );
      if (result['ok'] != true) {
        throw StateError(
          (result['message'] ?? result['status'] ?? 'credential status failed')
              .toString(),
        );
      }
      final credentialPresent = result['credentialPresent'] == true;
      if (credentialPresent) {
        final hint = (result['credentialHint'] ?? account.credentialHint)
            .toString();
        mobileAgentAccounts = usesOAuth
            ? await mobileAgentAccountService.markOAuthCredentialPresent(
                portableData,
                account.providerId,
                accountId: account.id,
                label: account.label,
                credentialHint: hint,
                authSource: account.authSource,
                relayDeviceLabel: account.relayDeviceLabel,
                relayProfileId: account.relayProfileId,
                oauth: account.oauth,
              )
            : await mobileAgentAccountService.markApiCredentialPresent(
                portableData,
                account.providerId,
                accountId: account.id,
                label: account.label,
                credentialHint: hint,
                authSource: account.authSource,
                relayDeviceLabel: account.relayDeviceLabel,
                relayProfileId: account.relayProfileId,
              );
      } else {
        mobileAgentAccounts = await mobileAgentAccountService
            .markAuthorizationRequired(
              portableData,
              account.id,
              credentialHint: usesOAuth ? 'OAuth' : '',
            );
      }
      syncMobileAgentAccountsWithDesktopRelay();
      _setLocalizedStatusMessage(
        credentialPresent ? '账号状态已刷新。' : '账号需要重新授权。',
        credentialPresent
            ? 'Account status refreshed.'
            : 'The account requires authorization.',
      );
      statusCaption = 'Mobile agents';
    } catch (error) {
      debugPrint('Failed to refresh mobile agent account status: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '账号状态刷新失败。',
        'Failed to refresh account status.',
      );
      statusCaption = 'Mobile agents';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> refreshMobileProviderOAuthCredentials({
    bool silent = false,
  }) async {
    final accounts = mobileAgentAccounts
        .where(
          (account) =>
              !account.usesDesktopRelay &&
              _mobileProviderAccountUsesOAuthCredential(account) &&
              account.provider.supportsLocalOAuthLogin,
        )
        .toList(growable: false);
    if (accounts.isEmpty) {
      return;
    }
    for (final account in accounts) {
      final providerId = account.providerId;
      final provider = account.provider;
      try {
        final result = await mobileRelayService.mobileProviderOAuthStatus(
          agentService: agentService,
          providerId: providerId,
          mobileAccountId: account.id,
        );
        if (result['ok'] == true && result['credentialPresent'] == true) {
          await _completeMobileAgentOAuthAuthorizationIfConversationReady(
            provider: provider,
            mobileAccountId: account.id,
            credentialHint: (result['credentialHint'] ?? 'OAuth').toString(),
            showSuccessPrompt: false,
          );
        } else if (result['ok'] == true &&
            result['credentialPresent'] == false) {
          mobileAgentAccounts = await mobileAgentAccountService
              .markAuthorizationRequired(
                portableData,
                account.id,
                credentialHint: 'OAuth',
              );
          syncMobileAgentAccountsWithDesktopRelay();
          if (!silent) {
            final error = _mobileProviderErrorText(result, provider.label);
            _markMobileAgentOAuthAuthorizationFailed(
              providerId,
              account.id,
              error,
            );
            lastError = error;
            _setLocalizedStatusMessage(
              '${provider.label} OAuth 需要重新授权。',
              '${provider.label} OAuth requires reauthorization.',
            );
            statusCaption = 'Mobile agents';
          }
        }
      } catch (error) {
        if (!silent) {
          lastError = error.toString();
          _setLocalizedStatusMessage(
            '${provider.label} OAuth 状态刷新失败。',
            'Failed to refresh ${provider.label} OAuth status.',
          );
          statusCaption = 'Mobile agents';
        }
      }
    }
    if (!silent) {
      _notifyStateChanged();
    }
  }

  MobileAgentOAuthAuthorizationPrompt? mobileAgentOAuthAuthorizationPromptFor(
    MobileAgentAccount account,
  ) {
    return mobileAgentOAuthAuthorizationPrompts[_mobileAgentOAuthPromptKey(
      account.providerId,
      account.id,
    )];
  }

  void dismissMobileAgentOAuthAuthorizationPrompt(MobileAgentAccount account) {
    final key = _mobileAgentOAuthPromptKey(account.providerId, account.id);
    final current = mobileAgentOAuthAuthorizationPrompts[key];
    if (current == null) {
      return;
    }
    mobileAgentOAuthAuthorizationPrompts = Map.unmodifiable({
      ...mobileAgentOAuthAuthorizationPrompts,
      key: current.copyWith(
        status: MobileAgentOAuthAuthorizationPromptStatus.dismissed,
        updatedAt: DateTime.now().toUtc(),
      ),
    });
    _stopMobileAgentOAuthStatusPollingIfIdle();
    _notifyStateChanged();
  }

  Future<void> refreshPendingMobileAgentOAuthAuthorizations() async {
    await _pollMobileAgentOAuthAuthorizationStatuses();
  }

  void _showMobileAgentOAuthAuthorizationWaiting(
    String providerId,
    String mobileAccountId,
  ) {
    final normalizedProvider = providerId.trim().toLowerCase();
    final normalizedAccount = mobileAccountId.trim();
    if (normalizedProvider.isEmpty || normalizedAccount.isEmpty) {
      return;
    }
    final key = _mobileAgentOAuthPromptKey(
      normalizedProvider,
      normalizedAccount,
    );
    mobileAgentOAuthAuthorizationPrompts = Map.unmodifiable({
      ...mobileAgentOAuthAuthorizationPrompts,
      key: MobileAgentOAuthAuthorizationPrompt(
        providerId: normalizedProvider,
        mobileAccountId: normalizedAccount,
        status: MobileAgentOAuthAuthorizationPromptStatus.waiting,
        updatedAt: DateTime.now().toUtc(),
      ),
    });
    _startMobileAgentOAuthStatusPolling();
    _notifyStateChanged();
  }

  void _markMobileAgentOAuthAuthorizationSuccess(
    String providerId,
    String mobileAccountId,
  ) {
    final normalizedProvider = providerId.trim().toLowerCase();
    final normalizedAccount = mobileAccountId.trim();
    if (normalizedProvider.isEmpty || normalizedAccount.isEmpty) {
      return;
    }
    final key = _mobileAgentOAuthPromptKey(
      normalizedProvider,
      normalizedAccount,
    );
    mobileAgentOAuthAuthorizationPrompts = Map.unmodifiable({
      ...mobileAgentOAuthAuthorizationPrompts,
      key: MobileAgentOAuthAuthorizationPrompt(
        providerId: normalizedProvider,
        mobileAccountId: normalizedAccount,
        status: MobileAgentOAuthAuthorizationPromptStatus.success,
        updatedAt: DateTime.now().toUtc(),
      ),
    });
    _stopMobileAgentOAuthStatusPollingIfIdle();
  }

  void _markMobileAgentOAuthAuthorizationFailed(
    String providerId,
    String mobileAccountId,
    String message,
  ) {
    final normalizedProvider = providerId.trim().toLowerCase();
    final normalizedAccount = mobileAccountId.trim();
    if (normalizedProvider.isEmpty || normalizedAccount.isEmpty) {
      return;
    }
    final key = _mobileAgentOAuthPromptKey(
      normalizedProvider,
      normalizedAccount,
    );
    mobileAgentOAuthAuthorizationPrompts = Map.unmodifiable({
      ...mobileAgentOAuthAuthorizationPrompts,
      key: MobileAgentOAuthAuthorizationPrompt(
        providerId: normalizedProvider,
        mobileAccountId: normalizedAccount,
        status: MobileAgentOAuthAuthorizationPromptStatus.failed,
        updatedAt: DateTime.now().toUtc(),
        message: message,
      ),
    });
    _stopMobileAgentOAuthStatusPollingIfIdle();
  }

  Future<bool> _completeMobileAgentOAuthAuthorizationIfConversationReady({
    required MobileAgentProvider provider,
    required String mobileAccountId,
    required String credentialHint,
    bool showSuccessPrompt = true,
  }) async {
    final normalizedAccount = mobileAccountId.trim();
    if (normalizedAccount.isEmpty) {
      return false;
    }
    if (showSuccessPrompt &&
        _mobileAgentOAuthAuthorizationSuccessWasConsumed(
          provider.id,
          normalizedAccount,
        )) {
      return true;
    }
    _setLocalizedStatusMessage(
      '正在验证 ${provider.label} OAuth 直连对话。',
      'Validating direct ${provider.label} OAuth conversation access.',
    );
    statusCaption = 'Mobile agents';
    _notifyStateChanged();
    final validation = await _validateMobileAgentOAuthConversation(
      provider: provider,
      mobileAccountId: normalizedAccount,
    );
    final reply = _mobileProviderReplyText(validation).trim();
    if (validation['ok'] == true && reply.isNotEmpty) {
      mobileAgentAccounts = await mobileAgentAccountService
          .markOAuthCredentialPresent(
            portableData,
            provider.id,
            accountId: normalizedAccount,
            credentialHint: credentialHint.trim().isEmpty
                ? 'OAuth'
                : credentialHint.trim(),
          );
      syncMobileAgentAccountsWithDesktopRelay();
      if (showSuccessPrompt) {
        if (!_mobileAgentOAuthAuthorizationSuccessWasConsumed(
          provider.id,
          normalizedAccount,
        )) {
          _markMobileAgentOAuthAuthorizationSuccess(
            provider.id,
            normalizedAccount,
          );
        }
      } else {
        _clearMobileAgentOAuthAuthorizationPrompt(
          provider.id,
          normalizedAccount,
        );
      }
      _setLocalizedStatusMessage(
        '${provider.label} OAuth 已验证，可直接对话。',
        '${provider.label} OAuth validated; direct conversation access is available.',
      );
      statusCaption = 'Mobile agents';
      return true;
    }
    final error = _mobileProviderErrorText(validation, provider.label);
    if (_mobileProviderErrorRequiresOAuthCredentialReset(error)) {
      mobileAgentAccounts = await mobileAgentAccountService
          .markAuthorizationRequired(
            portableData,
            normalizedAccount,
            credentialHint: 'OAuth',
          );
    } else {
      mobileAgentAccounts = await mobileAgentAccountService
          .markOAuthConversationValidationFailed(
            portableData,
            provider.id,
            accountId: normalizedAccount,
            credentialHint: credentialHint.trim().isEmpty
                ? 'OAuth'
                : credentialHint.trim(),
          );
    }
    syncMobileAgentAccountsWithDesktopRelay();
    _markMobileAgentOAuthAuthorizationFailed(
      provider.id,
      normalizedAccount,
      error,
    );
    lastError = _mobileProviderOAuthValidationFailureText(
      provider.label,
      error,
    );
    _setLocalizedStatusMessage(
      '${provider.label} OAuth 已返回，但真实对话验证失败。',
      '${provider.label} OAuth returned, but real conversation validation failed.',
    );
    statusCaption = 'Mobile agents';
    return false;
  }

  bool _mobileAgentOAuthAuthorizationSuccessWasConsumed(
    String providerId,
    String mobileAccountId,
  ) {
    final prompt =
        mobileAgentOAuthAuthorizationPrompts[_mobileAgentOAuthPromptKey(
          providerId,
          mobileAccountId,
        )];
    return prompt?.isSuccess == true || prompt?.isDismissed == true;
  }

  void _clearMobileAgentOAuthAuthorizationPrompt(
    String providerId,
    String mobileAccountId,
  ) {
    final key = _mobileAgentOAuthPromptKey(providerId, mobileAccountId);
    if (!mobileAgentOAuthAuthorizationPrompts.containsKey(key)) {
      return;
    }
    mobileAgentOAuthAuthorizationPrompts = Map.unmodifiable({
      for (final entry in mobileAgentOAuthAuthorizationPrompts.entries)
        if (entry.key != key) entry.key: entry.value,
    });
    _stopMobileAgentOAuthStatusPollingIfIdle();
  }

  Future<Map<String, dynamic>> _validateMobileAgentOAuthConversation({
    required MobileAgentProvider provider,
    required String mobileAccountId,
  }) async {
    final key = _mobileAgentOAuthPromptKey(provider.id, mobileAccountId);
    final existing = _mobileAgentOAuthValidationFutures[key];
    if (existing != null) {
      return existing;
    }
    late final Future<Map<String, dynamic>> validation;
    validation = _runMobileAgentOAuthConversationValidation(
      provider: provider,
      mobileAccountId: mobileAccountId,
    );
    _mobileAgentOAuthValidationFutures[key] = validation;
    try {
      return await validation;
    } finally {
      if (identical(_mobileAgentOAuthValidationFutures[key], validation)) {
        _mobileAgentOAuthValidationFutures.remove(key);
      }
    }
  }

  Future<Map<String, dynamic>> _runMobileAgentOAuthConversationValidation({
    required MobileAgentProvider provider,
    required String mobileAccountId,
  }) async {
    try {
      MobileAgentAccount? account;
      for (final candidate in mobileAgentAccounts) {
        if (candidate.id == mobileAccountId) {
          account = candidate;
          break;
        }
      }
      final result = await mobileRelayService.sendLocalProviderMessage(
        agentService: agentService,
        providerId: provider.id,
        text: _mobileAgentOAuthValidationPrompt,
        model: account?.effectiveModel ?? provider.defaultModel,
        reasoningEffort: account?.reasoningEffort ?? '',
        mobileAccountId: mobileAccountId,
      );
      if (result['ok'] == true && _mobileProviderReplyText(result).isNotEmpty) {
        return result;
      }
      return {
        ...result,
        'ok': false,
        'status': result['status'] ?? 'oauth_chat_validation_failed',
      };
    } catch (error) {
      return {
        'ok': false,
        'providerId': provider.id,
        'mobileAccountId': mobileAccountId,
        'status': 'oauth_chat_validation_failed',
        'error': error.toString(),
      };
    }
  }

  void _startMobileAgentOAuthStatusPolling() {
    if (_mobileAgentOAuthStatusTimer != null) {
      return;
    }
    _mobileAgentOAuthStatusTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_pollMobileAgentOAuthAuthorizationStatuses()),
    );
    unawaited(_pollMobileAgentOAuthAuthorizationStatuses());
  }

  void _stopMobileAgentOAuthStatusPollingIfIdle() {
    final hasWaitingPrompt = mobileAgentOAuthAuthorizationPrompts.values.any(
      (prompt) => prompt.isWaiting,
    );
    if (hasWaitingPrompt) {
      return;
    }
    _mobileAgentOAuthStatusTimer?.cancel();
    _mobileAgentOAuthStatusTimer = null;
  }

  Future<void> _pollMobileAgentOAuthAuthorizationStatuses() async {
    if (_isPollingMobileAgentOAuthStatus) {
      return;
    }
    final prompts = mobileAgentOAuthAuthorizationPrompts.values
        .where((prompt) => prompt.isWaiting)
        .toList(growable: false);
    if (prompts.isEmpty) {
      _stopMobileAgentOAuthStatusPollingIfIdle();
      return;
    }
    _isPollingMobileAgentOAuthStatus = true;
    var changed = false;
    try {
      for (final prompt in prompts) {
        try {
          final result = await mobileRelayService.mobileProviderOAuthStatus(
            agentService: agentService,
            providerId: prompt.providerId,
            mobileAccountId: prompt.mobileAccountId,
          );
          if (result['ok'] == true && result['credentialPresent'] == true) {
            if (!_mobileProviderOAuthStatusIsFreshForPrompt(result, prompt)) {
              continue;
            }
            final completedAccountId =
                (result['mobileAccountId'] ??
                        result['accountId'] ??
                        prompt.mobileAccountId)
                    .toString()
                    .trim();
            final accountId = completedAccountId.isEmpty
                ? prompt.mobileAccountId
                : completedAccountId;
            await _completeMobileAgentOAuthAuthorizationIfConversationReady(
              provider: mobileAgentProviderFor(prompt.providerId),
              mobileAccountId: accountId,
              credentialHint: (result['credentialHint'] ?? 'OAuth').toString(),
            );
            changed = true;
          }
        } catch (error) {
          debugPrint('Failed to poll mobile agent OAuth status: $error');
        }
      }
    } finally {
      _isPollingMobileAgentOAuthStatus = false;
      _stopMobileAgentOAuthStatusPollingIfIdle();
      if (changed) {
        _notifyStateChanged();
      }
    }
  }

  Future<void> openMobileAgentProviderCredentialPage(
    MobileAgentProvider provider,
  ) async {
    lastError = '';
    _setLocalizedStatusMessage(
      '正在打开 ${provider.label} 官方授权页面。',
      'Opening the official ${provider.label} authorization page.',
    );
    statusCaption = 'Mobile agents';
    _notifyStateChanged();
    try {
      final result = await mobileRelayService.openExternalUrl(
        agentService: agentService,
        url: provider.effectiveCredentialUrl,
      );
      if (result['ok'] == false) {
        throw StateError(
          (result['message'] ?? result['status'] ?? 'open failed').toString(),
        );
      }
      _setLocalizedStatusMessage(
        '已打开 ${provider.label} 官方授权页面。',
        'Opened the official ${provider.label} authorization page.',
      );
      statusCaption = 'Mobile agents';
    } catch (error) {
      debugPrint('Failed to open mobile provider credential page: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '${provider.label} 官方授权页面打开失败。',
        'Failed to open the official ${provider.label} authorization page.',
      );
      statusCaption = 'Mobile agents';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> openMobileProviderWebConversation(
    MobileAgentAccount account,
  ) async {
    final provider = account.provider;
    lastError = '';
    _setLocalizedStatusMessage(
      '正在打开 ${provider.label} 网页端对话。',
      'Opening ${provider.label} web conversation.',
    );
    statusCaption = 'Mobile agents';
    _notifyStateChanged();
    try {
      final result = await mobileRelayService.openMobileProviderWebConversation(
        agentService: agentService,
        providerId: provider.id,
      );
      if (result['ok'] == false) {
        throw StateError(
          (result['message'] ?? result['status'] ?? 'open failed').toString(),
        );
      }
      _setLocalizedStatusMessage(
        '已打开 ${provider.label} 网页端对话。',
        'Opened ${provider.label} web conversation.',
      );
      statusCaption = 'Mobile agents';
    } catch (error) {
      debugPrint('Failed to open mobile provider web conversation: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '${provider.label} 网页端对话打开失败。',
        'Failed to open ${provider.label} web conversation.',
      );
      statusCaption = 'Mobile agents';
    } finally {
      _notifyStateChanged();
    }
  }

  AgentConversationSession? mobileProviderConversationFor(
    MobileAgentAccount account,
  ) {
    final selectedId = selectedMobileProviderConversationIds[account.id] ?? '';
    final allRecords = mobileProviderConversationRecordsFor(account);
    if (selectedId.trim().isNotEmpty) {
      for (final record in allRecords) {
        if (record.session.id == selectedId) {
          return record.session;
        }
      }
    }
    final records = activeMobileProviderConversationsFor(account);
    return records.isEmpty ? null : records.first.session;
  }

  List<MobileProviderConversationRecord> mobileProviderConversationRecordsFor(
    MobileAgentAccount account, {
    String status = '',
  }) {
    final records =
        mobileProviderConversationRecordsByAccount[account.id] ?? const [];
    if (status.trim().isEmpty) {
      return records;
    }
    return records
        .where((record) => record.status == status)
        .toList(growable: false);
  }

  List<MobileProviderConversationRecord> activeMobileProviderConversationsFor(
    MobileAgentAccount account,
  ) {
    return mobileProviderConversationRecordsFor(
      account,
      status: mobileProviderConversationStatusActive,
    );
  }

  List<MobileProviderConversationRecord> archivedMobileProviderConversationsFor(
    MobileAgentAccount account,
  ) {
    return mobileProviderConversationRecordsFor(
      account,
      status: mobileProviderConversationStatusArchived,
    );
  }

  List<MobileProviderConversationRecord> trashedMobileProviderConversationsFor(
    MobileAgentAccount account,
  ) {
    return mobileProviderConversationRecordsFor(
      account,
      status: mobileProviderConversationStatusTrashed,
    );
  }

  String mobileProviderConversationPreview(MobileAgentAccount account) {
    final session = mobileProviderConversationFor(account);
    final preview = session?.preview.trim() ?? '';
    if (_mobileProviderConversationPreviewIsStaleOAuthFailure(
      account,
      preview,
    )) {
      return '';
    }
    return preview;
  }

  Future<void> updateMobileAgentGenerationOptions(
    String accountId, {
    String? selectedModel,
    String? reasoningEffort,
  }) async {
    final resolvedAccountId = accountId.trim();
    MobileAgentAccount? seedAccount;
    for (final account in mobileAgentAccounts) {
      if (account.id == resolvedAccountId) {
        seedAccount = account;
        break;
      }
    }
    if (seedAccount != null) {
      final now = DateTime.now().toUtc().toIso8601String();
      mobileAgentAccounts = List<MobileAgentAccount>.unmodifiable([
        for (final account in mobileAgentAccounts)
          if (account.id == resolvedAccountId)
            account.copyWith(
              selectedModel: selectedModel,
              reasoningEffort: reasoningEffort,
              updatedAt: now,
            )
          else
            account,
      ]);
      syncMobileAgentAccountsWithDesktopRelay();
      _notifyStateChanged();
    }
    try {
      mobileAgentAccounts = await mobileAgentAccountService
          .updateGenerationOptions(
            portableData,
            accountId,
            selectedModel: selectedModel,
            reasoningEffort: reasoningEffort,
            seedAccount: seedAccount,
          );
      syncMobileAgentAccountsWithDesktopRelay();
    } catch (error) {
      debugPrint('Failed to update mobile agent generation options: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '模型配置保存失败。',
        'Failed to save the model configuration.',
      );
      statusCaption = 'Mobile agents';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> sendMobileProviderMessage({
    required MobileAgentAccount account,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || isSendingMobileProviderMessage) {
      return;
    }
    final provider = account.provider;
    if (!provider.supportsDirectChat) {
      lastError = '${provider.label} 手机端对话暂未接入。';
      _setLocalizedStatusMessage(
        lastError,
        '${provider.label} mobile conversation support is not available yet.',
      );
      statusCaption = 'Mobile agents';
      _notifyStateChanged();
      return;
    }
    if (!account.credentialPresent) {
      lastError = '${provider.label} 需要先配置 API Key 或配对电脑授权。';
      _setLocalizedStatusMessage(
        lastError,
        '${provider.label} requires an API key or authorization from the paired computer.',
      );
      statusCaption = 'Mobile agents';
      _notifyStateChanged();
      return;
    }

    isSendingMobileProviderMessage = true;
    lastError = '';
    final sentAt = DateTime.now().toUtc().toIso8601String();
    await _appendMobileProviderMessage(
      account: account,
      message: AgentConversationMessage(
        id: _mobileProviderMessageId(account.id, 'user'),
        role: 'user',
        text: trimmed,
        createdAt: sentAt,
      ),
      updatedAt: sentAt,
    );
    _setLocalizedStatusMessage(
      account.usesDesktopRelay
          ? '正在通过配对电脑请求 ${provider.label}。'
          : account.usesLocalOAuth ||
                account.authKind == MobileAgentAuthKind.oauthPkce
          ? '正在通过手机本机 OAuth 请求 ${provider.label}。'
          : '正在通过手机本机 API Key 请求 ${provider.label}。',
      account.usesDesktopRelay
          ? 'Requesting ${provider.label} through the paired computer.'
          : account.usesLocalOAuth ||
                account.authKind == MobileAgentAuthKind.oauthPkce
          ? 'Requesting ${provider.label} with the OAuth credential stored on this phone.'
          : 'Requesting ${provider.label} with the API key stored on this phone.',
    );
    statusCaption = 'Mobile agents';
    _notifyStateChanged();

    try {
      final model = account.effectiveModel;
      final reasoningEffort = account.reasoningEffort.trim();
      final result = account.usesDesktopRelay
          ? await mobileRelayService.sendSecureProviderMessage(
              agentService: agentService,
              providerId: provider.id,
              text: trimmed,
              model: model,
              reasoningEffort: reasoningEffort,
              profileId: account.relayProfileId,
            )
          : await mobileRelayService.sendLocalProviderMessage(
              agentService: agentService,
              providerId: provider.id,
              text: trimmed,
              model: model,
              reasoningEffort: reasoningEffort,
              mobileAccountId: account.id,
            );
      final reply = _mobileProviderReplyText(result).trim();
      final receivedAt = DateTime.now().toUtc().toIso8601String();
      if (result['ok'] == true && reply.isNotEmpty) {
        await _appendMobileProviderMessage(
          account: account,
          message: AgentConversationMessage(
            id: _mobileProviderMessageId(account.id, 'assistant'),
            role: 'assistant',
            text: reply,
            createdAt: receivedAt,
          ),
          updatedAt: receivedAt,
        );
        _setLocalizedStatusMessage(
          '${provider.label} 已回复。',
          '${provider.label} replied.',
        );
      } else {
        final error = _mobileProviderErrorText(result, provider.label);
        lastError = error;
        final recoverOAuth =
            _mobileProviderAccountUsesOAuthCredential(account) &&
            _mobileProviderErrorLooksLikeOAuthRecovery(error);
        if (recoverOAuth) {
          if (_mobileProviderErrorRequiresOAuthCredentialReset(error)) {
            mobileAgentAccounts = await mobileAgentAccountService
                .markAuthorizationRequired(
                  portableData,
                  account.id,
                  credentialHint: 'OAuth',
                );
          } else {
            mobileAgentAccounts = await mobileAgentAccountService
                .markOAuthConversationValidationFailed(
                  portableData,
                  account.providerId,
                  accountId: account.id,
                  credentialHint: account.credentialHint.trim().isEmpty
                      ? 'OAuth'
                      : account.credentialHint.trim(),
                );
          }
          syncMobileAgentAccountsWithDesktopRelay();
          _markMobileAgentOAuthAuthorizationFailed(
            account.providerId,
            account.id,
            error,
          );
          final requiresReauthorization =
              _mobileProviderErrorRequiresOAuthCredentialReset(error);
          _setLocalizedStatusMessage(
            requiresReauthorization
                ? '${provider.label} OAuth 需要重新授权。'
                : '${provider.label} OAuth 已保存，但真实对话验证失败。',
            requiresReauthorization
                ? '${provider.label} OAuth requires reauthorization.'
                : '${provider.label} OAuth is saved, but real conversation validation failed.',
          );
        } else {
          await _appendMobileProviderMessage(
            account: account,
            message: AgentConversationMessage(
              id: _mobileProviderMessageId(account.id, 'assistant'),
              role: 'assistant',
              text: error,
              createdAt: receivedAt,
            ),
            updatedAt: receivedAt,
          );
          _setLocalizedStatusMessage(
            '${provider.label} 请求失败。',
            '${provider.label} request failed.',
          );
        }
      }
      statusCaption = 'Mobile agents';
    } catch (error) {
      debugPrint('Failed to send mobile provider message: $error');
      final failedAt = DateTime.now().toUtc().toIso8601String();
      lastError = error.toString();
      await _appendMobileProviderMessage(
        account: account,
        message: AgentConversationMessage(
          id: _mobileProviderMessageId(account.id, 'assistant'),
          role: 'assistant',
          text: _mobileProviderFallbackErrorText(provider.label),
          createdAt: failedAt,
        ),
        updatedAt: failedAt,
      );
      _setLocalizedStatusMessage(
        '${provider.label} 请求失败。',
        '${provider.label} request failed.',
      );
      statusCaption = 'Mobile agents';
    } finally {
      isSendingMobileProviderMessage = false;
      _notifyStateChanged();
    }
  }

  Future<void> syncMobileProviderCredentialsFromDesktopRelay({
    bool silent = false,
  }) async {
    await _writeMobileProviderSyncDiagnostic('sync_requested');
    if (!_mobileClientRuntimePlatform ||
        !_mobileRelayCanAttemptProviderCredentialSync()) {
      await _writeMobileProviderSyncDiagnostic('sync_skipped_not_pairable');
      return;
    }
    if (_isSyncingMobileProviderCredentials) {
      _syncMobileProviderCredentialsAgain = true;
      await _writeMobileProviderSyncDiagnostic('sync_skipped_in_flight');
      return;
    }
    final accounts = [
      ...mobileAgentAccounts.where(
        (account) =>
            account.usesDesktopRelay &&
            account.credentialPresent &&
            _mobileRelayCredentialSyncCandidate(account),
      ),
      ..._fallbackDesktopRelayCredentialAccounts(),
    ];
    if (accounts.isEmpty) {
      await _writeMobileProviderSyncDiagnostic('sync_skipped_no_accounts');
      return;
    }
    await _writeMobileProviderSyncDiagnostic('sync_started', {
      'candidateCount': accounts.length,
      'candidateProviders': accounts
          .map((account) => account.providerId)
          .toSet()
          .toList(growable: false),
    });
    _isSyncingMobileProviderCredentials = true;
    if (!silent) {
      lastError = '';
      _setLocalizedStatusMessage(
        accounts.length == 1
            ? '正在同步 ${accounts.first.provider.label} API Key 到手机安全存储。'
            : '正在同步电脑端 API Key 到手机安全存储。',
        accounts.length == 1
            ? 'Syncing the ${accounts.first.provider.label} API key to secure storage on this phone.'
            : 'Syncing desktop API keys to secure storage on this phone.',
      );
      statusCaption = 'Mobile agents';
      _notifyStateChanged();
    }
    for (final account in accounts) {
      final providerId = account.providerId;
      final provider = account.provider;
      final syncedAccountId = _syncedMobileProviderAccountId(account);
      try {
        final result = await mobileRelayService
            .syncMobileProviderCredentialFromRelay(
              agentService: agentService,
              providerId: providerId,
              mobileAccountId: syncedAccountId,
              profileId: account.relayProfileId,
            );
        await _writeMobileProviderSyncDiagnostic('sync_result', {
          'providerId': providerId,
          'ok': result['ok'] == true,
          'credentialPresent': result['credentialPresent'] == true,
          'credentialKind': (result['credentialKind'] ?? '').toString(),
          'status': (result['status'] ?? result['code'] ?? '').toString(),
          'code': (result['code'] ?? '').toString(),
          'detailCode': (result['detailCode'] ?? '').toString(),
          'detail': (result['detail'] ?? '').toString(),
        });
        if (result['ok'] == true && result['credentialPresent'] == true) {
          final credentialKind = (result['credentialKind'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          final syncedId = (result['mobileAccountId'] ?? syncedAccountId)
              .toString();
          if (credentialKind.startsWith('oauth')) {
            if (providerId != 'chatgpt') {
              await _writeMobileProviderSyncDiagnostic('sync_skipped_oauth', {
                'providerId': providerId,
              });
              continue;
            }
            mobileAgentAccounts = await mobileAgentAccountService
                .markOAuthCredentialPresent(
                  portableData,
                  providerId,
                  accountId: syncedId,
                  label: account.label,
                  credentialHint: (result['credentialHint'] ?? 'OAuth')
                      .toString(),
                  authSource: MobileAgentAccount.authSourceMobileSynced,
                  relayDeviceLabel: account.relayDeviceLabel,
                  relayProfileId: account.relayProfileId,
                );
          } else {
            mobileAgentAccounts = await mobileAgentAccountService
                .markApiCredentialPresent(
                  portableData,
                  providerId,
                  accountId: syncedId,
                  label: account.label,
                  credentialHint: (result['credentialHint'] ?? '').toString(),
                  authSource: MobileAgentAccount.authSourceMobileSynced,
                  relayDeviceLabel: account.relayDeviceLabel,
                  relayProfileId: account.relayProfileId,
                );
          }
          syncMobileAgentAccountsWithDesktopRelay();
          if (!silent) {
            _setLocalizedStatusMessage(
              credentialKind.startsWith('oauth')
                  ? '${provider.label} OAuth 已同步到手机端。'
                  : '${provider.label} API Key 已同步到手机端。',
              credentialKind.startsWith('oauth')
                  ? '${provider.label} OAuth authorization synced to this phone.'
                  : '${provider.label} API key synced to this phone.',
            );
            statusCaption = 'Mobile agents';
          }
        } else if (!silent) {
          if (_mobileProviderSyncPairingNotFound(result)) {
            await _handleMobileRelayPairingExpiredForProviderSync(providerId);
            break;
          }
          lastError = (result['message'] ?? result['status'] ?? '').toString();
          _setLocalizedStatusMessage(
            '${provider.label} API Key 同步失败。',
            'Failed to sync the ${provider.label} API key.',
          );
          statusCaption = 'Mobile agents';
        } else if (_mobileProviderSyncPairingNotFound(result)) {
          await _handleMobileRelayPairingExpiredForProviderSync(providerId);
          break;
        }
      } catch (error) {
        debugPrint('Failed to sync mobile provider credential: $error');
        await _writeMobileProviderSyncDiagnostic('sync_exception', {
          'providerId': providerId,
          'errorClass': error.runtimeType.toString(),
        });
        if (!silent) {
          lastError = error.toString();
          _setLocalizedStatusMessage(
            '${provider.label} API Key 同步失败。',
            'Failed to sync the ${provider.label} API key.',
          );
          statusCaption = 'Mobile agents';
        }
      }
    }
    _isSyncingMobileProviderCredentials = false;
    await _writeMobileProviderSyncDiagnostic('sync_finished');
    _notifyStateChanged();
    if (_syncMobileProviderCredentialsAgain) {
      _syncMobileProviderCredentialsAgain = false;
      unawaited(syncMobileProviderCredentialsFromDesktopRelay(silent: true));
    }
  }

  Future<void> handoffMobileProviderConversationToAgent({
    required MobileAgentAccount account,
    required String targetAgentId,
    String prompt = '',
    String sessionId = '',
  }) async {
    final normalizedTarget = targetAgentId.trim();
    if (normalizedTarget.isEmpty || isSendingConversationMessage) {
      return;
    }
    TargetCandidate? target;
    for (final candidate in scannedTargets) {
      if (candidate.target == normalizedTarget && candidate.canRelayRuntime) {
        target = candidate;
        break;
      }
    }
    if (target == null) {
      lastError = '未找到可中继的电脑端智能体。';
      _setLocalizedStatusMessage(
        'ChatGPT 对话转交失败。',
        'Failed to hand off the ChatGPT conversation.',
      );
      statusCaption = 'Mobile relay';
      _notifyStateChanged();
      return;
    }
    final List<AgentConversationMessage> messages;
    if (account.providerId == 'chatgpt') {
      final webSnapshotMessages = await _mobileProviderWebSnapshotMessages(
        account,
      );
      if (webSnapshotMessages.isEmpty) {
        lastError = 'ChatGPT 网页端对话暂无可转交内容，请先打开 ChatGPT 网页端完成或刷新对话。';
        _setLocalizedStatusMessage(
          'ChatGPT 网页端对话暂无可转交内容。',
          'The ChatGPT web conversation has no content to hand off.',
        );
        statusCaption = 'Mobile relay';
        _notifyStateChanged();
        return;
      }
      messages = webSnapshotMessages;
    } else {
      final conversation = mobileProviderConversationFor(account);
      messages = conversation?.messages ?? const <AgentConversationMessage>[];
    }
    final handoffPrompt = _mobileProviderConversationHandoffPrompt(
      account: account,
      messages: messages,
      prompt: prompt,
    );
    if (handoffPrompt.trim().isEmpty) {
      return;
    }
    isSendingConversationMessage = true;
    sendingConversationSessionId = selectedConversationSession?.id.trim() ?? '';
    sendingConversationNativeSessionId =
        selectedConversationSession?.nativeSessionId.trim() ?? sessionId.trim();
    lastError = '';
    _setLocalizedStatusMessage(
      '正在把 ${account.label} 对话转交给 ${target.label}。',
      'Handing off the ${account.label} conversation to ${target.label}.',
    );
    statusCaption = 'Mobile relay';
    _notifyStateChanged();
    try {
      final selectedSession = selectedConversationAgentId == target.target
          ? selectedConversationSession
          : null;
      if (sessionId.trim().isEmpty &&
          selectedConversationAgentId == target.target &&
          selectedConversationSessionId.trim().isNotEmpty &&
          selectedSession == null) {
        lastError = 'native_session_unresolved';
        _setLocalizedStatusMessage(
          '${target.label} 原生会话尚未解析，转交已禁用。',
          '${target.label} native session is unresolved; handoff is disabled.',
        );
        statusCaption = 'Mobile relay';
        return;
      }
      final selectedSessionId = sessionId.trim().isNotEmpty
          ? sessionId.trim()
          : selectedSession?.nativeSessionId.trim() ?? '';
      final result = await mobileRelayService.sendSecureAgentMessage(
        agentService: agentService,
        agentId: target.target,
        text: handoffPrompt,
        sessionId: selectedSessionId,
      );
      if (result['ok'] == true) {
        final returnedSessionId = _secureAgentRelayNativeSessionId(result);
        if (returnedSessionId.isEmpty ||
            (selectedSessionId.isNotEmpty &&
                returnedSessionId != selectedSessionId)) {
          selectedConversationAgentId = target.target;
          selectedConversationSessionId =
              _conversationSessionLoadFailedSelectionId;
          lastError = returnedSessionId.isEmpty
              ? 'native_session_id_missing_from_result'
              : 'native_session_id_mismatch';
          _recordConversationTabSendOutcome(
            agentId: target.target,
            ok: false,
            errorCode: lastError,
          );
          _setLocalizedStatusMessage(
            '${target.label} 未确认原生会话连续性，转交结果已拒绝。',
            '${target.label} did not confirm native session continuity; the handoff result was rejected.',
          );
          statusCaption = 'Mobile relay';
          return;
        }
        final receivedAt = DateTime.now().toUtc().toIso8601String();
        selectedConversationAgentId = target.target;
        _appendRelayConversationMessages(
          agent: target,
          userText: handoffPrompt,
          assistantText: _secureAgentRelayReplyText(result),
          sessionId: returnedSessionId,
          updatedAt: receivedAt,
        );
        _recordConversationTabSendOutcome(agentId: target.target, ok: true);
        _setLocalizedStatusMessage(
          '已把 ${account.label} 对话转交给 ${target.label}。',
          'Handed off the ${account.label} conversation to ${target.label}.',
        );
      } else {
        lastError = _runtimeAdapterErrorCode(result);
        _recordConversationTabSendOutcome(
          agentId: target.target,
          ok: false,
          result: result,
          errorCode: lastError,
        );
        _setLocalizedStatusMessage(
          '${target.label} 中继执行失败。',
          '${target.label} relay execution failed.',
        );
      }
      statusCaption = 'Mobile relay';
    } catch (_) {
      lastError = 'native_agent_transport_failed';
      _setLocalizedStatusMessage(
        'ChatGPT 对话转交失败。',
        'Failed to hand off the ChatGPT conversation.',
      );
      statusCaption = 'Mobile relay';
    } finally {
      isSendingConversationMessage = false;
      sendingConversationSessionId = '';
      sendingConversationNativeSessionId = '';
      _notifyStateChanged();
    }
  }

  Future<List<AgentConversationMessage>> _mobileProviderWebSnapshotMessages(
    MobileAgentAccount account,
  ) async {
    try {
      final result = await mobileRelayService
          .mobileProviderWebConversationSnapshot(
            agentService: agentService,
            providerId: account.providerId,
          );
      if (result['ok'] != true || result['snapshotPresent'] != true) {
        return const <AgentConversationMessage>[];
      }
      final rawMessages = result['messages'];
      if (rawMessages is! List) {
        return const <AgentConversationMessage>[];
      }
      final capturedAt = (result['capturedAt'] ?? '').toString().trim();
      final timestamp =
          DateTime.tryParse(capturedAt)?.toUtc().toIso8601String() ??
          DateTime.now().toUtc().toIso8601String();
      final messages = <AgentConversationMessage>[];
      for (final raw in rawMessages) {
        final item = _mobileProviderMap(raw);
        if (item == null) {
          continue;
        }
        final text = (item['text'] ?? '').toString().trim();
        if (text.isEmpty) {
          continue;
        }
        final role = (item['role'] ?? '').toString().trim().toLowerCase();
        messages.add(
          AgentConversationMessage(
            id: 'chatgpt-web-${item['index'] ?? messages.length}',
            role: role.isEmpty ? 'message' : role,
            text: text,
            createdAt: timestamp,
          ),
        );
      }
      return List.unmodifiable(messages);
    } catch (error) {
      debugPrint('Failed to read mobile provider web snapshot: $error');
      return const <AgentConversationMessage>[];
    }
  }

  List<MobileAgentAccount> _fallbackDesktopRelayCredentialAccounts() {
    if (!_mobileClientRuntimePlatform ||
        !_mobileRelayCanAttemptProviderCredentialSync()) {
      return const [];
    }
    final advertisedProviderProfiles = mobileAgentAccounts
        .where(
          (account) =>
              account.usesDesktopRelay &&
              account.credentialPresent &&
              _mobileRelayCredentialSyncCandidate(account),
        )
        .map(
          (account) => _mobileRelayProviderProfileKey(
            account.providerId,
            account.relayProfileId,
          ),
        )
        .toSet();
    final configuredLocalProviderProfiles = mobileAgentAccounts
        .where(
          (account) =>
              !account.usesDesktopRelay &&
              account.credentialPresent &&
              _mobileRelayCredentialSyncCandidate(account),
        )
        .map(
          (account) => _mobileRelayProviderProfileKey(
            account.providerId,
            account.relayProfileId,
          ),
        )
        .toSet();
    final relayProviders = <MobileRelayAuthorizedProvider>[
      ...mobileRelayConfig.authorizedProviders,
      for (final device in mobileRelayConfig.deviceTabs)
        if (device.pairingId == mobileRelayConfig.pairingId)
          ...device.authorizedProviders,
    ];
    final deviceLabel = mobileRelayConfig.pcClientName.trim().isNotEmpty
        ? mobileRelayConfig.pcClientName.trim()
        : 'Mac';
    final accounts = <MobileAgentAccount>[];
    final seen = <String>{};
    for (final relayProvider in relayProviders) {
      final provider = mobileAgentProviderOrNull(relayProvider.providerId);
      if (provider == null || !relayProvider.credentialPresent) {
        continue;
      }
      final credentialKind = relayProvider.credentialKind.trim().toLowerCase();
      if (provider.id == 'chatgpt' ||
          credentialKind.startsWith('oauth') ||
          (provider.authKind != MobileAgentAuthKind.apiKey &&
              !credentialKind.startsWith('oauth'))) {
        continue;
      }
      final profileId = relayProvider.profileId.trim().isNotEmpty
          ? relayProvider.profileId.trim()
          : provider.id;
      final key = _mobileRelayProviderProfileKey(provider.id, profileId);
      if (!seen.add(key) ||
          advertisedProviderProfiles.contains(key) ||
          configuredLocalProviderProfiles.contains(key)) {
        continue;
      }
      accounts.add(
        MobileAgentAccount.create(
          provider,
          id: 'desktop-relay-fallback:${_mobileAccountIdPart(mobileRelayConfig.pairingId)}:${provider.id}:${_mobileAccountIdPart(profileId)}',
          label: relayProvider.label.trim().isNotEmpty
              ? relayProvider.label.trim()
              : provider.label,
          authSource: MobileAgentAccount.authSourceDesktopRelay,
          credentialPresent: true,
          credentialHint: deviceLabel,
          relayDeviceLabel: deviceLabel,
          relayProfileId: profileId,
        ),
      );
    }
    if (accounts.isNotEmpty) {
      return accounts;
    }
    if (relayProviders.isNotEmpty) {
      return const [];
    }
    for (final fallback in const [
      (providerId: 'deepseek', profileId: 'deepseek', label: 'DeepSeek'),
    ]) {
      final provider = mobileAgentProviderFor(fallback.providerId);
      final key = _mobileRelayProviderProfileKey(
        provider.id,
        fallback.profileId,
      );
      if (!seen.add(key) ||
          advertisedProviderProfiles.contains(key) ||
          configuredLocalProviderProfiles.contains(key)) {
        continue;
      }
      accounts.add(
        MobileAgentAccount.create(
          provider,
          id: 'desktop-relay-fallback:${_mobileAccountIdPart(mobileRelayConfig.pairingId)}:${provider.id}:${_mobileAccountIdPart(fallback.profileId)}',
          label: fallback.label,
          authSource: MobileAgentAccount.authSourceDesktopRelay,
          credentialPresent: true,
          credentialHint: deviceLabel,
          relayDeviceLabel: deviceLabel,
          relayProfileId: fallback.profileId,
        ),
      );
    }
    return accounts;
  }

  bool _mobileRelayCredentialSyncCandidate(MobileAgentAccount account) {
    // Only API-key shaped providers can sync secrets into the phone store.
    // OAuth providers (ChatGPT/Gemini/Kimi) stay as desktop-relay echoes unless
    // an explicit OAuth sync path is used later.
    if (account.authKind == MobileAgentAuthKind.oauthPkce ||
        (account.authKind == MobileAgentAuthKind.desktopRelay &&
            account.provider.authKind == MobileAgentAuthKind.oauthPkce)) {
      return false;
    }
    if (_mobileProviderAccountUsesOAuthCredential(account)) {
      return false;
    }
    if (account.provider.authKind != MobileAgentAuthKind.apiKey) {
      return false;
    }
    final credentialHint = account.credentialHint.trim().toLowerCase();
    final profileId = account.relayProfileId.trim().toLowerCase();
    if (credentialHint.contains('oauth') || profileId.contains('oauth')) {
      return false;
    }
    return true;
  }

  bool _mobileRelayCanAttemptProviderCredentialSync() {
    return mobileRelayConfig.hasPairing &&
        (mobileRelayConfig.paired || mobileRelayConfig.hasPairedDeviceEcho);
  }

  bool _mobileProviderSyncPairingNotFound(Map<String, dynamic> result) {
    final values = [
      result['detailCode'],
      result['code'],
      result['status'],
      result['detail'],
      result['message'],
    ].map((value) => value?.toString().toLowerCase() ?? '');
    return values.any(
      (value) =>
          value.contains('pairing_not_found') ||
          value.contains('pairing not found') ||
          value.contains('配对不存在'),
    );
  }

  Future<void> _handleMobileRelayPairingExpiredForProviderSync(
    String providerId,
  ) async {
    await _writeMobileProviderSyncDiagnostic('pairing_expired_reset', {
      'providerId': providerId,
    });
    mobileRelayConfig = await mobileRelayService.resetPairing(
      agentService: agentService,
    );
    syncMobileAgentAccountsWithDesktopRelay();
    lastError = '移动端配对已失效，请重新配对电脑。';
    _setLocalizedStatusMessage(
      '移动端配对已失效，请重新配对电脑。',
      'Mobile pairing expired. Pair the computer again.',
    );
    statusCaption = 'Mobile relay';
    _syncMobileProviderCredentialsAgain = false;
  }

  Future<void> _writeMobileProviderSyncDiagnostic(
    String stage, [
    Map<String, Object?> extra = const {},
  ]) async {
    if (!runtimePlatformBridge.isAndroid) {
      return;
    }
    try {
      final payload = <String, Object?>{
        'stage': stage,
        'at': DateTime.now().toUtc().toIso8601String(),
        'hasPairing': mobileRelayConfig.hasPairing,
        'paired': mobileRelayConfig.paired,
        'hasPairedDeviceEcho': mobileRelayConfig.hasPairedDeviceEcho,
        'relayEnabled': mobileRelayConfig.relayEnabled,
        'deviceCount': mobileRelayConfig.deviceTabs.length,
        'authorizedProviderCount': mobileRelayConfig.authorizedProviders.length,
        'accountCount': mobileAgentAccounts.length,
        'accounts': [
          for (final account in mobileAgentAccounts)
            {
              'providerId': account.providerId,
              'authSource': account.authSource,
              'credentialPresent': account.credentialPresent,
              'usesDesktopRelay': account.usesDesktopRelay,
              'usesMobileSynced': account.usesMobileSynced,
              'relayProfilePresent': account.relayProfileId.trim().isNotEmpty,
            },
        ],
        ...extra,
      };
      await runtimePlatformBridge.writeAndroidMobileProviderSyncDiagnostic(
        payload,
      );
    } catch (_) {
      // Diagnostics must never affect provider authorization.
    }
  }

  Future<void> loadMobileProviderConversations() async {
    final records = await mobileProviderConversationService.load(portableData);
    _applyMobileProviderConversationRecords(records);
  }

  Future<void> startMobileProviderConversation(
    MobileAgentAccount account,
  ) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final session = AgentConversationSession(
      id: _mobileProviderSessionId(account.id),
      agentId: account.providerId,
      title: _strings.newConversation,
      createdAt: now,
      updatedAt: now,
      adapterId: 'mobile-provider',
      sourceKind: 'mobile-provider',
      sourceClient: account.id,
      sourceClientLabel: account.label,
      native: false,
      readOnly: false,
      messages: const [],
    );
    await _upsertMobileProviderConversationRecord(
      MobileProviderConversationRecord(
        accountId: account.id,
        providerId: account.providerId,
        status: mobileProviderConversationStatusActive,
        session: session,
      ),
      selected: true,
    );
    _setLocalizedStatusMessage(
      '已新建 ${account.label} 对话。',
      'Created a new ${account.label} conversation.',
    );
    statusCaption = 'Mobile agents';
    _notifyStateChanged();
  }

  void selectMobileProviderConversation(
    MobileAgentAccount account,
    String sessionId,
  ) {
    selectedMobileProviderConversationIds = Map<String, String>.unmodifiable({
      ...selectedMobileProviderConversationIds,
      account.id: sessionId,
    });
    _syncMobileProviderConversationCompatibilityMap();
    _notifyStateChanged();
  }

  Future<void> archiveMobileProviderConversation(
    MobileAgentAccount account,
    String sessionId,
  ) async {
    final record = _mobileProviderConversationRecord(account, sessionId);
    if (record == null) {
      return;
    }
    final archived = record.copyWith(
      status: mobileProviderConversationStatusArchived,
      archivedAt: DateTime.now().toUtc().toIso8601String(),
      deletedAt: '',
    );
    await _upsertMobileProviderConversationRecord(archived);
    _setLocalizedStatusMessage(
      '${record.session.title} 已存档到本机。',
      '${record.session.title} was archived locally.',
    );
    statusCaption = 'Mobile agents';
    _notifyStateChanged();
  }

  Future<void> trashMobileProviderConversation(
    MobileAgentAccount account,
    String sessionId,
  ) async {
    final record = _mobileProviderConversationRecord(account, sessionId);
    if (record == null) {
      return;
    }
    await _upsertMobileProviderConversationRecord(
      record.copyWith(
        status: mobileProviderConversationStatusTrashed,
        deletedAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
    _setLocalizedStatusMessage(
      '${record.session.title} 已移入回收站。',
      '${record.session.title} was moved to the recycle bin.',
    );
    statusCaption = 'Mobile agents';
    _notifyStateChanged();
  }

  Future<void> restoreMobileProviderConversation(
    MobileAgentAccount account,
    String sessionId,
  ) async {
    final record = _mobileProviderConversationRecord(account, sessionId);
    if (record == null) {
      return;
    }
    await _upsertMobileProviderConversationRecord(
      record.copyWith(
        status: mobileProviderConversationStatusActive,
        deletedAt: '',
      ),
      selected: true,
    );
    _setLocalizedStatusMessage(
      '${record.session.title} 已恢复。',
      '${record.session.title} was restored.',
    );
    statusCaption = 'Mobile agents';
    _notifyStateChanged();
  }

  Future<void> _appendMobileProviderMessage({
    required MobileAgentAccount account,
    required AgentConversationMessage message,
    required String updatedAt,
  }) async {
    final existing = await _ensureMobileProviderConversation(
      account,
      updatedAt,
    );
    final messages = [...?existing?.messages, message];
    final title = _mobileProviderConversationTitle(
      existing: existing,
      account: account,
      messages: messages,
    );
    final session = AgentConversationSession(
      id: existing?.id ?? _mobileProviderSessionId(account.id),
      agentId: account.providerId,
      title: title,
      createdAt: existing?.createdAt ?? updatedAt,
      updatedAt: updatedAt,
      adapterId: 'mobile-provider',
      sourceKind: 'mobile-provider',
      sourceClient: account.id,
      sourceClientLabel: account.label,
      native: false,
      readOnly: false,
      messageCount: messages.length,
      messages: List<AgentConversationMessage>.unmodifiable(messages),
    );
    await _upsertMobileProviderConversationRecord(
      MobileProviderConversationRecord(
        accountId: account.id,
        providerId: account.providerId,
        status: mobileProviderConversationStatusActive,
        session: session,
      ),
      selected: true,
    );
    _touchMobileAgentAccount(account.id, updatedAt);
  }

  Future<AgentConversationSession?> _ensureMobileProviderConversation(
    MobileAgentAccount account,
    String now,
  ) async {
    final selected = mobileProviderConversationFor(account);
    if (selected != null) {
      return selected;
    }
    final session = AgentConversationSession(
      id: _mobileProviderSessionId(account.id),
      agentId: account.providerId,
      title: '新对话',
      createdAt: now,
      updatedAt: now,
      adapterId: 'mobile-provider',
      sourceKind: 'mobile-provider',
      sourceClient: account.id,
      sourceClientLabel: account.label,
      native: false,
      readOnly: false,
      messages: const [],
    );
    await _upsertMobileProviderConversationRecord(
      MobileProviderConversationRecord(
        accountId: account.id,
        providerId: account.providerId,
        status: mobileProviderConversationStatusActive,
        session: session,
      ),
      selected: true,
    );
    return session;
  }

  Future<void> _upsertMobileProviderConversationRecord(
    MobileProviderConversationRecord record, {
    bool selected = false,
  }) async {
    final existing =
        mobileProviderConversationRecordsByAccount[record.accountId] ??
        const [];
    final nextForAccount = <MobileProviderConversationRecord>[
      record,
      for (final item in existing)
        if (item.session.id != record.session.id) item,
    ];
    final next = <MobileProviderConversationRecord>[
      for (final entry in mobileProviderConversationRecordsByAccount.entries)
        if (entry.key != record.accountId) ...entry.value,
      ...nextForAccount,
    ];
    _applyMobileProviderConversationRecords(next);
    if (selected) {
      selectedMobileProviderConversationIds = Map<String, String>.unmodifiable({
        ...selectedMobileProviderConversationIds,
        record.accountId: record.session.id,
      });
      _syncMobileProviderConversationCompatibilityMap();
    }
    await mobileProviderConversationService.save(portableData, next);
  }

  void _applyMobileProviderConversationRecords(
    List<MobileProviderConversationRecord> records,
  ) {
    final byAccount = <String, List<MobileProviderConversationRecord>>{};
    for (final record in records) {
      byAccount.putIfAbsent(record.accountId, () => []).add(record);
    }
    mobileProviderConversationRecordsByAccount = Map.unmodifiable({
      for (final entry in byAccount.entries)
        entry.key: List<MobileProviderConversationRecord>.unmodifiable(
          entry.value,
        ),
    });
    _syncMobileProviderConversationCompatibilityMap();
  }

  void _syncMobileProviderConversationCompatibilityMap() {
    final latest = <String, AgentConversationSession>{};
    for (final entry in mobileProviderConversationRecordsByAccount.entries) {
      final selectedId = selectedMobileProviderConversationIds[entry.key] ?? '';
      MobileProviderConversationRecord? selected;
      for (final record in entry.value) {
        if (!record.isActive) {
          continue;
        }
        if (record.session.id == selectedId) {
          selected = record;
          break;
        }
        selected ??= record;
      }
      if (selected != null) {
        latest[entry.key] = selected.session;
      }
    }
    mobileProviderConversations =
        Map<String, AgentConversationSession>.unmodifiable(latest);
  }

  MobileProviderConversationRecord? _mobileProviderConversationRecord(
    MobileAgentAccount account,
    String sessionId,
  ) {
    for (final record
        in mobileProviderConversationRecordsByAccount[account.id] ?? const []) {
      if (record.session.id == sessionId) {
        return record;
      }
    }
    return null;
  }

  void _touchMobileAgentAccount(String accountId, String updatedAt) {
    mobileAgentAccounts = List<MobileAgentAccount>.unmodifiable([
      for (final account in mobileAgentAccounts)
        if (account.id == accountId)
          account.copyWith(updatedAt: updatedAt, lastUsedAt: updatedAt)
        else
          account,
    ]);
  }
}

String _mobileProviderMessageId(String accountId, String role) {
  return 'mobile-provider-$accountId-$role-${DateTime.now().toUtc().microsecondsSinceEpoch}';
}

String _mobileProviderSessionId(String accountId) {
  return 'mobile-provider-$accountId-session-${DateTime.now().toUtc().microsecondsSinceEpoch}';
}

bool _mobileAgentProviderSupportsLocalOAuthLogin(MobileAgentProvider provider) {
  return provider.supportsLocalOAuthLogin;
}

String _mobileProviderConversationTitle({
  required AgentConversationSession? existing,
  required MobileAgentAccount account,
  required List<AgentConversationMessage> messages,
}) {
  final current = existing?.title.trim() ?? '';
  if (current.isNotEmpty && current != '新对话') {
    return current;
  }
  for (final message in messages) {
    if (message.role.trim().toLowerCase() != 'user') {
      continue;
    }
    final text = message.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) {
      continue;
    }
    return text.length <= 28 ? text : '${text.substring(0, 28)}...';
  }
  return '${account.label} 新对话';
}

String _syncedMobileProviderAccountId(MobileAgentAccount account) {
  final profile = account.relayProfileId.trim().isNotEmpty
      ? account.relayProfileId.trim()
      : account.id;
  return 'mobile-synced:${_mobileAccountIdPart(account.providerId)}:${_mobileAccountIdPart(profile)}';
}

String _mobileAccountIdPart(String value) {
  final safe = value.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
  return safe.isEmpty ? 'account' : safe;
}

String _mobileRelayProviderProfileKey(String providerId, String profileId) {
  final provider = providerId.trim().toLowerCase();
  final profile = profileId.trim().isEmpty ? provider : profileId.trim();
  return '$provider:$profile';
}

String _mobileProviderConversationHandoffPrompt({
  required MobileAgentAccount account,
  required List<AgentConversationMessage> messages,
  required String prompt,
}) {
  final visible = messages
      .where((message) => message.text.trim().isNotEmpty)
      .toList(growable: false);
  final recent = visible.length > 40
      ? visible.sublist(visible.length - 40)
      : visible;
  final contextSource = account.providerId == 'chatgpt' ? '网页端' : '手机端直连';
  final buffer = StringBuffer()
    ..writeln('请基于以下 ${account.label} $contextSource对话上下文执行用户的新请求。')
    ..writeln()
    ..writeln('## ${account.label} $contextSource对话上下文');
  if (recent.isEmpty) {
    buffer.writeln('(当前没有可转交的历史消息。)');
  } else {
    for (final message in recent) {
      final role = message.role.trim().isEmpty
          ? 'message'
          : message.role.trim();
      buffer
        ..writeln('[$role]')
        ..writeln(_boundedHandoffMessageText(message.text))
        ..writeln();
    }
  }
  final trimmedPrompt = prompt.trim();
  buffer
    ..writeln('## 用户新增提示词')
    ..writeln(trimmedPrompt.isEmpty ? '请基于以上上下文继续执行。' : trimmedPrompt);
  final text = buffer.toString().trim();
  const maxChars = 24000;
  if (text.length <= maxChars) {
    return text;
  }
  return text.substring(text.length - maxChars);
}

String _boundedHandoffMessageText(String value) {
  final text = value.replaceAll(RegExp(r'\s+\n'), '\n').trim();
  const maxChars = 4000;
  if (text.length <= maxChars) {
    return text;
  }
  return '${text.substring(0, maxChars)}\n[内容已截断]';
}

String _mobileProviderReplyText(Map<String, dynamic> result) {
  final opened = _mobileProviderMap(result['result'])?['openedResult'];
  final openedMap = _mobileProviderMap(opened);
  final execution = _mobileProviderMap(openedMap?['execution']);
  final secureOutput = _mobileProviderMap(execution?['output']);
  final providerOutput = _mobileProviderMap(secureOutput?['output']);
  return _firstMobileProviderText([
    providerOutput?['content'],
    providerOutput?['output'],
    providerOutput?['response'] is Map
        ? (_mobileProviderMap(providerOutput?['response'])?['choices'] is List
              ? _chatCompletionChoiceText(providerOutput?['response'])
              : null)
        : null,
    secureOutput?['content'],
    secureOutput?['output'],
    result['content'],
    result['output'],
  ]);
}

String _mobileProviderErrorText(
  Map<String, dynamic> result,
  String providerLabel,
) {
  final opened = _mobileProviderMap(result['result'])?['openedResult'];
  final openedMap = _mobileProviderMap(opened);
  final execution = _mobileProviderMap(openedMap?['execution']);
  final secureOutput = _mobileProviderMap(execution?['output']);
  final providerOutput = _mobileProviderMap(secureOutput?['output']);
  final status = _firstMobileProviderText([
    providerOutput?['status'],
    secureOutput?['status'],
    result['status'],
  ]);
  final detail = _firstMobileProviderText([
    providerOutput?['message'],
    providerOutput?['error'],
    secureOutput?['message'],
    secureOutput?['error'],
    execution?['errorDetail'],
    result['message'],
    result['error'],
  ]);
  final errorCode = _firstMobileProviderText([
    providerOutput?['errorCode'],
    secureOutput?['errorCode'],
    result['errorCode'],
  ]);
  final statusCodes = [
    providerOutput?['statusCode'],
    secureOutput?['statusCode'],
    result['statusCode'],
  ];
  final proxyModes = [
    providerOutput?['proxyMode'],
    secureOutput?['proxyMode'],
    result['proxyMode'],
  ];
  if (status.startsWith('oauth_')) {
    final primary = detail.isNotEmpty && !detail.contains(status)
        ? '$status: $detail'
        : status;
    return _mobileProviderErrorTextWithStatusCode(
      [primary, errorCode],
      statusCodes,
      proxyModes,
    );
  }
  return _firstMobileProviderText([
        providerOutput?['message'],
        providerOutput?['error'],
        providerOutput?['errorCode'],
        providerOutput?['status'],
        providerOutput?['statusCode'],
        secureOutput?['message'],
        secureOutput?['error'],
        secureOutput?['errorCode'],
        secureOutput?['statusCode'],
        execution?['errorDetail'],
        result['message'],
        result['statusCode'],
        result['errorCode'],
        result['error'],
        result['status'],
      ]).trim().isNotEmpty
      ? _mobileProviderErrorTextWithStatusCode(
          [
            providerOutput?['message'],
            providerOutput?['error'],
            providerOutput?['errorCode'],
            providerOutput?['status'],
            secureOutput?['message'],
            secureOutput?['error'],
            secureOutput?['errorCode'],
            execution?['errorDetail'],
            result['message'],
            result['errorCode'],
            result['error'],
            result['status'],
          ],
          [
            providerOutput?['statusCode'],
            secureOutput?['statusCode'],
            result['statusCode'],
          ],
          [
            providerOutput?['proxyMode'],
            secureOutput?['proxyMode'],
            result['proxyMode'],
          ],
        )
      : _mobileProviderFallbackErrorText(providerLabel);
}

String _mobileProviderFallbackErrorText(String providerLabel) {
  return '$providerLabel 请求失败，请确认手机端已同步或配置 API Key。';
}

String _mobileProviderOAuthValidationFailureText(
  String providerLabel,
  String detail,
) {
  final trimmed = detail.trim();
  if (trimmed.isEmpty) {
    return '$providerLabel OAuth 已返回，但真实对话验证失败。';
  }
  return '$providerLabel OAuth 已返回，但真实对话验证失败：$trimmed';
}

bool _mobileProviderOAuthStatusIsFreshForPrompt(
  Map<String, dynamic> result,
  MobileAgentOAuthAuthorizationPrompt prompt,
) {
  final updatedAt = _mobileProviderEpochMillis(result['updatedAtEpochMillis']);
  if (updatedAt <= 0) {
    return false;
  }
  return updatedAt >= prompt.updatedAt.millisecondsSinceEpoch;
}

int _mobileProviderEpochMillis(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value.trim()) ?? 0;
  }
  return 0;
}

String _mobileProviderErrorTextWithStatusCode(
  List<Object?> values,
  List<Object?> statusCodes,
  List<Object?> proxyModes,
) {
  final text = _firstMobileProviderText(values);
  final statusCode = _firstMobileProviderText(statusCodes);
  final proxyMode = _mobileProviderProxyModeText(proxyModes);
  final suffix = [
    if (statusCode.isNotEmpty && !text.contains(statusCode)) statusCode,
    if (proxyMode.isNotEmpty && !text.contains(proxyMode)) 'proxy: $proxyMode',
  ].join(', ');
  if (text.isEmpty) {
    return suffix;
  }
  if (suffix.isEmpty) {
    return text;
  }
  return '$text ($suffix)';
}

String _mobileProviderProxyModeText(List<Object?> values) {
  final mode = _firstMobileProviderText(values);
  return switch (mode) {
    'direct' => mode,
    'android-system-proxy' => mode,
    'java-proxy-selector' => mode,
    _ => '',
  };
}

bool _mobileProviderAccountUsesOAuthCredential(MobileAgentAccount account) {
  if (account.authKind == MobileAgentAuthKind.oauthPkce ||
      account.usesLocalOAuth) {
    return true;
  }
  if (account.provider.authKind == MobileAgentAuthKind.oauthPkce) {
    return true;
  }
  final hint = account.credentialHint.trim().toLowerCase();
  final profileId = account.relayProfileId.trim().toLowerCase();
  return hint == 'oauth' || hint == 'oauth-pkce' || profileId.contains('oauth');
}

bool _mobileProviderErrorLooksLikeOAuthRecovery(String text) {
  final normalized = text.trim().toLowerCase();
  if (normalized.isEmpty) {
    return false;
  }
  if (normalized.contains('oauth_chat_transport_failed')) {
    return false;
  }
  if (normalized.contains('oauth_access_token_missing') ||
      normalized.contains('oauth_refresh_token_missing') ||
      normalized.contains('oauth_token_refresh_failed') ||
      normalized.contains('oauth_token_refresh_incomplete') ||
      normalized.contains('oauth_credential_unreadable') ||
      normalized.contains('oauth_credential_missing') ||
      normalized.contains('oauth_account_id_missing') ||
      normalized.contains('oauth_chat_failed')) {
    return true;
  }
  if ((normalized.contains('oauth') || normalized.contains('chatgpt')) &&
      (normalized.contains('authorization is missing') ||
          normalized.contains('credential is missing') ||
          normalized.contains('credential missing') ||
          normalized.contains('授权缺失') ||
          normalized.contains('凭据缺失'))) {
    return true;
  }
  return normalized.contains(' 401') ||
      normalized.contains('(401') ||
      normalized.contains(' 403') ||
      normalized.contains('(403') ||
      normalized.contains('unauthorized') ||
      normalized.contains('forbidden');
}

bool _mobileProviderConversationPreviewIsStaleOAuthFailure(
  MobileAgentAccount account,
  String preview,
) {
  if (!account.credentialPresent ||
      account.authState == MobileAgentAccount.authStateChatValidationFailed ||
      !_mobileProviderAccountUsesOAuthCredential(account)) {
    return false;
  }
  return _mobileProviderErrorLooksLikeOAuthRecovery(preview);
}

bool _mobileProviderErrorRequiresOAuthCredentialReset(String text) {
  final normalized = text.trim().toLowerCase();
  if (normalized.isEmpty) {
    return false;
  }
  if (normalized.contains('oauth_access_token_missing') ||
      normalized.contains('oauth_refresh_token_missing') ||
      normalized.contains('oauth_token_refresh_failed') ||
      normalized.contains('oauth_token_refresh_incomplete') ||
      normalized.contains('oauth_credential_unreadable') ||
      normalized.contains('oauth_credential_missing') ||
      normalized.contains('oauth_account_id_missing')) {
    return true;
  }
  if ((normalized.contains('oauth') || normalized.contains('chatgpt')) &&
      (normalized.contains('authorization is missing') ||
          normalized.contains('credential is missing') ||
          normalized.contains('credential missing') ||
          normalized.contains('授权缺失') ||
          normalized.contains('凭据缺失'))) {
    return true;
  }
  return normalized.contains(' 401') ||
      normalized.contains('(401') ||
      normalized.contains('unauthorized');
}

String _mobileAgentOAuthPromptKey(String providerId, String mobileAccountId) {
  return '${providerId.trim().toLowerCase()}::${mobileAccountId.trim()}';
}

const String _mobileAgentOAuthValidationPrompt =
    'Reply with exactly: Lico Arc OAuth OK';

String _firstMobileProviderText(List<Object?> values) {
  for (final value in values) {
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    if (value is num) {
      return value.toString();
    }
  }
  return '';
}

String _chatCompletionChoiceText(Object? response) {
  final responseMap = _mobileProviderMap(response);
  final choices = responseMap?['choices'];
  if (choices is! List || choices.isEmpty) {
    return '';
  }
  final first = _mobileProviderMap(choices.first);
  final message = _mobileProviderMap(first?['message']);
  final content = message?['content'];
  return content is String ? content.trim() : '';
}

Map<String, dynamic>? _mobileProviderMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return null;
}

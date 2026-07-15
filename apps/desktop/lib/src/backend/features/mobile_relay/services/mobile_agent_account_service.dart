import 'package:flutter_client/src/contracts/mobile_agent_account.dart';

class MobileAgentAccountService {
  const MobileAgentAccountService({required MobileAgentAccountStore store})
    : _store = store;

  final MobileAgentAccountStore _store;

  Future<List<MobileAgentAccount>> load(Object portableData) async {
    try {
      final json = await _store.read(portableData);
      final rawAccounts = json is Map
          ? json['accounts']
          : json is List
          ? json
          : const [];
      if (rawAccounts is! List) {
        return const [];
      }
      final accounts = rawAccounts
          .whereType<Map>()
          .map(
            (item) =>
                MobileAgentAccount.fromJson(Map<String, dynamic>.from(item)),
          )
          .where((account) => account.providerId.trim().isNotEmpty)
          .toList(growable: false);
      final migrated = migrateProviderShapedAccounts(accounts);
      final normalized = ensureActiveAccountsPerProvider(
        _dropDefaultBlankDraftsWhenConfigured(migrated),
      );
      final needsRewrite =
          normalized.length != accounts.length ||
          !_accountsEqualForPersistence(accounts, normalized) ||
          (json is Map &&
              (json['schemaVersion'] as num?)?.toInt() !=
                  MobileAgentAccount.currentSchemaVersion);
      if (needsRewrite) {
        await save(portableData, normalized);
      }
      return List.unmodifiable(normalized);
    } catch (_) {
      return const [];
    }
  }

  Future<List<MobileAgentAccount>> addProvider(
    Object portableData,
    String providerId,
  ) async {
    final provider = mobileAgentProviderFor(providerId);
    final accounts = await load(portableData);
    final reusable = _firstBlankLocalAccount(accounts, provider.id);
    if (reusable != null) {
      return accounts;
    }
    final next = ensureActiveAccountsPerProvider([
      ...accounts,
      MobileAgentAccount.create(
        provider,
        id: _nextLocalAccountId(provider.id, accounts),
        label: _nextAccountLabel(provider, accounts),
        authSource: provider.authKind == MobileAgentAuthKind.oauthPkce
            ? MobileAgentAccount.authSourceLocalOAuth
            : MobileAgentAccount.authSourceLocalApiKey,
        authKind: provider.authKind,
        sourceMode: MobileAgentSourceMode.mobileLocal,
        active: !accounts.any((account) => account.providerId == provider.id),
      ),
    ]);
    await save(portableData, next);
    return List.unmodifiable(next);
  }

  Future<String> resolveWritableAccountId(
    Object portableData,
    String providerId, {
    String accountId = '',
  }) async {
    final provider = mobileAgentProviderFor(providerId);
    final accounts = await load(portableData);
    final normalizedAccountId = accountId.trim();
    if (normalizedAccountId.isNotEmpty) {
      return normalizedAccountId;
    }
    final active = activeMobileAgentAccountForProvider(accounts, provider.id);
    if (active != null &&
        !active.usesDesktopRelay &&
        !active.credentialPresent) {
      return active.id;
    }
    final blank = _firstBlankLocalAccount(accounts, provider.id);
    if (blank != null) {
      return blank.id;
    }
    return _nextLocalAccountId(provider.id, accounts);
  }

  Future<List<MobileAgentAccount>> setActiveAccount(
    Object portableData,
    String accountId,
  ) async {
    final resolvedAccountId = accountId.trim();
    if (resolvedAccountId.isEmpty) {
      return load(portableData);
    }
    final accounts = await load(portableData);
    MobileAgentAccount? target;
    for (final account in accounts) {
      if (account.id == resolvedAccountId) {
        target = account;
        break;
      }
    }
    if (target == null) {
      return accounts;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final next = [
      for (final account in accounts)
        if (account.providerId == target.providerId)
          account.copyWith(
            active: account.id == resolvedAccountId,
            updatedAt: account.id == resolvedAccountId
                ? now
                : account.updatedAt,
          )
        else
          account,
    ];
    final immutable = List<MobileAgentAccount>.unmodifiable(next);
    await save(portableData, immutable);
    return immutable;
  }

  Future<List<MobileAgentAccount>> renameAccount(
    Object portableData,
    String accountId,
    String label,
  ) async {
    final resolvedAccountId = accountId.trim();
    final nextLabel = label.trim();
    if (resolvedAccountId.isEmpty || nextLabel.isEmpty) {
      return load(portableData);
    }
    final accounts = await load(portableData);
    final now = DateTime.now().toUtc().toIso8601String();
    var changed = false;
    final next = [
      for (final account in accounts)
        if (account.id == resolvedAccountId) ...[
          account.copyWith(label: nextLabel, updatedAt: now),
        ] else
          account,
    ];
    changed = next.any(
      (account) =>
          account.id == resolvedAccountId && account.label == nextLabel,
    );
    if (!changed) {
      return accounts;
    }
    final immutable = List<MobileAgentAccount>.unmodifiable(next);
    await save(portableData, immutable);
    return immutable;
  }

  Future<List<MobileAgentAccount>> updateAssistantGrants(
    Object portableData,
    String accountId,
    MobileAgentAssistantGrants grants,
  ) async {
    final resolvedAccountId = accountId.trim();
    if (resolvedAccountId.isEmpty) {
      return load(portableData);
    }
    final accounts = await load(portableData);
    final now = DateTime.now().toUtc().toIso8601String();
    var changed = false;
    final next = [
      for (final account in accounts)
        if (account.id == resolvedAccountId) ...[
          account.copyWith(assistantGrants: grants, updatedAt: now),
        ] else
          account,
    ];
    changed = next.any((account) => account.id == resolvedAccountId);
    if (!changed) {
      return accounts;
    }
    final immutable = List<MobileAgentAccount>.unmodifiable(next);
    await save(portableData, immutable);
    return immutable;
  }

  Future<List<MobileAgentAccount>> touchAccount(
    Object portableData,
    String accountId, {
    String? lastUsedAt,
  }) async {
    final resolvedAccountId = accountId.trim();
    if (resolvedAccountId.isEmpty) {
      return load(portableData);
    }
    final accounts = await load(portableData);
    final now = lastUsedAt?.trim().isNotEmpty == true
        ? lastUsedAt!.trim()
        : DateTime.now().toUtc().toIso8601String();
    final next = [
      for (final account in accounts)
        if (account.id == resolvedAccountId)
          account.copyWith(updatedAt: now, lastUsedAt: now)
        else
          account,
    ];
    if (!next.any((account) => account.id == resolvedAccountId)) {
      return accounts;
    }
    final immutable = List<MobileAgentAccount>.unmodifiable(next);
    await save(portableData, immutable);
    return immutable;
  }

  Future<List<MobileAgentAccount>> configureApiCredential(
    Object portableData,
    String providerId,
    String secret, {
    String accountId = '',
    String label = '',
  }) async {
    final trimmed = secret.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(providerId, 'providerId');
    }
    final provider = mobileAgentProviderFor(providerId);
    final accounts = await load(portableData);
    final resolvedAccountId = accountId.trim().isNotEmpty
        ? accountId.trim()
        : await resolveWritableAccountId(portableData, provider.id);
    final now = DateTime.now().toUtc().toIso8601String();
    final credentialRef = mobileAgentCredentialRef(
      providerId: provider.id,
      accountId: resolvedAccountId,
      authKind: MobileAgentAuthKind.apiKey,
    );
    var updated = false;
    final next = [
      for (final account in accounts)
        if (account.id == resolvedAccountId)
          account.copyWith(
            label: label.trim().isEmpty ? null : label.trim(),
            authState: MobileAgentAccount.authStateConfigured,
            credentialPresent: true,
            credentialHint: _credentialHint(trimmed),
            credentialRef: credentialRef,
            authSource: MobileAgentAccount.authSourceLocalApiKey,
            sourceMode: MobileAgentSourceMode.mobileLocal,
            authKind: MobileAgentAuthKind.apiKey,
            relayDeviceLabel: '',
            active: true,
            updatedAt: now,
          )
        else if (account.providerId == provider.id)
          account.copyWith(active: false)
        else
          account,
    ];
    updated = next.any((account) => account.id == resolvedAccountId);
    final configured = updated
        ? next
        : [
            ...[
              for (final account in accounts)
                if (account.providerId == provider.id)
                  account.copyWith(active: false)
                else
                  account,
            ],
            MobileAgentAccount.create(
              provider,
              id: resolvedAccountId,
              label: label.trim().isEmpty
                  ? _nextAccountLabel(provider, accounts)
                  : label.trim(),
              active: true,
            ).copyWith(
              authState: MobileAgentAccount.authStateConfigured,
              credentialPresent: true,
              credentialHint: _credentialHint(trimmed),
              credentialRef: credentialRef,
              authSource: MobileAgentAccount.authSourceLocalApiKey,
              sourceMode: MobileAgentSourceMode.mobileLocal,
              authKind: MobileAgentAuthKind.apiKey,
              relayDeviceLabel: '',
              updatedAt: now,
            ),
          ];
    final immutable = List<MobileAgentAccount>.unmodifiable(
      ensureActiveAccountsPerProvider(
        _withoutBlankLocalProviderDrafts(
          configured,
          provider.id,
          exceptAccountId: resolvedAccountId,
        ),
      ),
    );
    await save(portableData, immutable);
    return immutable;
  }

  Future<List<MobileAgentAccount>> markApiCredentialPresent(
    Object portableData,
    String providerId, {
    String accountId = '',
    String label = '',
    String credentialHint = '',
    String authSource = MobileAgentAccount.authSourceLocalApiKey,
    String relayDeviceLabel = '',
    String relayProfileId = '',
  }) async {
    final provider = mobileAgentProviderFor(providerId);
    final accounts = await load(portableData);
    final resolvedAccountId = accountId.trim().isNotEmpty
        ? accountId.trim()
        : await resolveWritableAccountId(portableData, provider.id);
    final now = DateTime.now().toUtc().toIso8601String();
    final sourceMode = sourceModeForAuthSource(authSource);
    final authKind = authKindForProviderAndSource(provider, authSource);
    final credentialRef = mobileAgentCredentialRef(
      providerId: provider.id,
      accountId: resolvedAccountId,
      authKind: authKind,
    );
    var updated = false;
    final next = [
      for (final account in accounts)
        if (account.id == resolvedAccountId)
          account.copyWith(
            label: label.trim().isEmpty ? null : label.trim(),
            authState: MobileAgentAccount.authStateConfigured,
            credentialPresent: true,
            credentialHint: credentialHint.trim(),
            credentialRef: credentialRef,
            authSource: authSource,
            sourceMode: sourceMode,
            authKind: authKind,
            relayDeviceLabel: relayDeviceLabel.trim(),
            relayProfileId: relayProfileId,
            active: true,
            updatedAt: now,
          )
        else if (account.providerId == provider.id)
          account.copyWith(active: false)
        else
          account,
    ];
    updated = next.any((account) => account.id == resolvedAccountId);
    final configured = updated
        ? next
        : [
            ...[
              for (final account in accounts)
                if (account.providerId == provider.id)
                  account.copyWith(active: false)
                else
                  account,
            ],
            MobileAgentAccount.create(
              provider,
              id: resolvedAccountId,
              label: label.trim().isEmpty
                  ? _nextAccountLabel(provider, accounts)
                  : label.trim(),
              active: true,
            ).copyWith(
              authState: MobileAgentAccount.authStateConfigured,
              credentialPresent: true,
              credentialHint: credentialHint.trim(),
              credentialRef: credentialRef,
              authSource: authSource,
              sourceMode: sourceMode,
              authKind: authKind,
              relayDeviceLabel: relayDeviceLabel.trim(),
              relayProfileId: relayProfileId,
              updatedAt: now,
            ),
          ];
    final immutable = List<MobileAgentAccount>.unmodifiable(
      ensureActiveAccountsPerProvider(
        _withoutBlankLocalProviderDrafts(
          configured,
          provider.id,
          exceptAccountId: resolvedAccountId,
        ),
      ),
    );
    await save(portableData, immutable);
    return immutable;
  }

  Future<List<MobileAgentAccount>> markOAuthCredentialPresent(
    Object portableData,
    String providerId, {
    String accountId = '',
    String label = '',
    String credentialHint = 'OAuth',
    String authSource = MobileAgentAccount.authSourceLocalOAuth,
    String relayDeviceLabel = '',
    String relayProfileId = '',
    MobileAgentAccountOAuthMeta oauth = const MobileAgentAccountOAuthMeta(),
  }) async {
    final provider = mobileAgentProviderFor(providerId);
    final accounts = await load(portableData);
    final resolvedAccountId = accountId.trim().isNotEmpty
        ? accountId.trim()
        : await resolveWritableAccountId(portableData, provider.id);
    final now = DateTime.now().toUtc().toIso8601String();
    final credentialRef = mobileAgentCredentialRef(
      providerId: provider.id,
      accountId: resolvedAccountId,
      authKind: MobileAgentAuthKind.oauthPkce,
    );
    final oauthMeta = oauth.isEmpty
        ? MobileAgentAccountOAuthMeta(
            issuer: provider.oauthDescriptor.issuer,
            clientIdRef: provider.oauthDescriptor.clientIdRef,
            scopes: provider.oauthDescriptor.scopes,
          )
        : oauth;
    var updated = false;
    final next = [
      for (final account in accounts)
        if (account.id == resolvedAccountId)
          account.copyWith(
            label: label.trim().isEmpty ? null : label.trim(),
            authState: MobileAgentAccount.authStateConfigured,
            credentialPresent: true,
            credentialHint: credentialHint.trim(),
            credentialRef: credentialRef,
            authSource: authSource,
            sourceMode: sourceModeForAuthSource(authSource),
            authKind: MobileAgentAuthKind.oauthPkce,
            relayDeviceLabel: relayDeviceLabel.trim(),
            relayProfileId: relayProfileId,
            oauth: oauthMeta,
            active: true,
            updatedAt: now,
          )
        else if (account.providerId == provider.id)
          account.copyWith(active: false)
        else
          account,
    ];
    updated = next.any((account) => account.id == resolvedAccountId);
    final configured = updated
        ? next
        : [
            ...[
              for (final account in accounts)
                if (account.providerId == provider.id)
                  account.copyWith(active: false)
                else
                  account,
            ],
            MobileAgentAccount.create(
              provider,
              id: resolvedAccountId,
              label: label.trim().isEmpty
                  ? _nextAccountLabel(provider, accounts)
                  : label.trim(),
              active: true,
            ).copyWith(
              authState: MobileAgentAccount.authStateConfigured,
              credentialPresent: true,
              credentialHint: credentialHint.trim(),
              credentialRef: credentialRef,
              authSource: authSource,
              sourceMode: sourceModeForAuthSource(authSource),
              authKind: MobileAgentAuthKind.oauthPkce,
              relayDeviceLabel: relayDeviceLabel.trim(),
              relayProfileId: relayProfileId,
              oauth: oauthMeta,
              updatedAt: now,
            ),
          ];
    final immutable = List<MobileAgentAccount>.unmodifiable(
      ensureActiveAccountsPerProvider(
        _withoutBlankLocalProviderDrafts(
          configured,
          provider.id,
          exceptAccountId: resolvedAccountId,
        ),
      ),
    );
    await save(portableData, immutable);
    return immutable;
  }

  Future<List<MobileAgentAccount>> markAuthorizationRequired(
    Object portableData,
    String accountId, {
    String credentialHint = '',
  }) async {
    final resolvedAccountId = accountId.trim();
    if (resolvedAccountId.isEmpty) {
      return load(portableData);
    }
    final accounts = await load(portableData);
    final now = DateTime.now().toUtc().toIso8601String();
    var changed = false;
    final next = [
      for (final account in accounts)
        if (account.id == resolvedAccountId) ...[
          account.copyWith(
            authState: MobileAgentAccount.authStateAuthorizationRequired,
            credentialPresent: false,
            credentialHint: credentialHint.trim(),
            updatedAt: now,
          ),
        ] else
          account,
    ];
    changed = next.any(
      (account) =>
          account.id == resolvedAccountId && !account.credentialPresent,
    );
    if (changed) {
      final immutable = List<MobileAgentAccount>.unmodifiable(next);
      await save(portableData, immutable);
      return immutable;
    }
    return accounts;
  }

  Future<List<MobileAgentAccount>> markOAuthConversationValidationFailed(
    Object portableData,
    String providerId, {
    String accountId = '',
    String label = '',
    String credentialHint = 'OAuth',
    String authSource = MobileAgentAccount.authSourceLocalOAuth,
    String relayDeviceLabel = '',
    String relayProfileId = '',
  }) async {
    final provider = mobileAgentProviderFor(providerId);
    final accounts = await load(portableData);
    final resolvedAccountId = accountId.trim().isNotEmpty
        ? accountId.trim()
        : await resolveWritableAccountId(portableData, provider.id);
    final now = DateTime.now().toUtc().toIso8601String();
    final credentialRef = mobileAgentCredentialRef(
      providerId: provider.id,
      accountId: resolvedAccountId,
      authKind: MobileAgentAuthKind.oauthPkce,
    );
    var updated = false;
    final next = [
      for (final account in accounts)
        if (account.id == resolvedAccountId)
          account.copyWith(
            label: label.trim().isEmpty ? null : label.trim(),
            authState: MobileAgentAccount.authStateChatValidationFailed,
            credentialPresent: true,
            credentialHint: credentialHint.trim().isEmpty
                ? 'OAuth'
                : credentialHint.trim(),
            credentialRef: credentialRef,
            authSource: authSource,
            sourceMode: sourceModeForAuthSource(authSource),
            authKind: MobileAgentAuthKind.oauthPkce,
            relayDeviceLabel: relayDeviceLabel.trim(),
            relayProfileId: relayProfileId,
            updatedAt: now,
          )
        else
          account,
    ];
    updated = next.any((account) => account.id == resolvedAccountId);
    final configured = updated
        ? next
        : [
            ...accounts,
            MobileAgentAccount.create(
              provider,
              id: resolvedAccountId,
              label: label.trim().isEmpty
                  ? _nextAccountLabel(provider, accounts)
                  : label.trim(),
              authSource: authSource,
              credentialPresent: true,
              credentialHint: credentialHint.trim().isEmpty
                  ? 'OAuth'
                  : credentialHint.trim(),
              credentialRef: credentialRef,
              relayDeviceLabel: relayDeviceLabel.trim(),
              relayProfileId: relayProfileId,
            ).copyWith(
              authState: MobileAgentAccount.authStateChatValidationFailed,
              updatedAt: now,
            ),
          ];
    final immutable = List<MobileAgentAccount>.unmodifiable(
      _withoutBlankLocalProviderDrafts(
        configured,
        provider.id,
        exceptAccountId: resolvedAccountId,
      ),
    );
    await save(portableData, immutable);
    return immutable;
  }

  Future<List<MobileAgentAccount>> updateGenerationOptions(
    Object portableData,
    String accountId, {
    String? selectedModel,
    String? reasoningEffort,
    MobileAgentAccount? seedAccount,
  }) async {
    final resolvedAccountId = accountId.trim();
    if (resolvedAccountId.isEmpty) {
      return load(portableData);
    }
    final accounts = await load(portableData);
    final now = DateTime.now().toUtc().toIso8601String();
    var updated = false;
    final next = <MobileAgentAccount>[];
    for (final account in accounts) {
      if (account.id == resolvedAccountId) {
        final base = seedAccount != null && seedAccount.id == account.id
            ? seedAccount
            : account;
        next.add(
          base.copyWith(
            selectedModel: selectedModel,
            reasoningEffort: reasoningEffort,
            updatedAt: now,
          ),
        );
        updated = true;
      } else {
        next.add(account);
      }
    }
    if (!updated &&
        seedAccount != null &&
        seedAccount.id.trim() == resolvedAccountId) {
      next.add(
        seedAccount.copyWith(
          selectedModel: selectedModel,
          reasoningEffort: reasoningEffort,
          updatedAt: now,
        ),
      );
      updated = true;
    }
    if (!updated) {
      return accounts;
    }
    final immutable = List<MobileAgentAccount>.unmodifiable(next);
    await save(portableData, immutable);
    return immutable;
  }

  Future<List<MobileAgentAccount>> removeAccounts(
    Object portableData,
    Iterable<String> accountIds,
  ) async {
    final ids = accountIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) {
      return load(portableData);
    }
    final accounts = await load(portableData);
    final removedProviders = {
      for (final account in accounts)
        if (ids.contains(account.id)) account.providerId,
    };
    final next = ensureActiveAccountsPerProvider([
      for (final account in accounts)
        if (!ids.contains(account.id)) account,
    ]);
    // Re-assert active selection for providers that lost their active account.
    final repaired = [
      for (final account in next)
        if (removedProviders.contains(account.providerId) &&
            !next.any(
              (candidate) =>
                  candidate.providerId == account.providerId &&
                  candidate.active,
            ))
          account
        else
          account,
    ];
    final immutable = List<MobileAgentAccount>.unmodifiable(
      ensureActiveAccountsPerProvider(repaired),
    );
    if (immutable.length != accounts.length) {
      await save(portableData, immutable);
    }
    return immutable;
  }

  Future<void> save(
    Object portableData,
    List<MobileAgentAccount> accounts,
  ) async {
    final sanitized = [
      for (final account in accounts) _sanitizeForPortablePersistence(account),
    ];
    await _store.write(portableData, {
      'schemaVersion': MobileAgentAccount.currentSchemaVersion,
      'accounts': sanitized.map((account) => account.toJson()).toList(),
    });
  }
}

/// Migrates provider-shaped records (id == providerId, missing account fields)
/// into account-shaped metadata without inventing secrets.
List<MobileAgentAccount> migrateProviderShapedAccounts(
  List<MobileAgentAccount> accounts,
) {
  if (accounts.isEmpty) {
    return accounts;
  }
  final migrated = <MobileAgentAccount>[];
  for (final account in accounts) {
    final needsCredentialRef = account.credentialRef.trim().isEmpty;
    final needsSourceMode =
        account.sourceMode == MobileAgentSourceMode.mobileLocal &&
        account.authSource != MobileAgentAccount.authSourceLocalApiKey &&
        account.authSource != MobileAgentAccount.authSourceLocalOAuth;
    if (!needsCredentialRef && !needsSourceMode) {
      migrated.add(account);
      continue;
    }
    migrated.add(
      account.copyWith(
        credentialRef: needsCredentialRef
            ? mobileAgentCredentialRef(
                providerId: account.providerId,
                accountId: account.id,
                authKind: account.authKind,
              )
            : account.credentialRef,
        sourceMode: sourceModeForAuthSource(account.authSource),
        authKind: authKindForProviderAndSource(
          account.provider,
          account.authSource,
        ),
      ),
    );
  }
  return ensureActiveAccountsPerProvider(migrated);
}

MobileAgentAccount _sanitizeForPortablePersistence(MobileAgentAccount account) {
  // Strip anything that could look like secret material from portable JSON.
  final hint = account.credentialHint.trim();
  final safeHint = _looksLikeSecret(hint) ? _credentialHint(hint) : hint;
  final oauthHint = account.oauth.providerAccountHint.trim();
  return account.copyWith(
    credentialHint: safeHint,
    oauth: account.oauth.isEmpty
        ? account.oauth
        : MobileAgentAccountOAuthMeta(
            issuer: account.oauth.issuer,
            clientIdRef: account.oauth.clientIdRef,
            scopes: account.oauth.scopes,
            providerAccountHint: oauthHint.contains('@')
                ? oauthHint
                : account.oauth.providerAccountHint,
            expiresAt: account.oauth.expiresAt,
          ),
  );
}

bool _looksLikeSecret(String value) {
  final compact = value.replaceAll(RegExp(r'\s+'), '');
  if (compact.length >= 20 && !compact.startsWith('****')) {
    return true;
  }
  final lower = compact.toLowerCase();
  return lower.startsWith('sk-') ||
      lower.startsWith('eyj') ||
      lower.contains('access_token') ||
      lower.contains('refresh_token');
}

String _credentialHint(String value) {
  final compact = value.replaceAll(RegExp(r'\s+'), '');
  if (compact.length <= 4) {
    return '****';
  }
  return '**** ${compact.substring(compact.length - 4)}';
}

MobileAgentAccount? _firstBlankLocalAccount(
  List<MobileAgentAccount> accounts,
  String providerId,
) {
  for (final account in accounts) {
    if (account.providerId == providerId &&
        !account.usesDesktopRelay &&
        !account.credentialPresent) {
      return account;
    }
  }
  return null;
}

List<MobileAgentAccount> _withoutBlankLocalProviderDrafts(
  List<MobileAgentAccount> accounts,
  String providerId, {
  required String exceptAccountId,
}) {
  return accounts
      .where(
        (account) =>
            account.id == exceptAccountId ||
            account.providerId != providerId ||
            !_isBlankLocalProviderDraft(account),
      )
      .toList(growable: false);
}

bool _isBlankLocalProviderDraft(MobileAgentAccount account) {
  return !account.credentialPresent &&
      account.usesMobileLocal &&
      (account.authSource == MobileAgentAccount.authSourceLocalApiKey ||
          account.authSource == MobileAgentAccount.authSourceLocalOAuth);
}

List<MobileAgentAccount> _dropDefaultBlankDraftsWhenConfigured(
  List<MobileAgentAccount> accounts,
) {
  final configuredProviderIds = accounts
      .where((account) => account.credentialPresent)
      .map((account) => account.providerId)
      .toSet();
  if (configuredProviderIds.isEmpty) {
    return accounts;
  }
  return accounts
      .where(
        (account) =>
            !configuredProviderIds.contains(account.providerId) ||
            !_isBlankLocalProviderDraft(account),
      )
      .toList(growable: false);
}

String _nextLocalAccountId(
  String providerId,
  List<MobileAgentAccount> accounts,
) {
  final existing = accounts.map((account) => account.id).toSet();
  var candidate = generateMobileAgentAccountId(providerId);
  var suffix = 2;
  while (existing.contains(candidate)) {
    candidate = '${generateMobileAgentAccountId(providerId)}-$suffix';
    suffix++;
  }
  return candidate;
}

String _nextAccountLabel(
  MobileAgentProvider provider,
  List<MobileAgentAccount> accounts,
) {
  final count = accounts
      .where(
        (account) =>
            account.providerId == provider.id && !account.usesDesktopRelay,
      )
      .length;
  return count == 0 ? provider.label : '${provider.label} ${count + 1}';
}

bool _accountsEqualForPersistence(
  List<MobileAgentAccount> left,
  List<MobileAgentAccount> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    final a = left[i];
    final b = right[i];
    if (a.id != b.id ||
        a.providerId != b.providerId ||
        a.credentialRef != b.credentialRef ||
        a.sourceMode != b.sourceMode ||
        a.authKind != b.authKind ||
        a.active != b.active) {
      return false;
    }
  }
  return true;
}

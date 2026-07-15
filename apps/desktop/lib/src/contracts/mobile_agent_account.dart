import 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';

const mobileAgentProviders = <MobileAgentProvider>[
  MobileAgentProvider(
    id: 'chatgpt',
    label: 'ChatGPT',
    authKind: MobileAgentAuthKind.oauthPkce,
    docsUrl: 'https://developers.openai.com/codex/auth',
    oauthDocsUrl: 'https://developers.openai.com/codex/auth',
    defaultModel: 'gpt-5.5',
    modelOptions: [
      MobileAgentGenerationOption(id: 'gpt-5.5', label: 'GPT-5.5'),
      MobileAgentGenerationOption(id: 'gpt-5.4', label: 'GPT-5.4'),
      MobileAgentGenerationOption(id: 'gpt-5.4-mini', label: 'GPT-5.4 Mini'),
      MobileAgentGenerationOption(id: 'gpt-5.4-nano', label: 'GPT-5.4 Nano'),
    ],
    reasoningEffortOptions: [
      MobileAgentGenerationOption(id: '', label: 'Auto'),
      MobileAgentGenerationOption(id: 'low', label: 'Low'),
      MobileAgentGenerationOption(id: 'medium', label: 'Medium'),
      MobileAgentGenerationOption(id: 'high', label: 'High'),
    ],
    supportsDirectChat: true,
    supportsDesktopRelay: true,
    supportsPhoneAssistant: true,
    localOAuthAvailability: MobileAgentLocalOAuthAvailability.supported,
    requiresOAuthDescriptor: true,
    oauthDescriptor: MobileAgentOAuthDescriptor(
      issuer: 'https://auth.openai.com',
      authorizeUrl: 'https://auth.openai.com/oauth/authorize',
      tokenUrl: 'https://auth.openai.com/oauth/token',
      clientIdRef: 'chatgpt-oauth-client',
      scopes: ['openid', 'profile', 'email', 'offline_access'],
      redirectBehavior: 'loopback-http',
      refreshBehavior: 'refresh-token',
      complete: true,
    ),
  ),
  MobileAgentProvider(
    id: 'gemini',
    label: 'Gemini',
    authKind: MobileAgentAuthKind.oauthPkce,
    docsUrl: 'https://ai.google.dev/gemini-api/docs',
    localOAuthAvailability: MobileAgentLocalOAuthAvailability.deferred,
    defaultModel: 'gemini-3.5-flash',
    modelOptions: [
      MobileAgentGenerationOption(
        id: 'gemini-3.5-flash',
        label: 'Gemini 3.5 Flash',
      ),
      MobileAgentGenerationOption(
        id: 'gemini-3.5-pro',
        label: 'Gemini 3.5 Pro',
      ),
      MobileAgentGenerationOption(
        id: 'gemini-3-flash',
        label: 'Gemini 3 Flash',
      ),
      MobileAgentGenerationOption(id: 'gemini-3-pro', label: 'Gemini 3 Pro'),
    ],
    reasoningEffortOptions: [
      MobileAgentGenerationOption(id: '', label: 'Auto'),
      MobileAgentGenerationOption(id: 'low', label: 'Low'),
      MobileAgentGenerationOption(id: 'medium', label: 'Medium'),
      MobileAgentGenerationOption(id: 'high', label: 'High'),
    ],
    supportsDirectChat: true,
    supportsDesktopRelay: true,
    supportsPhoneAssistant: true,
  ),
  MobileAgentProvider(
    id: 'kimi',
    label: 'Kimi',
    authKind: MobileAgentAuthKind.oauthPkce,
    docsUrl: 'https://platform.kimi.ai/docs/api/overview',
    localOAuthAvailability: MobileAgentLocalOAuthAvailability.deferred,
    defaultModel: 'kimi-k2.6',
    modelOptions: [
      MobileAgentGenerationOption(id: 'kimi-k2.6', label: 'Kimi K2.6'),
      MobileAgentGenerationOption(id: 'kimi-k2', label: 'Kimi K2'),
      MobileAgentGenerationOption(
        id: 'moonshot-v1-auto',
        label: 'Moonshot v1 Auto',
      ),
    ],
    reasoningEffortOptions: [
      MobileAgentGenerationOption(id: '', label: 'Auto'),
      MobileAgentGenerationOption(id: 'enabled', label: 'Enabled'),
      MobileAgentGenerationOption(id: 'disabled', label: 'Disabled'),
    ],
    supportsDirectChat: true,
    supportsDesktopRelay: true,
    supportsPhoneAssistant: true,
  ),
  MobileAgentProvider(
    id: 'deepseek',
    label: 'DeepSeek',
    authKind: MobileAgentAuthKind.apiKey,
    docsUrl: 'https://api-docs.deepseek.com/api/deepseek-api',
    credentialUrl: 'https://platform.deepseek.com/api_keys',
    defaultModel: 'deepseek-v4-flash',
    modelOptions: [
      MobileAgentGenerationOption(
        id: 'deepseek-v4-flash',
        label: 'DeepSeek V4 Flash',
      ),
      MobileAgentGenerationOption(
        id: 'deepseek-v4-pro',
        label: 'DeepSeek V4 Pro',
      ),
      MobileAgentGenerationOption(id: 'deepseek-chat', label: 'DeepSeek Chat'),
      MobileAgentGenerationOption(
        id: 'deepseek-reasoner',
        label: 'DeepSeek Reasoner',
      ),
    ],
    reasoningEffortOptions: [
      MobileAgentGenerationOption(id: '', label: 'Auto'),
      MobileAgentGenerationOption(id: 'low', label: 'Low'),
      MobileAgentGenerationOption(id: 'medium', label: 'Medium'),
      MobileAgentGenerationOption(id: 'high', label: 'High'),
    ],
    supportsDirectChat: true,
    supportsDesktopRelay: true,
    supportsPhoneAssistant: true,
    requiresOAuthDescriptor: false,
  ),
];

enum MobileAgentAuthKind { oauthPkce, apiKey, desktopRelay }

enum MobileAgentLocalOAuthAvailability { supported, deferred, notApplicable }

enum MobileAgentSourceMode { mobileLocal, mobileSynced, desktopRelay }

class MobileAgentOAuthDescriptor {
  const MobileAgentOAuthDescriptor({
    required this.issuer,
    required this.authorizeUrl,
    required this.tokenUrl,
    required this.clientIdRef,
    required this.scopes,
    required this.redirectBehavior,
    required this.refreshBehavior,
    required this.complete,
  });

  const MobileAgentOAuthDescriptor.incomplete({this.clientIdRef = ''})
    : issuer = '',
      authorizeUrl = '',
      tokenUrl = '',
      scopes = const [],
      redirectBehavior = '',
      refreshBehavior = '',
      complete = false;

  final String issuer;
  final String authorizeUrl;
  final String tokenUrl;
  final String clientIdRef;
  final List<String> scopes;
  final String redirectBehavior;
  final String refreshBehavior;
  final bool complete;

  bool get isUsable =>
      complete &&
      issuer.trim().isNotEmpty &&
      authorizeUrl.trim().isNotEmpty &&
      tokenUrl.trim().isNotEmpty &&
      clientIdRef.trim().isNotEmpty;
}

class MobileAgentAssistantGrants {
  const MobileAgentAssistantGrants({
    this.localInfo = false,
    this.accessibility = false,
    this.fileContext = false,
    this.clipboardContext = false,
    this.notificationContext = false,
  });

  static const disabled = MobileAgentAssistantGrants();

  final bool localInfo;
  final bool accessibility;
  final bool fileContext;
  final bool clipboardContext;
  final bool notificationContext;

  bool get anyEnabled =>
      localInfo ||
      accessibility ||
      fileContext ||
      clipboardContext ||
      notificationContext;

  MobileAgentAssistantGrants copyWith({
    bool? localInfo,
    bool? accessibility,
    bool? fileContext,
    bool? clipboardContext,
    bool? notificationContext,
  }) {
    return MobileAgentAssistantGrants(
      localInfo: localInfo ?? this.localInfo,
      accessibility: accessibility ?? this.accessibility,
      fileContext: fileContext ?? this.fileContext,
      clipboardContext: clipboardContext ?? this.clipboardContext,
      notificationContext: notificationContext ?? this.notificationContext,
    );
  }

  factory MobileAgentAssistantGrants.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return disabled;
    }
    return MobileAgentAssistantGrants(
      localInfo: json['localInfo'] == true,
      accessibility: json['accessibility'] == true,
      fileContext: json['fileContext'] == true,
      clipboardContext: json['clipboardContext'] == true,
      notificationContext: json['notificationContext'] == true,
    );
  }

  Map<String, dynamic>? toJson() {
    if (!anyEnabled) {
      return null;
    }
    return {
      if (localInfo) 'localInfo': true,
      if (accessibility) 'accessibility': true,
      if (fileContext) 'fileContext': true,
      if (clipboardContext) 'clipboardContext': true,
      if (notificationContext) 'notificationContext': true,
    };
  }
}

class MobileAgentAccountOAuthMeta {
  const MobileAgentAccountOAuthMeta({
    this.issuer = '',
    this.clientIdRef = '',
    this.scopes = const [],
    this.providerAccountHint = '',
    this.expiresAt = '',
  });

  final String issuer;
  final String clientIdRef;
  final List<String> scopes;
  final String providerAccountHint;
  final String expiresAt;

  bool get isEmpty =>
      issuer.trim().isEmpty &&
      clientIdRef.trim().isEmpty &&
      scopes.isEmpty &&
      providerAccountHint.trim().isEmpty &&
      expiresAt.trim().isEmpty;

  factory MobileAgentAccountOAuthMeta.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const MobileAgentAccountOAuthMeta();
    }
    final rawScopes = json['scopes'];
    return MobileAgentAccountOAuthMeta(
      issuer: (json['issuer'] ?? '').toString(),
      clientIdRef: (json['clientIdRef'] ?? '').toString(),
      scopes: rawScopes is List
          ? [
              for (final scope in rawScopes) scope.toString().trim(),
            ].where((scope) => scope.isNotEmpty).toList(growable: false)
          : const [],
      providerAccountHint: _redactedProviderAccountHint(
        (json['providerAccountHint'] ?? json['accountHint'] ?? '').toString(),
      ),
      expiresAt: (json['expiresAt'] ?? '').toString(),
    );
  }

  Map<String, dynamic>? toJson() {
    if (isEmpty) {
      return null;
    }
    return {
      if (issuer.trim().isNotEmpty) 'issuer': issuer.trim(),
      if (clientIdRef.trim().isNotEmpty) 'clientIdRef': clientIdRef.trim(),
      if (scopes.isNotEmpty) 'scopes': scopes,
      if (providerAccountHint.trim().isNotEmpty)
        'providerAccountHint': providerAccountHint.trim(),
      if (expiresAt.trim().isNotEmpty) 'expiresAt': expiresAt.trim(),
    };
  }
}

class MobileAgentProvider {
  const MobileAgentProvider({
    required this.id,
    required this.label,
    required this.authKind,
    required this.docsUrl,
    required this.defaultModel,
    this.modelOptions = const [],
    this.reasoningEffortOptions = const [],
    this.credentialUrl = '',
    this.oauthDocsUrl = '',
    this.supportsDirectChat = true,
    this.supportsDesktopRelay = true,
    this.supportsPhoneAssistant = false,
    this.localOAuthAvailability =
        MobileAgentLocalOAuthAvailability.notApplicable,
    this.requiresOAuthDescriptor = false,
    this.oauthDescriptor = const MobileAgentOAuthDescriptor.incomplete(),
  });

  final String id;
  final String label;
  final MobileAgentAuthKind authKind;
  final String docsUrl;
  final String defaultModel;
  final List<MobileAgentGenerationOption> modelOptions;
  final List<MobileAgentGenerationOption> reasoningEffortOptions;
  final String credentialUrl;
  final String oauthDocsUrl;
  final bool supportsDirectChat;
  final bool supportsDesktopRelay;
  final bool supportsPhoneAssistant;
  final MobileAgentLocalOAuthAvailability localOAuthAvailability;
  final bool requiresOAuthDescriptor;
  final MobileAgentOAuthDescriptor oauthDescriptor;

  String get effectiveCredentialUrl =>
      credentialUrl.trim().isEmpty ? docsUrl : credentialUrl;

  bool get supportsLocalOAuthLogin =>
      localOAuthAvailability == MobileAgentLocalOAuthAvailability.supported &&
      authKind == MobileAgentAuthKind.oauthPkce &&
      (!requiresOAuthDescriptor || oauthDescriptor.isUsable);

  bool get localOAuthDeferred =>
      localOAuthAvailability == MobileAgentLocalOAuthAvailability.deferred;

  List<MobileAgentGenerationOption> get effectiveModelOptions {
    if (modelOptions.any((option) => option.id == defaultModel)) {
      return modelOptions;
    }
    return [
      MobileAgentGenerationOption(id: defaultModel, label: defaultModel),
      ...modelOptions,
    ];
  }
}

class MobileAgentGenerationOption {
  const MobileAgentGenerationOption({required this.id, required this.label});

  final String id;
  final String label;
}

MobileAgentProvider mobileAgentProviderFor(String id) {
  return mobileAgentProviderOrNull(id) ?? mobileAgentProviders.first;
}

MobileAgentProvider? mobileAgentProviderOrNull(String id) {
  final normalized = id.trim().toLowerCase();
  for (final provider in mobileAgentProviders) {
    if (provider.id == normalized) {
      return provider;
    }
  }
  return null;
}

class MobileAgentAccount {
  const MobileAgentAccount({
    required this.id,
    required this.providerId,
    required this.label,
    required this.authState,
    required this.createdAt,
    required this.updatedAt,
    this.credentialPresent = false,
    this.credentialHint = '',
    this.credentialRef = '',
    this.authSource = authSourceLocalApiKey,
    this.sourceMode = MobileAgentSourceMode.mobileLocal,
    this.authKind = MobileAgentAuthKind.apiKey,
    this.active = false,
    this.relayDeviceLabel = '',
    this.relayProfileId = '',
    this.relayPairingId = '',
    this.relayDeviceId = '',
    this.relayGatewayUrl = '',
    this.selectedModel = '',
    this.reasoningEffort = '',
    this.lastUsedAt = '',
    this.oauth = const MobileAgentAccountOAuthMeta(),
    this.assistantGrants = MobileAgentAssistantGrants.disabled,
  });

  static const currentSchemaVersion = 4;
  static const authSourceLocalApiKey = 'local-api-key';
  static const authSourceLocalOAuth = 'local-oauth';
  static const authSourceMobileSynced = 'mobile-synced';
  static const authSourceDesktopRelay = 'desktop-relay';
  static const authStateConfigured = 'configured';
  static const authStateAuthorizationRequired = 'authorization-required';
  static const authStateChatValidationFailed = 'chat-validation-failed';

  /// Stable account id. Independent from [providerId]; never treat provider id
  /// as the only account identity for new records.
  final String id;
  final String providerId;
  final String label;
  final String authState;
  final String createdAt;
  final String updatedAt;
  final bool credentialPresent;
  final String credentialHint;

  /// Opaque secure-store reference. Never a secret value.
  final String credentialRef;
  final String authSource;
  final MobileAgentSourceMode sourceMode;
  final MobileAgentAuthKind authKind;
  final bool active;
  final String relayDeviceLabel;
  final String relayProfileId;
  final String relayPairingId;
  final String relayDeviceId;
  final String relayGatewayUrl;
  final String selectedModel;
  final String reasoningEffort;
  final String lastUsedAt;
  final MobileAgentAccountOAuthMeta oauth;
  final MobileAgentAssistantGrants assistantGrants;

  String get accountId => id;

  MobileAgentProvider get provider => mobileAgentProviderFor(providerId);
  bool get usesDesktopRelay =>
      sourceMode == MobileAgentSourceMode.desktopRelay ||
      authSource == authSourceDesktopRelay;
  bool get usesLocalOAuth =>
      authKind == MobileAgentAuthKind.oauthPkce &&
      sourceMode == MobileAgentSourceMode.mobileLocal &&
      authSource == authSourceLocalOAuth;
  bool get usesMobileSynced =>
      sourceMode == MobileAgentSourceMode.mobileSynced ||
      authSource == authSourceMobileSynced;
  bool get usesMobileLocal => sourceMode == MobileAgentSourceMode.mobileLocal;

  String get effectiveModel {
    final selected = selectedModel.trim();
    return selected.isEmpty ? provider.defaultModel : selected;
  }

  String get effectiveCredentialRef {
    final existing = credentialRef.trim();
    if (existing.isNotEmpty) {
      return existing;
    }
    return mobileAgentCredentialRef(
      providerId: providerId,
      accountId: id,
      authKind: authKind,
    );
  }

  factory MobileAgentAccount.create(
    MobileAgentProvider provider, {
    String id = '',
    String label = '',
    String authSource = authSourceLocalApiKey,
    MobileAgentSourceMode? sourceMode,
    MobileAgentAuthKind? authKind,
    bool credentialPresent = false,
    String credentialHint = '',
    String credentialRef = '',
    bool active = false,
    String relayDeviceLabel = '',
    String relayProfileId = '',
    String relayPairingId = '',
    String relayDeviceId = '',
    String relayGatewayUrl = '',
    String selectedModel = '',
    String reasoningEffort = '',
    String lastUsedAt = '',
    MobileAgentAccountOAuthMeta oauth = const MobileAgentAccountOAuthMeta(),
    MobileAgentAssistantGrants assistantGrants =
        MobileAgentAssistantGrants.disabled,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    final resolvedAuthSource = authSource.trim().isEmpty
        ? authSourceLocalApiKey
        : authSource.trim();
    final resolvedSourceMode =
        sourceMode ?? sourceModeForAuthSource(resolvedAuthSource);
    final resolvedAuthKind =
        authKind ?? authKindForProviderAndSource(provider, resolvedAuthSource);
    final accountId = id.trim().isEmpty
        ? generateMobileAgentAccountId(provider.id)
        : id.trim();
    return MobileAgentAccount(
      id: accountId,
      providerId: provider.id,
      label: label.trim().isEmpty ? provider.label : label.trim(),
      authState: credentialPresent
          ? authStateConfigured
          : authStateAuthorizationRequired,
      createdAt: now,
      updatedAt: now,
      credentialPresent: credentialPresent,
      credentialHint: credentialHint.trim(),
      credentialRef: credentialRef.trim().isEmpty
          ? mobileAgentCredentialRef(
              providerId: provider.id,
              accountId: accountId,
              authKind: resolvedAuthKind,
            )
          : credentialRef.trim(),
      authSource: resolvedAuthSource,
      sourceMode: resolvedSourceMode,
      authKind: resolvedAuthKind,
      active: active,
      relayDeviceLabel: relayDeviceLabel.trim(),
      relayProfileId: relayProfileId.trim(),
      relayPairingId: relayPairingId.trim(),
      relayDeviceId: relayDeviceId.trim(),
      relayGatewayUrl: relayGatewayUrl.trim(),
      selectedModel: _normalizeMobileAgentModel(provider, selectedModel),
      reasoningEffort: _normalizeMobileAgentReasoningEffort(
        provider,
        reasoningEffort,
      ),
      lastUsedAt: lastUsedAt.trim(),
      oauth: oauth,
      assistantGrants: assistantGrants,
    );
  }

  MobileAgentAccount copyWith({
    String? label,
    String? authState,
    String? updatedAt,
    bool? credentialPresent,
    String? credentialHint,
    String? credentialRef,
    String? authSource,
    MobileAgentSourceMode? sourceMode,
    MobileAgentAuthKind? authKind,
    bool? active,
    String? relayDeviceLabel,
    String? relayProfileId,
    String? relayPairingId,
    String? relayDeviceId,
    String? relayGatewayUrl,
    String? selectedModel,
    String? reasoningEffort,
    String? lastUsedAt,
    MobileAgentAccountOAuthMeta? oauth,
    MobileAgentAssistantGrants? assistantGrants,
  }) {
    final nextAuthSource = authSource ?? this.authSource;
    final nextSourceMode =
        sourceMode ??
        (authSource == null
            ? this.sourceMode
            : sourceModeForAuthSource(nextAuthSource));
    final nextAuthKind =
        authKind ??
        (authSource == null
            ? this.authKind
            : authKindForProviderAndSource(provider, nextAuthSource));
    return MobileAgentAccount(
      id: id,
      providerId: providerId,
      label: label ?? this.label,
      authState: authState ?? this.authState,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      credentialPresent: credentialPresent ?? this.credentialPresent,
      credentialHint: credentialHint ?? this.credentialHint,
      credentialRef: credentialRef ?? this.credentialRef,
      authSource: nextAuthSource,
      sourceMode: nextSourceMode,
      authKind: nextAuthKind,
      active: active ?? this.active,
      relayDeviceLabel: relayDeviceLabel ?? this.relayDeviceLabel,
      relayProfileId: relayProfileId ?? this.relayProfileId,
      relayPairingId: relayPairingId ?? this.relayPairingId,
      relayDeviceId: relayDeviceId ?? this.relayDeviceId,
      relayGatewayUrl: relayGatewayUrl ?? this.relayGatewayUrl,
      selectedModel: selectedModel == null
          ? this.selectedModel
          : _normalizeMobileAgentModel(provider, selectedModel),
      reasoningEffort: reasoningEffort == null
          ? this.reasoningEffort
          : _normalizeMobileAgentReasoningEffort(provider, reasoningEffort),
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      oauth: oauth ?? this.oauth,
      assistantGrants: assistantGrants ?? this.assistantGrants,
    );
  }

  factory MobileAgentAccount.fromJson(Map<String, dynamic> json) {
    final providerId = (json['providerId'] ?? json['id'] ?? '').toString();
    final provider = mobileAgentProviderFor(providerId);
    final authSource = (json['authSource'] ?? authSourceLocalApiKey).toString();
    final sourceMode = sourceModeFromJson(
      (json['sourceMode'] ?? '').toString(),
      authSource,
    );
    final authKind = authKindFromJson(
      (json['authKind'] ?? '').toString(),
      provider,
      authSource,
    );
    final accountId = (json['accountId'] ?? json['id'] ?? '').toString().trim();
    final resolvedAccountId = accountId.isEmpty
        ? generateMobileAgentAccountId(provider.id)
        : accountId;
    final oauthJson = json['oauth'];
    final grantsJson = json['assistantGrants'];
    return MobileAgentAccount(
      id: resolvedAccountId,
      providerId: provider.id,
      label: (json['label'] ?? provider.label).toString(),
      authState: (json['authState'] ?? 'authorization-required').toString(),
      credentialPresent: json['credentialPresent'] == true,
      credentialHint: (json['credentialHint'] ?? '').toString(),
      credentialRef: (json['credentialRef'] ?? '').toString().trim().isEmpty
          ? mobileAgentCredentialRef(
              providerId: provider.id,
              accountId: resolvedAccountId,
              authKind: authKind,
            )
          : (json['credentialRef'] ?? '').toString().trim(),
      authSource: authSource,
      sourceMode: sourceMode,
      authKind: authKind,
      active: json['active'] == true,
      relayDeviceLabel: (json['relayDeviceLabel'] ?? '').toString(),
      relayProfileId: (json['relayProfileId'] ?? json['profileId'] ?? '')
          .toString(),
      relayPairingId: (json['relayPairingId'] ?? json['pairingId'] ?? '')
          .toString(),
      relayDeviceId: (json['relayDeviceId'] ?? json['deviceId'] ?? '')
          .toString(),
      relayGatewayUrl: (json['relayGatewayUrl'] ?? json['gatewayUrl'] ?? '')
          .toString(),
      selectedModel: _normalizeMobileAgentModel(
        provider,
        (json['selectedModel'] ?? json['model'] ?? json['modelId'] ?? '')
            .toString(),
      ),
      reasoningEffort: _normalizeMobileAgentReasoningEffort(
        provider,
        (json['reasoningEffort'] ?? json['reasoning_effort'] ?? '').toString(),
      ),
      lastUsedAt: (json['lastUsedAt'] ?? '').toString(),
      oauth: MobileAgentAccountOAuthMeta.fromJson(
        oauthJson is Map ? Map<String, dynamic>.from(oauthJson) : null,
      ),
      assistantGrants: MobileAgentAssistantGrants.fromJson(
        grantsJson is Map ? Map<String, dynamic>.from(grantsJson) : null,
      ),
      createdAt: (json['createdAt'] ?? '').toString(),
      updatedAt: (json['updatedAt'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() {
    final grants = assistantGrants.toJson();
    final oauthJson = oauth.toJson();
    return {
      'schemaVersion': currentSchemaVersion,
      'accountId': id,
      'id': id,
      'providerId': providerId,
      'label': label,
      'authState': authState,
      'authKind': authKindWire(authKind),
      'sourceMode': sourceModeWire(sourceMode),
      'credentialPresent': credentialPresent,
      if (credentialHint.trim().isNotEmpty) 'credentialHint': credentialHint,
      if (credentialRef.trim().isNotEmpty) 'credentialRef': credentialRef,
      if (authSource != authSourceLocalApiKey) 'authSource': authSource,
      if (active) 'active': true,
      if (relayDeviceLabel.trim().isNotEmpty)
        'relayDeviceLabel': relayDeviceLabel,
      if (relayProfileId.trim().isNotEmpty) 'relayProfileId': relayProfileId,
      if (relayPairingId.trim().isNotEmpty) 'relayPairingId': relayPairingId,
      if (relayDeviceId.trim().isNotEmpty) 'relayDeviceId': relayDeviceId,
      if (relayGatewayUrl.trim().isNotEmpty) 'relayGatewayUrl': relayGatewayUrl,
      if (selectedModel.trim().isNotEmpty) 'selectedModel': selectedModel,
      if (reasoningEffort.trim().isNotEmpty) 'reasoningEffort': reasoningEffort,
      if (lastUsedAt.trim().isNotEmpty) 'lastUsedAt': lastUsedAt,
      'oauth': ?oauthJson,
      'assistantGrants': ?grants,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }
}

List<MobileAgentAccount> mobileAgentAccountsWithDesktopRelay(
  List<MobileAgentAccount> accounts,
  MobileRelayConfig relayConfig,
) {
  if (!relayConfig.hasPairing ||
      (!relayConfig.paired && !relayConfig.hasPairedDeviceEcho)) {
    return List<MobileAgentAccount>.unmodifiable(
      accounts.where((account) => !account.usesDesktopRelay),
    );
  }
  final deviceLabel = relayConfig.pcClientName.trim().isNotEmpty
      ? relayConfig.pcClientName.trim()
      : 'Mac';
  final providers = <MobileRelayAuthorizedProvider>[
    ...relayConfig.authorizedProviders,
    for (final device in relayConfig.deviceTabs)
      if (device.pairingId == relayConfig.pairingId)
        ...device.authorizedProviders,
  ];
  if (providers.isEmpty) {
    return List<MobileAgentAccount>.unmodifiable(
      accounts.where((account) => !account.usesDesktopRelay),
    );
  }
  final existingById = <String, MobileAgentAccount>{
    for (final account in accounts) account.id: account,
  };
  final byAccount = <String, MobileAgentAccount>{
    for (final account in accounts)
      if (!account.usesDesktopRelay) account.id: account,
  };
  for (final relayProvider in providers) {
    final provider = mobileAgentProviderOrNull(relayProvider.providerId);
    if (provider == null || !relayProvider.credentialPresent) {
      continue;
    }
    final credentialKind = relayProvider.credentialKind.trim().toLowerCase();
    if (provider.authKind == MobileAgentAuthKind.apiKey &&
        credentialKind.startsWith('oauth')) {
      continue;
    }
    if (provider.authKind == MobileAgentAuthKind.oauthPkce &&
        credentialKind.isNotEmpty &&
        !credentialKind.startsWith('oauth') &&
        credentialKind != 'api-key') {
      continue;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final relayAccountId = _relayAccountId(
      relayConfig.pairingId,
      provider.id,
      relayProvider.accountId,
      relayProvider.profileId,
    );
    final existing = existingById[relayAccountId];
    final relayAuthKind = credentialKind.startsWith('oauth')
        ? MobileAgentAuthKind.oauthPkce
        : provider.authKind == MobileAgentAuthKind.oauthPkce
        ? MobileAgentAuthKind.oauthPkce
        : MobileAgentAuthKind.apiKey;
    byAccount[relayAccountId] = MobileAgentAccount.create(
      provider,
      id: relayAccountId,
      label: relayProvider.label.trim().isEmpty
          ? provider.label
          : relayProvider.label.trim(),
      authSource: MobileAgentAccount.authSourceDesktopRelay,
      sourceMode: MobileAgentSourceMode.desktopRelay,
      authKind: MobileAgentAuthKind.desktopRelay,
      credentialPresent: true,
      credentialHint: deviceLabel,
      credentialRef: mobileAgentCredentialRef(
        providerId: provider.id,
        accountId: relayAccountId,
        authKind: MobileAgentAuthKind.desktopRelay,
      ),
      relayDeviceLabel: deviceLabel,
      relayProfileId: relayProvider.profileId,
      relayPairingId: relayConfig.pairingId,
      relayDeviceId: relayConfig.pcClientId,
      relayGatewayUrl: relayConfig.effectiveGatewayUrl,
      selectedModel: existing?.selectedModel ?? '',
      reasoningEffort: existing?.reasoningEffort ?? '',
      active: existing?.active ?? false,
      assistantGrants:
          existing?.assistantGrants ?? MobileAgentAssistantGrants.disabled,
      oauth:
          existing?.oauth ??
          (relayAuthKind == MobileAgentAuthKind.oauthPkce
              ? MobileAgentAccountOAuthMeta(
                  clientIdRef: provider.oauthDescriptor.clientIdRef,
                  issuer: provider.oauthDescriptor.issuer,
                )
              : const MobileAgentAccountOAuthMeta()),
    ).copyWith(updatedAt: now);
  }
  return List<MobileAgentAccount>.unmodifiable(
    ensureActiveAccountsPerProvider(byAccount.values.toList(growable: false)),
  );
}

String mobileAgentCredentialRef({
  required String providerId,
  required String accountId,
  required MobileAgentAuthKind authKind,
}) {
  final kind = switch (authKind) {
    MobileAgentAuthKind.oauthPkce => 'oauth',
    MobileAgentAuthKind.apiKey => 'api-key',
    MobileAgentAuthKind.desktopRelay => 'desktop-relay',
  };
  return 'secure-ref:$kind:${providerId.trim()}:${accountId.trim()}';
}

String generateMobileAgentAccountId(String providerId) {
  final safeProvider = providerId.trim().isEmpty
      ? 'provider'
      : providerId.trim().toLowerCase();
  final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
  return 'mpa-$safeProvider-$stamp';
}

MobileAgentSourceMode sourceModeForAuthSource(String authSource) {
  return switch (authSource.trim()) {
    MobileAgentAccount.authSourceDesktopRelay =>
      MobileAgentSourceMode.desktopRelay,
    MobileAgentAccount.authSourceMobileSynced =>
      MobileAgentSourceMode.mobileSynced,
    _ => MobileAgentSourceMode.mobileLocal,
  };
}

MobileAgentSourceMode sourceModeFromJson(String raw, String authSource) {
  final normalized = raw.trim().toLowerCase();
  return switch (normalized) {
    'mobile-local' || 'local' => MobileAgentSourceMode.mobileLocal,
    'mobile-synced' || 'synced' => MobileAgentSourceMode.mobileSynced,
    'desktop-relay' || 'relay' => MobileAgentSourceMode.desktopRelay,
    _ => sourceModeForAuthSource(authSource),
  };
}

String sourceModeWire(MobileAgentSourceMode mode) {
  return switch (mode) {
    MobileAgentSourceMode.mobileLocal => 'mobile-local',
    MobileAgentSourceMode.mobileSynced => 'mobile-synced',
    MobileAgentSourceMode.desktopRelay => 'desktop-relay',
  };
}

MobileAgentAuthKind authKindForProviderAndSource(
  MobileAgentProvider provider,
  String authSource,
) {
  if (authSource == MobileAgentAccount.authSourceDesktopRelay) {
    return MobileAgentAuthKind.desktopRelay;
  }
  if (authSource == MobileAgentAccount.authSourceLocalOAuth) {
    return MobileAgentAuthKind.oauthPkce;
  }
  if (authSource == MobileAgentAccount.authSourceMobileSynced) {
    return provider.authKind == MobileAgentAuthKind.oauthPkce
        ? MobileAgentAuthKind.oauthPkce
        : MobileAgentAuthKind.apiKey;
  }
  return provider.authKind == MobileAgentAuthKind.oauthPkce
      ? MobileAgentAuthKind.oauthPkce
      : MobileAgentAuthKind.apiKey;
}

MobileAgentAuthKind authKindFromJson(
  String raw,
  MobileAgentProvider provider,
  String authSource,
) {
  final normalized = raw.trim().toLowerCase().replaceAll('_', '-');
  return switch (normalized) {
    'oauth' || 'oauth-pkce' || 'oauth2' => MobileAgentAuthKind.oauthPkce,
    'api' || 'api-key' || 'apikey' => MobileAgentAuthKind.apiKey,
    'desktop-relay' || 'relay' => MobileAgentAuthKind.desktopRelay,
    _ => authKindForProviderAndSource(provider, authSource),
  };
}

String authKindWire(MobileAgentAuthKind kind) {
  return switch (kind) {
    MobileAgentAuthKind.oauthPkce => 'oauth-pkce',
    MobileAgentAuthKind.apiKey => 'api-key',
    MobileAgentAuthKind.desktopRelay => 'desktop-relay',
  };
}

List<MobileAgentAccount> ensureActiveAccountsPerProvider(
  List<MobileAgentAccount> accounts,
) {
  final byProvider = <String, List<MobileAgentAccount>>{};
  for (final account in accounts) {
    byProvider.putIfAbsent(account.providerId, () => []).add(account);
  }
  final next = <MobileAgentAccount>[];
  for (final entry in byProvider.entries) {
    final group = entry.value;
    final activeCount = group.where((account) => account.active).length;
    if (activeCount == 1) {
      next.addAll(group);
      continue;
    }
    MobileAgentAccount? preferred;
    for (final account in group) {
      if (account.credentialPresent) {
        preferred = account;
        break;
      }
    }
    preferred ??= group.first;
    for (final account in group) {
      next.add(
        account.id == preferred.id
            ? (account.active ? account : account.copyWith(active: true))
            : (account.active ? account.copyWith(active: false) : account),
      );
    }
  }
  return next;
}

MobileAgentAccount? activeMobileAgentAccountForProvider(
  List<MobileAgentAccount> accounts,
  String providerId,
) {
  final normalized = providerId.trim().toLowerCase();
  MobileAgentAccount? fallback;
  for (final account in accounts) {
    if (account.providerId != normalized) {
      continue;
    }
    if (account.active) {
      return account;
    }
    fallback ??= account;
  }
  return fallback;
}

String _normalizeMobileAgentModel(MobileAgentProvider provider, String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized == provider.defaultModel) {
    return '';
  }
  final options = provider.effectiveModelOptions.map((option) => option.id);
  return options.contains(normalized) ? normalized : '';
}

String _normalizeMobileAgentReasoningEffort(
  MobileAgentProvider provider,
  String value,
) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty) {
    return '';
  }
  final options = provider.reasoningEffortOptions.map((option) => option.id);
  return options.contains(normalized) ? normalized : '';
}

String _relayAccountId(
  String pairingId,
  String providerId,
  String relayAccountId,
  String profileId,
) {
  final sourceId = relayAccountId.trim().isNotEmpty
      ? relayAccountId.trim()
      : profileId.trim().isNotEmpty
      ? profileId.trim()
      : providerId;
  final pair = pairingId.trim().isEmpty ? 'paired' : pairingId.trim();
  return 'desktop-relay:${_safeAccountPart(pair)}:${_safeAccountPart(providerId)}:${_safeAccountPart(sourceId)}';
}

String _safeAccountPart(String value) {
  final safe = value.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
  return safe.isEmpty ? 'account' : safe;
}

String _redactedProviderAccountHint(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  if (trimmed.contains('@')) {
    final at = trimmed.indexOf('@');
    final local = trimmed.substring(0, at);
    final domain = trimmed.substring(at + 1);
    final localHint = local.length <= 1 ? '*' : '${local[0]}***';
    return '$localHint@$domain';
  }
  if (trimmed.length <= 4) {
    return '****';
  }
  return '****${trimmed.substring(trimmed.length - 4)}';
}

abstract class MobileAgentAccountStore {
  const MobileAgentAccountStore();

  Future<Object?> read(Object portableData);
  Future<void> write(Object portableData, Object? payload);
}

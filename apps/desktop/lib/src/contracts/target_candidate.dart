class TargetCandidate {
  final String id;
  final String target;
  final String label;
  final String kind;
  final String status;
  final bool configured;
  final double confidence;
  final String? detail;
  final String? configPath;
  final String? binaryPath;
  final List<String> historyRoots;
  final List<String> remoteHistoryRoots;
  final bool manual;
  final String adapterStatus;
  final Map<String, dynamic> adapterCapabilities;
  final List<String> supportedActions;
  final String scanSource;
  final String location;
  final Map<String, dynamic> environment;
  final Map<String, dynamic> optionOverrides;
  final Map<String, dynamic> modelCatalog;

  TargetCandidate({
    String? id,
    required this.target,
    required this.label,
    required this.kind,
    required this.status,
    required this.configured,
    required this.confidence,
    this.detail,
    this.configPath,
    this.binaryPath,
    List<String>? historyRoots,
    List<String>? remoteHistoryRoots,
    this.manual = false,
    required this.adapterStatus,
    Map<String, dynamic>? adapterCapabilities,
    List<String>? supportedActions,
    this.scanSource = '',
    this.location = 'local',
    Map<String, dynamic>? environment,
    Map<String, dynamic>? optionOverrides,
    Map<String, dynamic>? modelCatalog,
  }) : id = id ?? target,
       historyRoots = historyRoots ?? const [],
       remoteHistoryRoots = remoteHistoryRoots ?? const [],
       adapterCapabilities = adapterCapabilities ?? const {},
       supportedActions = supportedActions ?? const [],
       environment = environment ?? const {},
       optionOverrides = optionOverrides ?? const {},
       modelCatalog = modelCatalog ?? const {};

  bool supportsAction(String action) {
    return supportedActions.contains(action);
  }

  bool get visibleInClient => status != 'not-detected';
  bool get isConversationAgent =>
      visibleInClient && target != 'code' && location == 'local';

  String get conversationDriverStatus =>
      (adapterCapabilities['conversationDriver'] ?? 'unsupported').toString();
  String get conversationProtocol =>
      (adapterCapabilities['conversationProtocol'] ?? '').toString();
  String get conversationReadiness =>
      (adapterCapabilities['conversationReadiness'] ?? 'unverified').toString();
  String get conversationBlocker =>
      (adapterCapabilities['conversationBlocker'] ?? '').toString();
  Map<String, dynamic> get conversationProbe =>
      adapterCapabilities['conversationProbe'] is Map
      ? Map<String, dynamic>.from(
          adapterCapabilities['conversationProbe'] as Map,
        )
      : const {};
  Map<String, dynamic> get conversationCapabilityMatrix =>
      adapterCapabilities['conversationCapabilityMatrix'] is Map
      ? Map<String, dynamic>.from(
          adapterCapabilities['conversationCapabilityMatrix'] as Map,
        )
      : const {};
  List<String> get conversationSummaryCodes {
    final raw = adapterCapabilities['conversationSummaryCodes'];
    if (raw is! List) {
      final blocker = conversationBlocker.trim();
      return blocker.isEmpty ? const [] : [blocker];
    }
    return raw
        .map((entry) => entry.toString().trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }

  int get conversationConsecutivePasses {
    final raw = adapterCapabilities['conversationConsecutivePasses'];
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  String get conversationEvidenceAge =>
      (adapterCapabilities['conversationEvidenceAge'] ?? '').toString();

  String get conversationSendGateReason {
    final codes = conversationSummaryCodes;
    if (codes.isNotEmpty) {
      return codes.first;
    }
    final blocker = conversationBlocker.trim();
    if (blocker.isNotEmpty) {
      return blocker;
    }
    return 'native_conversation_parity_$conversationReadiness';
  }

  bool get canRelayRuntime =>
      visibleInClient &&
      conversationReadiness == 'ready' &&
      supportsAction('runtime.message.send');

  bool get canUpdateMcpPlugin => supportsAction('mcp.plugin.update');
  bool get canRollbackMcpPlugin => supportsAction('mcp.plugin.rollback');
  bool get canInstallSkill => supportsAction('skill.install');

  /// Peer MCP install/repair is available when plan or apply is advertised.
  bool get supportsMcpPluginInstall =>
      canUpdateMcpPlugin ||
      supportsAction('mcp.config.plan') ||
      adapterStatus == 'partial' ||
      adapterStatus == 'implemented';

  /// ACP lane support from adapter conversation metadata (not invented).
  bool get supportsAcpPlugin {
    final laneFamily = conversationCapabilityMatrix['laneFamily']
        ?.toString()
        .trim()
        .toLowerCase();
    if (laneFamily == 'acp') {
      return true;
    }
    final protocol = conversationProtocol.trim().toLowerCase();
    return protocol.contains('acp');
  }

  factory TargetCandidate.fromJson(Map<String, dynamic> json) {
    return TargetCandidate(
      id: json['id']?.toString(),
      target: (json['target'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      kind: (json['kind'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      configured: json['configured'] == true,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      detail: json['detail']?.toString(),
      configPath: json['configPath']?.toString(),
      binaryPath: json['binaryPath']?.toString(),
      historyRoots: json['historyRoots'] is List
          ? (json['historyRoots'] as List)
                .map((value) => value.toString())
                .toList()
          : null,
      remoteHistoryRoots: json['remoteHistoryRoots'] is List
          ? (json['remoteHistoryRoots'] as List)
                .map((value) => value.toString())
                .toList()
          : null,
      manual: json['manual'] == true,
      adapterStatus: (json['adapterStatus'] ?? '').toString(),
      adapterCapabilities: json['adapterCapabilities'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(json['adapterCapabilities'] as Map)
          : null,
      supportedActions: json['supportedActions'] is List
          ? (json['supportedActions'] as List).whereType<String>().toList()
          : null,
      scanSource: (json['scanSource'] ?? '').toString(),
      location: (json['location'] ?? 'local').toString(),
      environment: json['environment'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(json['environment'] as Map)
          : null,
      optionOverrides: json['optionOverrides'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(json['optionOverrides'] as Map)
          : null,
      modelCatalog: json['modelCatalog'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(json['modelCatalog'] as Map)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'target': target,
      'label': label,
      'kind': kind,
      'status': status,
      'configured': configured,
      'confidence': confidence,
      if (detail != null) 'detail': detail,
      if (configPath != null) 'configPath': configPath,
      if (binaryPath != null) 'binaryPath': binaryPath,
      if (historyRoots.isNotEmpty) 'historyRoots': historyRoots,
      if (remoteHistoryRoots.isNotEmpty)
        'remoteHistoryRoots': remoteHistoryRoots,
      'manual': manual,
      'adapterStatus': adapterStatus,
      'adapterCapabilities': adapterCapabilities,
      'supportedActions': supportedActions,
      if (scanSource.isNotEmpty) 'scanSource': scanSource,
      'location': location,
      if (environment.isNotEmpty) 'environment': environment,
      if (optionOverrides.isNotEmpty) 'optionOverrides': optionOverrides,
      if (modelCatalog.isNotEmpty) 'modelCatalog': modelCatalog,
    };
  }
}

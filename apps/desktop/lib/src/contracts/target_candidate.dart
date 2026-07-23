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
  final bool manual;
  final String adapterStatus;
  final Map<String, dynamic> adapterCapabilities;
  final List<String> supportedActions;
  final String scanSource;
  final String location;
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
    this.manual = false,
    required this.adapterStatus,
    Map<String, dynamic>? adapterCapabilities,
    List<String>? supportedActions,
    this.scanSource = '',
    this.location = 'local',
    Map<String, dynamic>? modelCatalog,
  }) : id = id ?? target,
       historyRoots = historyRoots ?? const [],
       adapterCapabilities = adapterCapabilities ?? const {},
       supportedActions = supportedActions ?? const [],
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
    if ((binaryPath ?? '').trim().isEmpty) {
      return 'native_agent_executable_not_detected';
    }
    if (conversationDriverStatus == 'unsupported') {
      return 'native_agent_runtime_profile_unavailable';
    }
    return 'runtime_message_send_unavailable';
  }

  /// Local conversation agents are client-accessible by default: parity
  /// evidence (conversationReadiness) stays informational and never gates
  /// local runtime use. Only runtimes without a driver profile or without a
  /// detected binary are excluded. The projected supported-action list is
  /// informational and cannot veto an execution path the client can resolve.
  bool get canRelayRuntime =>
      visibleInClient &&
      (binaryPath ?? '').trim().isNotEmpty &&
      conversationDriverStatus != 'unsupported';

  bool get supportsNativeInterruptSteer =>
      conversationCapabilityMatrix['interruptSteer'] == true;

  bool get canInstallSkill => supportsAction('skill.install');

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
      'manual': manual,
      'adapterStatus': adapterStatus,
      'adapterCapabilities': adapterCapabilities,
      'supportedActions': supportedActions,
      if (scanSource.isNotEmpty) 'scanSource': scanSource,
      'location': location,
      if (modelCatalog.isNotEmpty) 'modelCatalog': modelCatalog,
    };
  }
}

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
  }) : id = id ?? target,
       historyRoots = historyRoots ?? const [],
       remoteHistoryRoots = remoteHistoryRoots ?? const [],
       adapterCapabilities = adapterCapabilities ?? const {},
       supportedActions = supportedActions ?? const [],
       environment = environment ?? const {},
       optionOverrides = optionOverrides ?? const {};

  bool supportsAction(String action) {
    return supportedActions.contains(action);
  }

  bool get visibleInClient => status != 'not-detected';

  bool get canUpdateMcpPlugin => supportsAction('mcp.plugin.update');
  bool get canRollbackMcpPlugin => supportsAction('mcp.plugin.rollback');
  bool get canInstallSkill => supportsAction('skill.install');

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
    };
  }
}

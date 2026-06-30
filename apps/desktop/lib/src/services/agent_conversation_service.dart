import 'agent_service.dart';

part 'agent_conversation_archive_service.dart';

class AgentConversationMessage {
  const AgentConversationMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String role;
  final String text;
  final String createdAt;

  factory AgentConversationMessage.fromJson(Map<String, dynamic> json) {
    return AgentConversationMessage(
      id: (json['id'] ?? '').toString(),
      role: (json['role'] ?? 'system').toString(),
      text: (json['text'] ?? '').toString(),
      createdAt: (json['createdAt'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'role': role, 'text': text, 'createdAt': createdAt};
  }
}

class AgentConversationSession {
  const AgentConversationSession({
    required this.id,
    required this.agentId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
    this.adapterId = '',
    this.nativeSessionId = '',
    this.sourceKind = '',
    this.importMode = '',
    this.sourceTool = '',
    this.sourceClient = '',
    this.sourceClientLabel = '',
    this.hostApp = '',
    this.hostAppLabel = '',
    this.sourceLabel = '',
    this.sourcePath = '',
    this.native = true,
    this.readOnly = true,
    this.messageCount = 0,
  });

  final String id;
  final String agentId;
  final String title;
  final String createdAt;
  final String updatedAt;
  final String adapterId;
  final String nativeSessionId;
  final String sourceKind;
  final String importMode;
  final String sourceTool;
  final String sourceClient;
  final String sourceClientLabel;
  final String hostApp;
  final String hostAppLabel;
  final String sourceLabel;
  final String sourcePath;
  final bool native;
  final bool readOnly;
  final int messageCount;
  final List<AgentConversationMessage> messages;

  String get preview {
    if (messages.isEmpty) {
      return 'No native messages yet';
    }
    return messages.last.text;
  }

  factory AgentConversationSession.fromJson(Map<String, dynamic> json) {
    final messages = (json['messages'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(AgentConversationMessage.fromJson)
        .toList();
    return AgentConversationSession(
      id: (json['id'] ?? '').toString(),
      agentId: (json['agentId'] ?? '').toString(),
      title: (json['title'] ?? 'Native agent history').toString(),
      createdAt: (json['createdAt'] ?? '').toString(),
      updatedAt: (json['updatedAt'] ?? '').toString(),
      adapterId: (json['adapterId'] ?? '').toString(),
      nativeSessionId: (json['nativeSessionId'] ?? '').toString(),
      sourceKind: (json['sourceKind'] ?? '').toString(),
      importMode: (json['importMode'] ?? '').toString(),
      sourceTool: (json['sourceTool'] ?? '').toString(),
      sourceClient: (json['sourceClient'] ?? '').toString(),
      sourceClientLabel: (json['sourceClientLabel'] ?? '').toString(),
      hostApp: (json['hostApp'] ?? '').toString(),
      hostAppLabel: (json['hostAppLabel'] ?? '').toString(),
      sourceLabel: (json['sourceLabel'] ?? '').toString(),
      sourcePath: (json['sourcePath'] ?? '').toString(),
      native: json['native'] != false,
      readOnly: json['readOnly'] != false,
      messageCount: (json['messageCount'] as num?)?.toInt() ?? messages.length,
      messages: messages,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'agentId': agentId,
      'title': title,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'adapterId': adapterId,
      'nativeSessionId': nativeSessionId,
      'sourceKind': sourceKind,
      'importMode': importMode,
      'sourceTool': sourceTool,
      'sourceClient': sourceClient,
      'sourceClientLabel': sourceClientLabel,
      'hostApp': hostApp,
      'hostAppLabel': hostAppLabel,
      'sourceLabel': sourceLabel,
      'sourcePath': sourcePath,
      'native': native,
      'readOnly': readOnly,
      'messageCount': messageCount == 0 ? messages.length : messageCount,
      'messages': messages.map((message) => message.toJson()).toList(),
    };
  }
}

class AgentConversationService {
  const AgentConversationService();

  Future<List<AgentConversationSession>> loadSessions({
    required AgentService agentService,
    required String agentId,
  }) async {
    final output = await agentService.runCli([
      'conversations',
      'list',
      '--agent',
      agentId,
    ]);
    return _sessionsFromOutput(output);
  }

  Future<Map<String, dynamic>> sendRuntimeMessage({
    required AgentService agentService,
    required String agentId,
    required String text,
    String sessionId = '',
  }) {
    final args = [
      'agent',
      'message',
      'send',
      '--agent',
      agentId,
      '--text',
      text,
    ];
    if (sessionId.trim().isNotEmpty) {
      args.addAll(['--session-id', sessionId.trim()]);
    }
    return agentService.runCli(args);
  }

  List<AgentConversationSession> _sessionsFromOutput(
    Map<String, dynamic> output,
  ) {
    if (output['ok'] == true && output['sessions'] is List) {
      return (output['sessions'] as List)
          .whereType<Map<String, dynamic>>()
          .map(AgentConversationSession.fromJson)
          .where((session) => session.id.isNotEmpty)
          .toList();
    }
    return const [];
  }
}

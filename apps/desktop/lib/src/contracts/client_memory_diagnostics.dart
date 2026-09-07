/// Privacy-safe memory-pressure events for local crash diagnosis.
///
/// Records carry only counts and process RSS. Conversation ids, titles,
/// transcripts, paths, and exception text are never accepted.
enum ClientMemoryDiagnosticEvent {
  sample('sample'),
  conversationOpened('conversation_opened'),
  conversationClosed('conversation_closed'),
  liveTurnOpened('live_turn_opened'),
  liveTurnClosed('live_turn_closed');

  const ClientMemoryDiagnosticEvent(this.wireName);

  final String wireName;
}

enum ClientMemoryDiagnosticSurface {
  canonical('canonical'),
  workspace('workspace');

  const ClientMemoryDiagnosticSurface(this.wireName);

  final String wireName;
}

/// Counts observed from a conversation surface. No identifiers or text.
final class ClientMemoryDiagnosticObservation {
  const ClientMemoryDiagnosticObservation({
    required this.event,
    required this.surface,
    this.eventCount = 0,
    this.loadedEventCount = 0,
    this.liveTurnCount = 0,
    this.livePartCount = 0,
    this.liveMessageCount = 0,
    this.cachedConversationCount = 0,
  });

  final ClientMemoryDiagnosticEvent event;
  final ClientMemoryDiagnosticSurface surface;
  final int eventCount;
  final int loadedEventCount;
  final int liveTurnCount;
  final int livePartCount;
  final int liveMessageCount;
  final int cachedConversationCount;
}

/// One bounded memory-pressure sample.
final class ClientMemoryDiagnosticRecord {
  const ClientMemoryDiagnosticRecord({
    required this.event,
    required this.createdAt,
    required this.surface,
    required this.rssBytes,
    required this.maxRssBytes,
    required this.eventCount,
    required this.loadedEventCount,
    required this.liveTurnCount,
    required this.livePartCount,
    required this.liveMessageCount,
    required this.cachedConversationCount,
  });

  final ClientMemoryDiagnosticEvent event;
  final DateTime createdAt;
  final ClientMemoryDiagnosticSurface surface;
  final int rssBytes;
  final int maxRssBytes;
  final int eventCount;
  final int loadedEventCount;
  final int liveTurnCount;
  final int livePartCount;
  final int liveMessageCount;
  final int cachedConversationCount;

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'event': event.wireName,
    'surface': surface.wireName,
    'rssBytes': rssBytes,
    'maxRssBytes': maxRssBytes,
    'eventCount': eventCount,
    'loadedEventCount': loadedEventCount,
    'liveTurnCount': liveTurnCount,
    'livePartCount': livePartCount,
    'liveMessageCount': liveMessageCount,
    'cachedConversationCount': cachedConversationCount,
  };

  static const String schemaVersion = 'licoup.client-memory-diagnostic.v1';
}

/// Persists [ClientMemoryDiagnosticRecord] values for post-crash inspection.
abstract interface class ClientMemoryDiagnosticSink {
  Future<void> record(ClientMemoryDiagnosticRecord record);
}

final class NoopClientMemoryDiagnosticSink
    implements ClientMemoryDiagnosticSink {
  const NoopClientMemoryDiagnosticSink();

  @override
  Future<void> record(ClientMemoryDiagnosticRecord record) async {}
}

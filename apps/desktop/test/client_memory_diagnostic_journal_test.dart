import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/conversations/client_memory_diagnostic_journal.dart';
import 'package:licoup/src/contracts/client_memory_diagnostics.dart';
import 'package:licoup/src/platform/client_resource_usage_probe.dart';

final class _CollectingSink implements ClientMemoryDiagnosticSink {
  final records = <ClientMemoryDiagnosticRecord>[];

  @override
  Future<void> record(ClientMemoryDiagnosticRecord record) async {
    records.add(record);
  }
}

final class _RssProbe implements ClientResourceUsageProbe {
  _RssProbe(this.readings);

  final List<int> readings;
  int calls = 0;

  @override
  bool get supported => true;

  @override
  ResourceProbeReading read() {
    final rss = readings[calls < readings.length ? calls : readings.length - 1];
    calls += 1;
    return ResourceProbeReading(
      rssBytes: rss,
      diskReadBytes: 0,
      diskWriteBytes: 0,
    );
  }
}

void main() {
  test('open conversation writes RSS plus counts', () {
    final sink = _CollectingSink();
    final journal = ClientMemoryDiagnosticJournal(
      sink: sink,
      probe: _RssProbe([10 * 1024 * 1024]),
      now: () => DateTime.utc(2026, 9, 7, 9),
      maxRssBytes: () => 12 * 1024 * 1024,
    );
    addTearDown(journal.dispose);

    journal.observe(
      const ClientMemoryDiagnosticObservation(
        event: ClientMemoryDiagnosticEvent.conversationOpened,
        surface: ClientMemoryDiagnosticSurface.canonical,
        eventCount: 12,
        loadedEventCount: 8,
        cachedConversationCount: 1,
      ),
    );

    expect(journal.isSampling, isTrue);
    expect(sink.records, hasLength(1));
    final record = sink.records.single;
    expect(record.event, ClientMemoryDiagnosticEvent.conversationOpened);
    expect(record.rssBytes, 10 * 1024 * 1024);
    expect(record.maxRssBytes, 12 * 1024 * 1024);
    expect(record.eventCount, 12);
    expect(record.loadedEventCount, 8);
    expect(record.toJson().toString(), isNot(contains('conversation:')));
  });

  test('sample writes only when RSS steps by 32 MiB', () {
    final sink = _CollectingSink();
    final journal = ClientMemoryDiagnosticJournal(
      sink: sink,
      probe: _RssProbe([20 * 1024 * 1024, 30 * 1024 * 1024, 60 * 1024 * 1024]),
      now: () => DateTime.utc(2026, 9, 7, 9),
      maxRssBytes: () => 60 * 1024 * 1024,
    );
    addTearDown(journal.dispose);

    journal.observe(
      const ClientMemoryDiagnosticObservation(
        event: ClientMemoryDiagnosticEvent.conversationOpened,
        surface: ClientMemoryDiagnosticSurface.workspace,
        liveTurnCount: 1,
        liveMessageCount: 4,
      ),
    );
    journal.observe(
      const ClientMemoryDiagnosticObservation(
        event: ClientMemoryDiagnosticEvent.sample,
        surface: ClientMemoryDiagnosticSurface.workspace,
        liveTurnCount: 1,
        liveMessageCount: 5,
      ),
    );
    journal.observe(
      const ClientMemoryDiagnosticObservation(
        event: ClientMemoryDiagnosticEvent.sample,
        surface: ClientMemoryDiagnosticSurface.workspace,
        liveTurnCount: 1,
        liveMessageCount: 6,
      ),
    );

    expect(sink.records, hasLength(2));
    expect(
      sink.records.first.event,
      ClientMemoryDiagnosticEvent.conversationOpened,
    );
    expect(sink.records.last.event, ClientMemoryDiagnosticEvent.sample);
    expect(sink.records.last.rssBytes, 60 * 1024 * 1024);
    expect(sink.records.last.liveMessageCount, 6);
  });

  test('closing the conversation ends sampling', () {
    final sink = _CollectingSink();
    final journal = ClientMemoryDiagnosticJournal(
      sink: sink,
      probe: _RssProbe([8 * 1024 * 1024]),
      now: () => DateTime.utc(2026, 9, 7, 9),
      maxRssBytes: () => 8 * 1024 * 1024,
    );
    addTearDown(journal.dispose);

    journal.observe(
      const ClientMemoryDiagnosticObservation(
        event: ClientMemoryDiagnosticEvent.conversationOpened,
        surface: ClientMemoryDiagnosticSurface.canonical,
      ),
    );
    journal.observe(
      const ClientMemoryDiagnosticObservation(
        event: ClientMemoryDiagnosticEvent.conversationClosed,
        surface: ClientMemoryDiagnosticSurface.canonical,
      ),
    );

    expect(journal.isSampling, isFalse);
    expect(sink.records.map((record) => record.event), [
      ClientMemoryDiagnosticEvent.conversationOpened,
      ClientMemoryDiagnosticEvent.conversationClosed,
    ]);
  });
}

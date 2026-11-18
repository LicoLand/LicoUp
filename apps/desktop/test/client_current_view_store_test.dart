import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/navigation/controller/client_current_view_tracker.dart';
import 'package:licoup/src/contracts/presentation/client_current_view.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/platform/agents/agent_tab_order_store.dart';
import 'package:licoup/src/platform/presentation/client_current_view_store.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late PortableDataRoot portableData;
  const store = PlatformClientCurrentViewStore();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lico-current-view-');
    portableData = PortableDataRoot(dataDirectoryOverride: directory);
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('round-trips the exact Agent conversation and section', () async {
    expect(await store.load(portableData), isNull);

    await store.save(
      portableData,
      ClientCurrentView.agent(
        section: ClientSection.settings,
        agentId: 'codex',
        sessionId: 'native-session-42',
      ),
    );

    expect(
      await store.load(portableData),
      ClientCurrentView.agent(
        section: ClientSection.settings,
        agentId: 'codex',
        sessionId: 'native-session-42',
      ),
    );
  });

  test('round-trips Local and Welcome views', () async {
    await store.save(
      portableData,
      ClientCurrentView.group(conversationId: 'conversation:local'),
    );
    expect(
      await store.load(portableData),
      ClientCurrentView.group(conversationId: 'conversation:local'),
    );

    await store.save(
      portableData,
      ClientCurrentView.welcome(section: ClientSection.models),
    );
    expect(
      await store.load(portableData),
      ClientCurrentView.welcome(section: ClientSection.models),
    );
  });

  test('loads nothing from missing or malformed documents', () async {
    final dataDir = await portableData.clientDirectory();
    final file = File('${dataDir.path}/current-client-view.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '{"schemaVersion":1,"section":"agents",'
      '"conversationKind":"group","groupConversationId":""}',
    );

    expect(await store.load(portableData), isNull);
  });

  test('rejects a document awaiting startup migration', () async {
    final dataDir = await portableData.clientDirectory();
    final file = File('${dataDir.path}/current-client-view.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '{"schemaVersion":0,"section":"agents",'
      '"conversationKind":"welcome"}',
    );

    await expectLater(store.load(portableData), throwsStateError);
  });

  test(
    'durable JSON readers reject corruption instead of projecting absence',
    () async {
      final dataDir = await portableData.clientDirectory();
      final file = File('${dataDir.path}/current-client-view.json');
      await file.writeAsString('{invalid');

      await expectLater(store.load(portableData), throwsFormatException);
    },
  );

  test(
    'agent tab order accepts only the startup-admitted current schema',
    () async {
      final dataDir = await portableData.clientDirectory();
      final file = File('${dataDir.path}/agent-tab-order.json');
      await file.writeAsString('["codex"]');

      await expectLater(
        const PlatformAgentTabOrderStore().load(portableData),
        throwsStateError,
      );
    },
  );

  test('a user switch during startup wins over the restored view', () async {
    final delayedStore = _DelayedCurrentViewStore(
      ClientCurrentView.agent(agentId: 'codex'),
    );
    final tracker = ClientCurrentViewTracker();
    final loading = tracker.load(
      store: delayedStore,
      portableData: portableData,
    );
    final selected = ClientCurrentView.group(
      conversationId: 'conversation:local',
    );

    tracker.record(selected);
    delayedStore.releaseLoad();
    await loading;
    await tracker.flush();

    expect(tracker.current, selected);
    expect(delayedStore.saved, [selected]);
  });

  test('production current-view ownership is process-wide', () {
    expect(
      identical(
        ClientCurrentViewTracker.instance,
        ClientCurrentViewTracker.instance,
      ),
      isTrue,
    );
  });
}

final class _DelayedCurrentViewStore implements ClientCurrentViewStore {
  _DelayedCurrentViewStore(this.restored);

  final ClientCurrentView restored;
  final Completer<void> _loadGate = Completer<void>();
  final List<ClientCurrentView> saved = [];

  void releaseLoad() => _loadGate.complete();

  @override
  Future<ClientCurrentView?> load(Object portableData) async {
    await _loadGate.future;
    return restored;
  }

  @override
  Future<void> save(Object portableData, ClientCurrentView view) async {
    saved.add(view);
  }
}

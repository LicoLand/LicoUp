import 'package:flutter/widgets.dart';
import 'package:licoup/app.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/application/features/navigation/controller/client_current_view_tracker.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/client_memory_diagnostics.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/contracts/presentation/client_current_view.dart';

import 'fixtures/client_controller/support/client_controller_scenario_dependencies.dart';
import 'fixtures/client_controller/support/fake_agent_service.dart';

const _localId = ClientConversation.defaultLocalAgentGroupId;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final remainsMounted in [true, false]) {
    testWidgets(
      'first-frame Gateway waits for startup; mounted=$remainsMounted',
      (tester) async {
        final controller = _FirstFrameClient();
        final composition = ClientAppComposition(controller: controller);
        addTearDown(() => tester.runAsync(composition.dispose));
        await tester.pumpWidget(
          LicoApp(
            compositionFactory: () => composition,
            homeBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        );
        expect(controller.gatewayStarts, 0);
        if (!remainsMounted) {
          await tester.runAsync(composition.dispose);
          await tester.pumpWidget(const SizedBox.shrink());
        }
        controller.startup.complete();
        await tester.pump();
        expect(controller.gatewayStarts, remainsMounted ? 1 : 0);
        await tester.runAsync(composition.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test('Local first page is warmed once without changing selection', () async {
    final native = _StartupConversationNative();
    final controller = ClientConversationController(native: native);
    addTearDown(controller.dispose);

    await controller.initialize();

    expect(native.actions, [
      'conversation.list',
      'conversation.get',
      'conversation.events.page',
    ]);
    expect(controller.selectedConversationId, isEmpty);
    expect(controller.groupConversations.map((item) => item.id), [
      _localId,
      'other-group',
    ]);
    await controller.selectConversation(_localId);
    expect(controller.events.single.id, 'local-event');
    expect(native.gets, 1);
    expect(native.pages, 1);
  });

  test('Local becomes readable before blocked Agent discovery', () async {
    final directory = await Directory.systemTemp.createTemp('local-priority-');
    final native = _StartupConversationNative()..pageGate = Completer<void>();
    final store = _StartupViewStore(
      ClientCurrentView.group(conversationId: _localId),
    );
    final tracker = ClientCurrentViewTracker();
    final controller = _StartupClient(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      conversationNativePort: native,
      currentViewStore: store,
      currentViewTracker: tracker,
    );
    addTearDown(() async {
      if (!controller.scanGate.isCompleted) controller.scanGate.complete();
      if (!native.pageGate!.isCompleted) native.pageGate!.complete();
      await controller.close();
      await tracker.flush();
      tracker.dispose();
      await directory.delete(recursive: true);
    });

    final initializing = controller.initializeWithOptions(
      runBackgroundSteps: false,
    );
    await native.pageStarted.future;
    expect(store.loads, 0);
    expect(controller.scanStarted.isCompleted, isFalse);

    native.pageGate!.complete();
    await controller.scanStarted.future;
    expect(controller.initialized, isFalse);
    expect(
      controller.clientConversationController.selectedConversationId,
      _localId,
    );
    expect(
      controller.clientConversationController.events.single.id,
      'local-event',
    );
    expect(native.gets, 1);
    expect(native.pages, 1);

    controller.scanGate.complete();
    await initializing;
    expect(controller.initialized, isTrue);
  });

  test('client close drains pending diagnostic writes', () async {
    final directory = await Directory.systemTemp.createTemp('local-close-');
    final portableData = _BlockedDiagnosticDataRoot(directory);
    final controller = ClientController(
      portableData: portableData,
      agentService: FakeAgentService(),
      conversationNativePort: _StartupConversationNative(),
    );
    addTearDown(() async {
      if (!portableData.release.isCompleted) portableData.release.complete();
      await controller.close();
      await directory.delete(recursive: true);
    });

    controller.observeClientMemory(
      const ClientMemoryDiagnosticObservation(
        event: ClientMemoryDiagnosticEvent.conversationOpened,
        surface: ClientMemoryDiagnosticSurface.canonical,
      ),
    );
    await portableData.started.future;
    var closed = false;
    final closing = controller.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);

    portableData.release.complete();
    await closing;
    final log = File(
      '${directory.path}/client-state/diagnostics/client-memory.jsonl',
    );
    expect(await log.readAsLines(), hasLength(1));
  });

  test('Local preload preserves a saved different group', () async {
    final directory = await Directory.systemTemp.createTemp('local-selection-');
    final native = _StartupConversationNative();
    final tracker = ClientCurrentViewTracker();
    final controller = _StartupClient(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      conversationNativePort: native,
      currentViewStore: _StartupViewStore(
        ClientCurrentView.group(conversationId: 'other-group'),
      ),
      currentViewTracker: tracker,
    );
    addTearDown(() async {
      if (!controller.scanGate.isCompleted) controller.scanGate.complete();
      await controller.close();
      await tracker.flush();
      tracker.dispose();
      await directory.delete(recursive: true);
    });
    controller.scanGate.complete();

    await controller.initializeWithOptions(runBackgroundSteps: false);

    expect(native.readIds, [_localId, 'other-group']);
    expect(
      controller.clientConversationController.selectedConversationId,
      'other-group',
    );
    expect(tracker.current?.groupConversationId, 'other-group');
  });

  test(
    'failed Local preload reports failure and leaves its catalog usable',
    () async {
      final native = _StartupConversationNative()..failPage = true;
      final controller = ClientConversationController(native: native);
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.failureCode, 'synthetic_page_unavailable');
      expect(controller.loading, isFalse);
      expect(controller.groupConversations.first.id, _localId);
      native.failPage = false;
      await controller.initialize();
      await controller.selectConversation(_localId);
      expect(controller.events.single.id, 'local-event');
      expect(controller.failureCode, isEmpty);
    },
  );
}

final class _BlockedDiagnosticDataRoot extends PortableDataRoot {
  _BlockedDiagnosticDataRoot(Directory directory)
    : super(dataDirectoryOverride: directory);

  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Directory> clientDirectory() async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return super.clientDirectory();
  }
}

final class _StartupClient extends ClientController {
  _StartupClient({
    required super.portableData,
    required super.conversationNativePort,
    required super.currentViewStore,
    required super.currentViewTracker,
  }) : super(agentService: FakeAgentService());

  final scanStarted = Completer<void>();
  final scanGate = Completer<void>();

  @override
  Future<void> scanTargets({
    bool showProgress = true,
    bool? surfaceErrors,
    bool forceRescanKnown = false,
  }) async {
    if (!scanStarted.isCompleted) scanStarted.complete();
    await scanGate.future;
  }
}

final class _FirstFrameClient extends ClientController {
  _FirstFrameClient() : super(agentService: FakeAgentService());

  final startup = Completer<void>();
  int gatewayStarts = 0;

  @override
  Future<void> initialize() => startup.future;

  @override
  Future<void> initializeLlmGateway() async {
    gatewayStarts += 1;
  }
}

final class _StartupViewStore implements ClientCurrentViewStore {
  _StartupViewStore(this.view);

  ClientCurrentView view;
  int loads = 0;

  @override
  Future<ClientCurrentView?> load(Object portableData) async {
    loads += 1;
    return view;
  }

  @override
  Future<void> save(Object portableData, ClientCurrentView value) async {
    view = value;
  }
}

final class _StartupConversationNative implements ClientConversationNativePort {
  final actions = <String>[];
  final readIds = <String>[];
  final pageStarted = Completer<void>();
  Completer<void>? pageGate;
  bool failPage = false;
  int gets = 0;
  int pages = 0;

  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) async {
    final request = command.payload;
    final action = request['action'] as String;
    actions.add(action);
    final id = request['conversationId'] as String? ?? _localId;
    Object result = <String, dynamic>{};
    switch (action) {
      case 'conversation.list':
        result = [_conversation(_localId), _conversation('other-group')];
      case 'conversation.get':
        gets += 1;
        readIds.add(id);
        result = _conversation(id);
      case 'conversation.events.page':
        pages += 1;
        expect(request['latest'], isTrue);
        expect(request['limit'], 20);
        if (!pageStarted.isCompleted) pageStarted.complete();
        await pageGate?.future;
        if (failPage) {
          return {
            'ok': false,
            'error': {'code': 'synthetic_page_unavailable'},
          };
        }
        result = {
          'events': [
            {
              'id': 'local-event',
              'conversationId': id,
              'sequence': 1,
              'authorMembershipId': 'owner',
              'kind': 'message',
              'finalized': true,
              'parts': <Object>[],
            },
          ],
          'hasEarlier': false,
        };
      case 'list-pending-completion-notices':
        result = {'pendingCompletionNotices': <Object>[]};
    }
    return {'ok': true, 'result': result};
  }

  Map<String, dynamic> _conversation(String id) => {
    'id': id,
    'title': id == _localId ? 'Local' : 'Other group',
    'isGroup': true,
    'pinned': id == _localId,
    'revision': 1,
    'eventCount': 1,
    'memberships': [
      {
        'id': 'owner',
        'conversationId': id,
        'principal': {
          'id': 'human:local',
          'kind': 'human',
          'displayName': 'You',
        },
        'access': 'owner',
        'status': 'active',
      },
    ],
  };
}

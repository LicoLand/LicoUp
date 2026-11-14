import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/composition/chrome_feature_apps.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/collaboration/collaboration_presentation_source.dart';

import '../support/presentation_binding_fakes.dart';
import 'support/collaboration_fixture.dart';

ConversationProjection _root(
  String conversationId, {
  ConversationAuthority authority = ConversationAuthority.canonicalConversation,
}) => ConversationProjection(
  authority: authority,
  conversationId: conversationId,
  membershipId: '',
);

CanonicalConversationProjection _canonical(
  String conversationId,
  String title,
) => CanonicalConversationProjection(
  conversationId: conversationId,
  events: const <CanonicalConversationEventProjection>[],
  conversation: conversationId.isEmpty
      ? null
      : ClientConversation(
          id: conversationId,
          title: title,
          archived: false,
          group: true,
          revision: 1,
          createdAtUnixMs: 0,
          updatedAtUnixMs: 0,
          memberships: const [],
          eventCount: 0,
        ),
  hasEarlier: false,
  phase: PresentationPhase.ready,
);

/// The selected conversation and one scripted run port per conversation.
final class _Harness {
  _Harness({String conversationId = 'conv-1', String title = 'Release review'})
    : root = MutableProjectionSource(_root(conversationId)),
      canonical = MutableProjectionSource(_canonical(conversationId, title));

  final MutableProjectionSource<ConversationProjection> root;
  final MutableProjectionSource<CanonicalConversationProjection> canonical;
  final Map<String, FakeCollaborationRunPort> ports = {};
  final Map<String, CollaborationPresentationSource> sources = {};
  final List<String> retained = [];
  final List<String> released = [];

  late final CollaborationAppFollower follower = CollaborationAppFollower(
    conversation: conversationBindingFake(
      projection: root,
      canonicalEvents: canonical,
    ),
    bindingFor: (conversationId) {
      retained.add(conversationId);
      final port = ports[conversationId] = FakeCollaborationRunPort();
      final source = sources[conversationId] = CollaborationPresentationSource(
        port: port,
        conversationId: conversationId,
      );
      return CollaborationBinding(
        projection: source,
        intents: source,
        effects: source,
      );
    },
    release: (conversationId) async {
      released.add(conversationId);
      await sources.remove(conversationId)?.dispose();
    },
  );

  void select(String conversationId, String title) {
    canonical.set(_canonical(conversationId, title));
    root.set(_root(conversationId));
  }

  Future<void> emit(
    String conversationId,
    CollaborationRunSnapshot snapshot,
  ) async {
    ports[conversationId]!.emit(snapshot);
    await pumpEventQueue();
  }

  Future<void> dispose() async {
    for (final source in sources.values) {
      await source.dispose();
    }
    for (final port in ports.values) {
      await port.close();
    }
    await root.close();
    await canonical.close();
  }
}

Map<String, CollaborationNodeState> _waitingOn(Set<String> nodes) => {
  for (final entry in collabStatesV2().entries)
    entry.key: nodes.contains(entry.key)
        ? collabState(CollaborationNodeStatus.waitingUser)
        : entry.key == 'idx'
        ? collabState(CollaborationNodeStatus.running)
        : entry.value,
};

void main() {
  late _Harness harness;
  late int notifications;

  void listener() => notifications += 1;

  setUp(() {
    harness = _Harness();
    notifications = 0;
  });
  tearDown(() => harness.dispose());

  group('following', () {
    test('stays idle until someone listens', () {
      expect(harness.follower.value, const LayoutCollaborationAppState());
      expect(harness.follower.binding, isNull);
      expect(harness.retained, isEmpty);
    });

    test('the first listener follows the selected group conversation', () {
      harness.follower.addListener(listener);

      expect(harness.retained, ['conv-1']);
      expect(harness.follower.conversationId, 'conv-1');
      expect(harness.follower.binding, isNotNull);
      expect(harness.follower.value.subtitle, 'Release review');
      expect(harness.follower.value.pendingDecisions, 0);
      expect(notifications, 0);
    });

    test('a native session is not followed', () {
      harness.root.set(
        _root('native-1', authority: ConversationAuthority.nativeCatalog),
      );
      harness.follower.addListener(listener);

      expect(harness.follower.binding, isNull);
      expect(harness.follower.conversationId, isEmpty);
      expect(harness.follower.value.subtitle, isEmpty);
      expect(harness.retained, isEmpty);
    });

    test(
      'the title waits for the canonical projection of the same conversation',
      () {
        harness.canonical.set(_canonical('conv-9', 'Another room'));
        harness.follower.addListener(listener);

        expect(harness.follower.conversationId, 'conv-1');
        expect(harness.follower.value.subtitle, isEmpty);

        harness.canonical.set(_canonical('conv-1', '  Release review  '));
        expect(harness.follower.value.subtitle, 'Release review');
        expect(notifications, 1);
      },
    );

    test('switching conversations releases the previous binding', () async {
      harness.follower.addListener(listener);

      harness.select('conv-2', 'Design sync');
      await pumpEventQueue();

      expect(harness.retained, ['conv-1', 'conv-2']);
      expect(harness.released, ['conv-1']);
      expect(harness.follower.conversationId, 'conv-2');
      expect(harness.follower.value.subtitle, 'Design sync');
      expect(notifications, greaterThanOrEqualTo(1));
    });

    test('leaving the group conversation releases the binding', () async {
      harness.follower.addListener(listener);

      harness.select('', '');
      await pumpEventQueue();

      expect(harness.released, ['conv-1']);
      expect(harness.follower.binding, isNull);
      expect(harness.follower.value, const LayoutCollaborationAppState());
    });
  });

  group('pending decisions', () {
    setUp(() => harness.follower.addListener(listener));

    test('counts the gates waiting for the user', () async {
      await harness.emit('conv-1', collabSnapshotV2());

      expect(harness.follower.value.pendingDecisions, 1);
      expect(notifications, 1);

      await harness.emit(
        'conv-1',
        collabSnapshotV2(nodeStates: _waitingOn({'arch', 's1', 's2'})),
      );
      expect(harness.follower.value.pendingDecisions, 3);
    });

    test('a held plan proposal counts as one decision', () async {
      await harness.emit('conv-1', collabSnapshotWithProposal());

      expect(harness.follower.value.pendingDecisions, 1);
    });

    test('a finished run has nothing pending', () async {
      await harness.emit('conv-1', collabSnapshotV2());
      await harness.emit('conv-1', collabSnapshotCompletedV3());

      expect(harness.follower.value.pendingDecisions, 0);
    });
  });

  group('listeners', () {
    test('the last listener leaving releases the binding', () async {
      void other() {}
      harness.follower.addListener(listener);
      harness.follower.addListener(other);

      harness.follower.removeListener(listener);
      expect(harness.released, isEmpty);

      harness.follower.removeListener(other);
      await pumpEventQueue();
      expect(harness.released, ['conv-1']);
      expect(harness.follower.binding, isNull);

      harness.select('conv-2', 'Design sync');
      expect(harness.retained, ['conv-1']);
    });

    test('a listener that was never added does not stop following', () {
      harness.follower.addListener(listener);

      harness.follower.removeListener(() {});

      expect(harness.follower.binding, isNotNull);
      expect(harness.released, isEmpty);
    });

    test('a listener added twice needs two removals', () async {
      harness.follower.addListener(listener);
      harness.follower.addListener(listener);

      harness.follower.removeListener(listener);
      expect(harness.follower.binding, isNotNull);

      harness.follower.removeListener(listener);
      await pumpEventQueue();
      expect(harness.follower.binding, isNull);
    });

    test('listening again follows the current selection', () async {
      harness.follower.addListener(listener);
      harness.follower.removeListener(listener);
      harness.select('conv-2', 'Design sync');

      harness.follower.addListener(listener);

      expect(harness.retained, ['conv-1', 'conv-2']);
      expect(harness.follower.value.subtitle, 'Design sync');
    });
  });

  group('surface', () {
    Future<void> pumpSurface(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.light),
          home: Scaffold(
            body: CollaborationAppSurface(follower: harness.follower),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('prompts for a group conversation when none is selected', (
      tester,
    ) async {
      harness.root.set(
        _root('native-1', authority: ConversationAuthority.nativeCatalog),
      );
      await pumpSurface(tester);

      expect(
        find.byKey(const Key('collaboration-app-no-conversation')),
        findsOneWidget,
      );
      expect(harness.retained, isEmpty);
    });

    testWidgets('shows the flowchart of the followed conversation and '
        'releases it when removed', (tester) async {
      await pumpSurface(tester);

      expect(find.byKey(const Key('collaboration-app-conv-1')), findsOneWidget);
      expect(harness.retained, ['conv-1']);

      harness.select('conv-2', 'Design sync');
      await tester.pump();
      expect(find.byKey(const Key('collaboration-app-conv-2')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(harness.released, ['conv-1', 'conv-2']);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/frontend/features/agents/ui/conversation/conversation_plane_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/conversation_plane_projection_source.dart';
import 'package:licoup/src/presentation/conversation/conversation_execution_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_source_port.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/conversation/conversation_projection_producer.dart';
import 'package:licoup/src/projections/conversation/conversation_source_owner.dart';

/// Real behavior evidence for the conversation plane sources.
///
/// The fixtures drive the producer's own channel type, so what is asserted here
/// is the admission, identity, consistency-group, and revocation behavior of
/// the runtime-backed planes, not a stand-in for it.
void main() {
  late PresentationRuntime runtime;
  late _PlaneFixture fixture;
  late ConversationSourceOwner owner;

  setUp(() async {
    runtime = PresentationRuntime();
    fixture = _PlaneFixture();
    owner = ConversationSourceOwner.spawn(
      runtime: runtime,
      planes: fixture.planes,
    );
    // The initial channel values enter admission in a microtask, like any
    // runtime source opening.
    await _settle();
  });

  tearDown(() async {
    await owner.dispose();
    runtime.dispose();
  });

  test(
    'every plane is admitted from its channel at its own resource',
    () async {
      expect(owner.projection.visibleValue, fixture.projection.current);
      expect(owner.nativeCatalog.visibleValue, fixture.nativeCatalog.current);
      expect(
        owner.canonicalEvents.visibleValue,
        fixture.canonicalEvents.current,
      );
      expect(
        owner.persistentTurns.visibleValue,
        fixture.persistentTurns.current,
      );
      expect(owner.composer.visibleValue, fixture.composer.current);
      expect(owner.attachments.visibleValue, fixture.attachments.current);
      expect(owner.tabActivity.visibleValue, fixture.tabActivity.current);
      expect(owner.archive.visibleValue, fixture.archive.current);
      expect(owner.execution?.visibleValue, fixture.execution.current);

      for (final plane in <ConversationPlanePort<Object?>>[
        owner.projection,
        owner.nativeCatalog,
        owner.canonicalEvents,
        owner.persistentTurns,
        owner.composer,
        owner.attachments,
        owner.tabActivity,
        owner.archive,
        owner.execution!,
      ]) {
        final admitted = runtime.current(plane.fieldGroup);
        expect(admitted, isNotNull, reason: plane.fieldGroup.name);
        expect(admitted!.version.value, 0);
        expect(
          admitted.consistencyGroup?.id,
          ConsistencyGroupId(
            'conversation-plane:${plane.fieldGroup.resource.stableKey}',
          ),
        );
      }
    },
  );

  test(
    'a channel update admits one version and notifies only its plane',
    () async {
      final composerReads = <ConversationPlaneRead<ComposerProjection>>[];
      final canonicalReads =
          <ConversationPlaneRead<CanonicalConversationProjection>>[];
      final releaseComposer = owner.composer.reads.listen(composerReads.add);
      final releaseCanonical = owner.canonicalEvents.reads.listen(
        canonicalReads.add,
      );
      addTearDown(() => releaseComposer.cancel());
      addTearDown(() => releaseCanonical.cancel());

      final next = _composer(revision: 3);
      fixture.composer.publish(next);
      await _settle();

      expect(owner.composer.visibleValue, next);
      expect(composerReads, hasLength(1));
      expect((composerReads.single as ConversationPlaneVisible).value, next);
      expect(canonicalReads, isEmpty, reason: 'narrow per-plane notification');
      expect(
        owner.canonicalEvents.visibleValue,
        fixture.canonicalEvents.current,
      );
      expect(
        runtime.current(owner.composer.fieldGroup)!.version.value,
        1,
        reason: 'the update is a new version of the same resource',
      );
      expect(
        runtime.current(owner.canonicalEvents.fieldGroup)!.version.value,
        0,
      );
    },
  );

  test('rebuilds never open another source incarnation', () async {
    for (var index = 0; index < 20; index++) {
      fixture.composer.publish(_composer(revision: index + 1));
    }
    await _settle();
    expect(
      runtime.current(owner.composer.fieldGroup)!.version.value,
      20,
      reason: 'one source, one version per read',
    );
    expect(
      owner.composer.fieldGroup.resource.stableKey,
      conversationPlaneComposer,
    );
    expect(
      owner.composer.fieldGroup,
      conversationPlaneFieldGroupFor<ComposerProjection>(
        conversationPlaneComposer,
      ),
      reason: 'the same resource field is reused, never recreated',
    );
  });

  test(
    'an authority withdrawal hides one plane and keeps the others',
    () async {
      final reads = <ConversationPlaneRead<ComposerProjection>>[];
      final subscription = owner.composer.reads.listen(reads.add);
      addTearDown(() => subscription.cancel());

      runtime.revoke(owner.composer.fieldGroup.resource);
      expect(owner.composer.visibleValue, isNull);
      expect(runtime.current(owner.composer.fieldGroup), isNull);
      expect(reads.last, isA<ConversationPlaneWithdrawn<ComposerProjection>>());
      expect(
        (reads.last as ConversationPlaneWithdrawn).reason,
        ConversationPlaneWithdrawal.revoked,
      );

      // An authorization-only change for one plane never marks the rest of the
      // conversation unreadable.
      expect(owner.canonicalEvents.visibleValue, isNotNull);
      expect(owner.persistentTurns.visibleValue, isNotNull);
      expect(owner.projection.visibleValue, isNotNull);

      // A producer read while withdrawn does not silently bring the plane back.
      fixture.composer.publish(_composer(revision: 9));
      await _settle();
      expect(owner.composer.visibleValue, isNull);
      expect(runtime.current(owner.composer.fieldGroup), isNull);
    },
  );

  test(
    'an explicit reconnect admits the provider value in a fresh epoch',
    () async {
      final before = runtime.current(owner.composer.fieldGroup)!;
      runtime.revoke(owner.composer.fieldGroup.resource);
      fixture.composer.publish(_composer(revision: 7));

      owner.reconnect(conversationPlaneComposer);
      await _settle();
      final after = runtime.current(owner.composer.fieldGroup);
      expect(after, isNotNull, reason: 'the real re-read is admitted');
      expect(after!.epoch, isNot(before.epoch));
      expect(
        after.version.value,
        0,
        reason: 'a fresh incarnation starts at v0',
      );
      expect(
        owner.composer.visibleValue,
        fixture.composer.current,
        reason:
            'the admitted value is the producer read, not a reconstructed one',
      );
      expect(
        (owner.composer as ConversationPlaneRuntime<ComposerProjection>)
            .incarnations,
        2,
      );
    },
  );

  test('dispose withdraws every plane as a scope end', () async {
    await owner.dispose();
    expect(owner.projection.visibleValue, isNull);
    expect(owner.composer.visibleValue, isNull);
    expect(runtime.current(owner.composer.fieldGroup), isNull);
    expect(runtime.current(owner.projection.fieldGroup), isNull);
  });

  test(
    'the initial value becomes visible only through runtime admission',
    () async {
      final freshRuntime = PresentationRuntime();
      final freshFixture = _PlaneFixture();
      final freshOwner = ConversationSourceOwner.spawn(
        runtime: freshRuntime,
        planes: freshFixture.planes,
      );
      addTearDown(() async {
        await freshOwner.dispose();
        freshRuntime.dispose();
      });

      // The producer already holds its channel value, but the plane is not
      // visible until the runtime admitted it: the owner never serves the
      // producer's current value as a cache.
      expect(freshFixture.composer.current, isNotNull);
      expect(freshOwner.composer.visibleValue, isNull);
      expect(freshRuntime.current(freshOwner.composer.fieldGroup), isNull);

      await _settle();
      expect(freshOwner.composer.visibleValue, freshFixture.composer.current);
      expect(freshRuntime.current(freshOwner.composer.fieldGroup), isNotNull);
    },
  );

  test('a projection adapter never serves a withdrawn plane value', () async {
    final reads = <ProjectionUpdate<ComposerProjection>>[];
    final source = ConversationPlaneProjectionSource<ComposerProjection>(
      owner.composer,
      empty: () => _composer(),
    );
    final subscription = source.changes.listen(reads.add);
    addTearDown(() => subscription.cancel());
    expect(source.current, owner.composer.visibleValue);

    final next = _composer(revision: 5);
    fixture.composer.publish(next);
    await _settle();
    expect(source.current, next);
    expect(reads, hasLength(1));

    runtime.revoke(owner.composer.fieldGroup.resource);
    expect(
      source.current.draft,
      isEmpty,
      reason: 'the withdrawn value is gone',
    );
    fixture.composer.publish(_composer(revision: 6));
    await _settle();
    expect(reads, hasLength(1), reason: 'a withdrawn plane publishes nothing');
    expect(source.current.draft, isEmpty);
  });

  testWidgets('a plane consumer shows, hides, and rebuilds locally', (
    tester,
  ) async {
    var composerBuilds = 0;
    var canonicalBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ConversationPlaneBuilder<ComposerProjection, String>(
                plane: owner.composer,
                select: (composer) =>
                    composer.draft.isEmpty ? 'empty draft' : composer.draft,
                builder: (context, selected) {
                  composerBuilds++;
                  return Text(selected);
                },
                emptyBuilder: (context) => const Text('hidden'),
              ),
              ConversationPlaneBuilder<CanonicalConversationProjection, String>(
                plane: owner.canonicalEvents,
                select: (canonical) => canonical.conversationId,
                builder: (context, selected) {
                  canonicalBuilds++;
                  return Text('canonical $selected');
                },
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('empty draft'), findsOneWidget);
    final composerBuildsBefore = composerBuilds;
    final canonicalBuildsBefore = canonicalBuilds;

    fixture.composer.publish(_composer(revision: 4));
    await _settleInWidget(tester);
    // ignore: avoid_print
    expect(find.text('draft 4'), findsOneWidget);
    expect(
      composerBuilds,
      greaterThan(composerBuildsBefore),
      reason: 'the plane consumer rebuilds for its own read',
    );
    expect(
      canonicalBuilds,
      canonicalBuildsBefore,
      reason: 'a sibling plane does not rebuild for another plane read',
    );

    runtime.revoke(owner.composer.fieldGroup.resource);
    await _settleInWidget(tester);
    expect(find.text('hidden'), findsOneWidget);
    expect(find.text('draft 4'), findsNothing);
    await tester.pump();
  });
}

/// The producer's own channel type, driven by production-shaped fixtures.
final class _PlaneFixture {
  _PlaneFixture()
    : projection = ConversationProjectionChannel<ConversationProjection>(
        _root(),
      ),
      nativeCatalog =
          ConversationProjectionChannel<NativeConversationCatalogProjection>(
            _nativeCatalog(),
          ),
      canonicalEvents =
          ConversationProjectionChannel<CanonicalConversationProjection>(
            _canonical(),
          ),
      persistentTurns = ConversationProjectionChannel<PersistentTurnProjection>(
        _turns(),
      ),
      composer = ConversationProjectionChannel<ComposerProjection>(_composer()),
      attachments =
          ConversationProjectionChannel<ConversationAttachmentsProjection>(
            _attachments(),
          ),
      tabActivity =
          ConversationProjectionChannel<ConversationTabActivityProjection>(
            _tabActivity(),
          ),
      archive = ConversationProjectionChannel<ConversationArchiveProjection>(
        _archive(),
      ),
      execution =
          ConversationProjectionChannel<ConversationExecutionProjection>(
            ConversationExecutionProjection(),
          );

  final ConversationProjectionChannel<ConversationProjection> projection;
  final ConversationProjectionChannel<NativeConversationCatalogProjection>
  nativeCatalog;
  final ConversationProjectionChannel<CanonicalConversationProjection>
  canonicalEvents;
  final ConversationProjectionChannel<PersistentTurnProjection> persistentTurns;
  final ConversationProjectionChannel<ComposerProjection> composer;
  final ConversationProjectionChannel<ConversationAttachmentsProjection>
  attachments;
  final ConversationProjectionChannel<ConversationTabActivityProjection>
  tabActivity;
  final ConversationProjectionChannel<ConversationArchiveProjection> archive;
  final ConversationProjectionChannel<ConversationExecutionProjection>
  execution;

  ConversationSourcePlanes get planes => ConversationSourcePlanes(
    projection: projection,
    nativeCatalog: nativeCatalog,
    canonicalEvents: canonicalEvents,
    persistentTurns: persistentTurns,
    composer: composer,
    attachments: attachments,
    tabActivity: tabActivity,
    archive: archive,
    execution: execution,
  );
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

/// Lets a runtime admission settle while the widget binding keeps pumping.
Future<void> _settleInWidget(WidgetTester tester) async {
  for (var frame = 0; frame < 40; frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 5));
  }
}

ConversationProjection _root() => const ConversationProjection(
  authority: ConversationAuthority.canonicalConversation,
  conversationId: 'c-1',
  membershipId: 'm-1',
);

NativeConversationCatalogProjection _nativeCatalog() =>
    NativeConversationCatalogProjection(
      sessions: const <NativeConversationSessionProjection>[],
      hasMore: false,
      phase: PresentationPhase.ready,
    );

CanonicalConversationProjection _canonical() => CanonicalConversationProjection(
  conversationId: 'c-1',
  events: const <CanonicalConversationEventProjection>[],
  hasEarlier: false,
  phase: PresentationPhase.ready,
);

PersistentTurnProjection _turns() => PersistentTurnProjection(
  conversationId: 'c-1',
  memberships: const <MembershipTurnProjection>[],
);

ComposerProjection _composer({int revision = 0}) => ComposerProjection(
  conversationId: 'c-1',
  draft: revision == 0 ? '' : 'draft $revision',
  inputEnabled: true,
  sendLabel: 'Send',
);

ConversationAttachmentsProjection _attachments() =>
    ConversationAttachmentsProjection(
      conversationId: 'c-1',
      attachments: const <ConversationAttachmentProjection>[],
      acceptsImages: true,
    );

ConversationTabActivityProjection _tabActivity() =>
    ConversationTabActivityProjection(
      conversationId: 'c-1',
      active: true,
      unreadCount: 0,
      requiresAttention: false,
    );

ConversationArchiveProjection _archive() => ConversationArchiveProjection(
  conversations: const <ArchivedConversationItemProjection>[],
  phase: PresentationPhase.ready,
);

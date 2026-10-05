import 'package:licoup/src/composition/features/models/native_selection_composition.dart';
import 'package:licoup/src/frontend/features/models/selection/selection_policy_view.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_selection_actions.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'the composed facts source reads the matrix through the projection',
    () async {
      final transport = _SelectionTransport()..document = _matrixDocument();
      final composition = nativeSelectionComposition(
        NativeSelectionActions(stdioRpcTransport: transport),
      );

      final projection = await composition.readFacts('codex');
      expect(transport.methods, <String>['selection.matrix']);
      expect(projection.phase, PresentationPhase.ready);
      expect(projection.agent, 'codex');
      expect(projection.entries, hasLength(1));
      expect(projection.entries.single.model, 'k3-256k');
      expect(projection.entries.single.outcomeFor('direct')?.executes, isFalse);
    },
  );

  test(
    'a refused matrix is a failed projection, never an empty ready one',
    () async {
      final composition = nativeSelectionComposition(
        NativeSelectionActions(
          stdioRpcTransport: const _RefusingTransport(
            'selection_matrix_unavailable',
          ),
        ),
      );

      final projection = await composition.readFacts('codex');
      expect(projection.phase, PresentationPhase.failed);
      expect(projection.entries, isEmpty);
      expect(projection.notice, isNotNull);
      expect(
        projection.notice!.reasonCode,
        'selection_matrix_unavailable',
        reason: 'the refusal keeps the code the owner reported',
      );
    },
  );

  test(
    'a document the projection refuses is a failed projection too',
    () async {
      final transport = _SelectionTransport()
        ..document = <String, dynamic>{'schemaVersion': 99};
      final composition = nativeSelectionComposition(
        NativeSelectionActions(stdioRpcTransport: transport),
      );

      final projection = await composition.readFacts('codex');
      expect(projection.phase, PresentationPhase.failed);
      expect(projection.entries, isEmpty);
    },
  );

  test(
    'the composed policy source reports the revision the owner stated',
    () async {
      final transport = _SelectionTransport()
        ..binding = const <String, dynamic>{
          'revisionId': 'policy:r2',
          'revisionName': 'policy:r2',
        };
      final composition = nativeSelectionComposition(
        NativeSelectionActions(stdioRpcTransport: transport),
      );

      final view = await composition.readPolicy();
      expect(view.revisionInForce, 'policy:r2');
      expect(view.hasAdoptedPolicy, isTrue);
      expect(
        view.notice!.reasonCode,
        selectionSuggestionsSourceAbsentCode,
        reason: 'the suggestions half has no source and must say so',
      );
    },
  );

  test('an unadopted register reports no revision to revoke', () async {
    final transport = _SelectionTransport()
      ..binding = const <String, dynamic>{'revisionName': 'unadopted'};
    final composition = nativeSelectionComposition(
      NativeSelectionActions(stdioRpcTransport: transport),
    );

    final view = await composition.readPolicy();
    expect(view.revisionInForce, isEmpty);
    expect(view.hasAdoptedPolicy, isFalse);
    expect(view.suggestions, isEmpty);
  });

  test(
    'an unreadable register is a failed policy view, not an unadopted one',
    () async {
      final composition = nativeSelectionComposition(
        NativeSelectionActions(
          stdioRpcTransport: const _RefusingTransport(
            'selection_policy_unavailable',
          ),
        ),
      );

      final view = await composition.readPolicy();
      expect(view.phase, PresentationPhase.failed);
      expect(view.revisionInForce, isEmpty);
      expect(view.notice!.reasonCode, 'selection_policy_unavailable');
    },
  );

  test('revoke is the owner transition and a refusal keeps its code', () async {
    final transport = _SelectionTransport();
    final composition = nativeSelectionComposition(
      NativeSelectionActions(stdioRpcTransport: transport),
    );

    expect(
      await composition.actions.revoke('policy:r2'),
      const SelectionPolicyOutcome.accepted(),
    );
    expect(transport.methods, <String>['selection.policy.revoke']);
    expect(transport.params.single, <String, dynamic>{
      'revisionId': 'policy:r2',
    });

    final stale = nativeSelectionComposition(
      NativeSelectionActions(
        stdioRpcTransport: const _RefusingTransport(
          'selection_policy_not_in_force',
        ),
      ),
    );
    expect(
      await stale.actions.revoke('policy:r1'),
      const SelectionPolicyOutcome.refused('selection_policy_not_in_force'),
    );
  });

  test(
    'adopting a suggestion refuses because no owner turns one into a revision',
    () async {
      final transport = _SelectionTransport();
      final composition = nativeSelectionComposition(
        NativeSelectionActions(stdioRpcTransport: transport),
      );

      expect(
        await composition.actions.adopt('suggestion-1'),
        const SelectionPolicyOutcome.refused(
          selectionSuggestionRevisionAbsentCode,
        ),
      );
      expect(
        transport.methods,
        isEmpty,
        reason: 'a refused approval must write nothing and call no owner',
      );
    },
  );

  testWidgets('the composed section revokes the revision the reader saw', (
    tester,
  ) async {
    final transport = _SelectionTransport()
      ..binding = const <String, dynamic>{
        'revisionId': 'policy:r2',
        'revisionName': 'policy:r2',
      };
    final composition = nativeSelectionComposition(
      NativeSelectionActions(stdioRpcTransport: transport),
    );
    final view = await composition.readPolicy();

    await tester.pumpWidget(MaterialApp(home: composition.policySection(view)));
    expect(find.byKey(const Key('selection-policy-revision')), findsOneWidget);
    expect(find.text('policy:r2'), findsOneWidget);
    // The suggestions half says it could not be read instead of claiming there
    // is nothing to adopt.
    expect(find.byKey(const Key('selection-policy-notice')), findsOneWidget);
    expect(
      find.byKey(const Key('selection-policy-no-suggestions')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('selection-policy-revoke')));
    await tester.pumpAndSettle();

    // The tap revoked exactly the revision the reader saw, exactly once, and the
    // revision argument came from the read rather than from the widget.
    expect(
      transport.methods.where((method) => method == 'selection.policy.revoke'),
      hasLength(1),
    );
    expect(transport.methods.last, 'selection.policy.revoke');
    expect(transport.params.last, <String, dynamic>{'revisionId': 'policy:r2'});
  });
}

/// One Agent's matrix document as the owner renders it.
Map<String, dynamic> _matrixDocument() => <String, dynamic>{
  'schemaVersion': 1,
  'scopes': <String>['direct', 'workflow'],
  'agent': 'codex',
  'generation': 'generation-1',
  'observedAtUnixMs': 1726000000000,
  'entries': <Object?>[
    <String, dynamic>{
      'agent': 'codex',
      'model': 'k3-256k',
      'canonicalId': 'moonshotai/kimi-k3',
      'canonicalDisplayName': 'Kimi K3',
      'evidence': 'observed',
      'support': <String, dynamic>{
        'state': 'supported',
        'reason': 'declared_identity',
      },
      'availability': <String, dynamic>{
        'state': 'observed',
        'reason': 'observed_by_live_source',
        'observedAtUnixMs': 1726000000000,
      },
      'credentials': <String, dynamic>{
        'state': 'unknown',
        'reason': 'provider_credential_unknown',
      },
      'providers': <String>['kimi-for-coding'],
      'scopes': <Object?>[
        <String, dynamic>{
          'scope': 'direct',
          'state': 'undetermined',
          'reason': 'selection_policy_owner_absent',
        },
        <String, dynamic>{
          'scope': 'workflow',
          'state': 'undetermined',
          'reason': 'selection_policy_owner_absent',
        },
      ],
    },
  ],
};

/// A transport that answers the selection methods from one canned answer.
final class _SelectionTransport implements NativeStdioRpcTransport {
  final List<String> methods = <String>[];
  final List<Map<String, dynamic>> params = <Map<String, dynamic>>[];
  Object? document = const <String, dynamic>{'schemaVersion': 1};
  Object? binding = const <String, dynamic>{'revisionName': 'unadopted'};

  @override
  Future<Map<String, dynamic>> executeStructured(
    String method,
    Map<String, dynamic> request,
  ) async {
    methods.add(method);
    params.add(request);
    return switch (method) {
      'selection.matrix' => <String, dynamic>{'matrix': document},
      _ => <String, dynamic>{'policy': binding},
    };
  }

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) =>
      throw UnsupportedError('raw selection CLI is not part of this contract');

  @override
  Stream<Map<String, dynamic>> streamConversation(
    Map<String, dynamic> request,
  ) => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

/// A transport that refuses every request with one code.
final class _RefusingTransport implements NativeStdioRpcTransport {
  const _RefusingTransport(this.code);

  final String code;

  @override
  Future<Map<String, dynamic>> executeStructured(
    String method,
    Map<String, dynamic> params,
  ) => Future<Map<String, dynamic>>.error(LicoClientRpcException(code));

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) =>
      throw UnsupportedError('raw selection CLI is not part of this contract');

  @override
  Stream<Map<String, dynamic>> streamConversation(
    Map<String, dynamic> request,
  ) => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

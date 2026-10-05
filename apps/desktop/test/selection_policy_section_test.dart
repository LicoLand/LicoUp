import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/models/selection/selection_policy_section.dart';
import 'package:licoup/src/frontend/features/models/selection/selection_policy_view.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Records every action it was asked to take, so a test can tell an action the
/// surface dispatched from one it only displayed.
final class _RecordingActions implements SelectionPolicyActions {
  _RecordingActions({this.outcome = const SelectionPolicyOutcome.accepted()});

  final SelectionPolicyOutcome outcome;
  final List<String> calls = <String>[];

  @override
  Future<SelectionPolicyOutcome> adopt(String suggestionId) async {
    calls.add('adopt:$suggestionId');
    return outcome;
  }

  @override
  Future<SelectionPolicyOutcome> dismiss(String suggestionId) async {
    calls.add('dismiss:$suggestionId');
    return outcome;
  }

  @override
  Future<SelectionPolicyOutcome> revoke(String revisionInForce) async {
    calls.add('revoke:$revisionInForce');
    return outcome;
  }
}

SelectionSuggestionView _suggestion({
  String id = 'suggestion-a',
  SelectionEvaluation evaluation = SelectionEvaluation.usable,
  SelectionPromotionSubject subject = SelectionPromotionSubject.routingOnly,
  bool invalidated = false,
  List<String> effects = const ['next task prefers the cheaper route'],
}) => SelectionSuggestionView(
  suggestionId: id,
  evaluatorId: 'judging-agent',
  evaluation: evaluation,
  rationale: 'the paired live sample is cheaper at equal acceptance',
  evidenceDigest: 'outcome-0123456789abcdef',
  evidenceLimits: 'two terminal samples in one project',
  promotionSubject: subject,
  proposedEffects: effects,
  invalidated: invalidated,
);

SelectionPolicyView _view({
  String revisionInForce = 'policy-1',
  List<SelectionSuggestionView> suggestions = const [],
  PresentationPhase phase = PresentationPhase.ready,
  PresentationNotice? notice,
}) => SelectionPolicyView(
  revisionInForce: revisionInForce,
  suggestions: suggestions,
  phase: phase,
  notice: notice,
);

Future<void> _pump(
  WidgetTester tester, {
  required SelectionPolicyView view,
  required SelectionPolicyActions actions,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SelectionPolicySection(view: view, actions: actions),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a visible adopted policy offers revoke and reports it', (
    tester,
  ) async {
    final actions = _RecordingActions();
    await _pump(tester, view: _view(), actions: actions);

    expect(find.text('policy-1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('selection-policy-revoke')));
    await tester.pumpAndSettle();

    expect(actions.calls, ['revoke:policy-1']);
    expect(find.byKey(const Key('selection-policy-refusal')), findsNothing);
  });

  testWidgets('an unadopted policy offers no revoke', (tester) async {
    final actions = _RecordingActions();
    await _pump(tester, view: _view(revisionInForce: ''), actions: actions);

    expect(find.byKey(const Key('selection-policy-revoke')), findsNothing);
    expect(find.text('No policy is adopted'), findsOneWidget);
  });

  testWidgets('a suggestion shows its evaluator, limits and effects first', (
    tester,
  ) async {
    final actions = _RecordingActions();
    await _pump(
      tester,
      view: _view(suggestions: [_suggestion()]),
      actions: actions,
    );

    // Everything a reader needs is on screen before the approve control is.
    expect(
      find.byKey(const Key('selection-suggestion-evaluator-suggestion-a')),
      findsOneWidget,
    );
    expect(find.text('judging-agent'), findsOneWidget);
    expect(
      find.byKey(const Key('selection-suggestion-limits-suggestion-a')),
      findsOneWidget,
    );
    expect(find.text('two terminal samples in one project'), findsOneWidget);
    expect(find.textContaining('outcome-0123456789abcdef'), findsOneWidget);
    expect(
      find.textContaining('next task prefers the cheaper route'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('selection-suggestion-adopt-suggestion-a')),
      findsOneWidget,
    );
  });

  testWidgets('a routing-only sample is labelled as such', (tester) async {
    await _pump(
      tester,
      view: _view(suggestions: [_suggestion()]),
      actions: _RecordingActions(),
    );

    expect(
      find.byKey(const Key('selection-suggestion-routing-only-suggestion-a')),
      findsOneWidget,
    );
  });

  testWidgets('a context sample is not labelled routing-only', (tester) async {
    await _pump(
      tester,
      view: _view(
        suggestions: [
          _suggestion(subject: SelectionPromotionSubject.routingAndContext),
        ],
      ),
      actions: _RecordingActions(),
    );

    expect(
      find.byKey(const Key('selection-suggestion-routing-only-suggestion-a')),
      findsNothing,
    );
  });

  testWidgets('an invalidated suggestion cannot be approved', (tester) async {
    final actions = _RecordingActions();
    await _pump(
      tester,
      view: _view(suggestions: [_suggestion(invalidated: true)]),
      actions: actions,
    );

    expect(
      find.byKey(const Key('selection-suggestion-adopt-suggestion-a')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('selection-suggestion-invalidated-suggestion-a')),
      findsOneWidget,
    );
  });

  testWidgets('a dismissed suggestion keeps the current policy', (
    tester,
  ) async {
    final actions = _RecordingActions();
    await _pump(
      tester,
      view: _view(suggestions: [_suggestion()]),
      actions: actions,
    );

    await tester.tap(
      find.byKey(const Key('selection-suggestion-dismiss-suggestion-a')),
    );
    await tester.pumpAndSettle();

    expect(actions.calls, ['dismiss:suggestion-a']);
    expect(find.byKey(const Key('selection-policy-kept')), findsOneWidget);
    // The policy in force is untouched by a dismissal.
    expect(find.text('policy-1'), findsOneWidget);
  });

  testWidgets('every non-usable evaluation is evidence, never a proposal', (
    tester,
  ) async {
    for (final evaluation in <SelectionEvaluation>[
      SelectionEvaluation.rejected,
      SelectionEvaluation.uncertain,
      SelectionEvaluation.missing,
    ]) {
      await _pump(
        tester,
        view: _view(suggestions: [_suggestion(evaluation: evaluation)]),
        actions: _RecordingActions(),
      );
      expect(
        find.byKey(const Key('selection-suggestion-adopt-suggestion-a')),
        findsNothing,
        reason: '$evaluation must not offer an approve control',
      );
      expect(
        find.byKey(const Key('selection-suggestion-dismiss-suggestion-a')),
        findsOneWidget,
      );
    }
  });

  testWidgets('a refusal is reported verbatim and changes nothing', (
    tester,
  ) async {
    final actions = _RecordingActions(
      outcome: const SelectionPolicyOutcome.refused('policy_revision_conflict'),
    );
    await _pump(tester, view: _view(), actions: actions);

    await tester.tap(find.byKey(const Key('selection-policy-revoke')));
    await tester.pumpAndSettle();

    expect(actions.calls, ['revoke:policy-1']);
    expect(find.text('Not applied: policy_revision_conflict'), findsOneWidget);
  });

  testWidgets('an absent owner is named instead of a silent success', (
    tester,
  ) async {
    await _pump(
      tester,
      view: _view(),
      actions: const UnavailableSelectionPolicyActions(),
    );

    await tester.tap(find.byKey(const Key('selection-policy-revoke')));
    await tester.pumpAndSettle();

    expect(
      find.text('This build composes no policy owner; nothing was changed.'),
      findsOneWidget,
    );
  });

  testWidgets('a failed read is reported instead of an empty success', (
    tester,
  ) async {
    await _pump(
      tester,
      view: _view(
        revisionInForce: '',
        phase: PresentationPhase.failed,
        notice: const PresentationNotice(
          id: 'selection-policy-unavailable',
          title: 'Route selection policy',
          message: 'The selection policy could not be read.',
          severity: PresentationNoticeSeverity.error,
          reasonCode: 'selection_policy_owner_absent',
        ),
      ),
      actions: _RecordingActions(),
    );

    expect(find.byKey(const Key('selection-policy-notice')), findsOneWidget);
    expect(
      find.textContaining('selection_policy_owner_absent'),
      findsOneWidget,
    );
  });

  testWidgets('a read in progress offers no action against an unseen policy', (
    tester,
  ) async {
    await _pump(
      tester,
      view: _view(phase: PresentationPhase.loading),
      actions: _RecordingActions(),
    );

    expect(find.byKey(const Key('selection-policy-loading')), findsOneWidget);
    expect(find.byKey(const Key('selection-policy-revoke')), findsNothing);
  });

  testWidgets('a passive suggestion blocks nothing and dispatches nothing', (
    tester,
  ) async {
    final actions = _RecordingActions();
    await _pump(
      tester,
      view: _view(suggestions: [_suggestion(), _suggestion(id: 'suggestion-b')]),
      actions: actions,
    );

    // Rendering a suggestion is not acting on it: no call happens until the
    // user names one.
    expect(actions.calls, isEmpty);
    expect(find.byKey(const Key('selection-policy-refusal')), findsNothing);
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/composition/features/models/selection_policy_composition.dart';
import 'package:licoup/src/frontend/features/models/selection/selection_policy_view.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fail-closed composition', () {
    const composition = SelectionPolicyComposition.unavailable();

    test('adopting a suggestion changes nothing and is refused', () async {
      final outcome = await composition.actions.adopt('suggestion-a');

      expect(outcome.accepted, isFalse);
      expect(outcome.reasonCode, selectionPolicyOwnerAbsentCode);
    });

    test('revoking a visible policy changes nothing and is refused', () async {
      final outcome = await composition.actions.revoke('policy-1');

      expect(outcome.accepted, isFalse);
      expect(outcome.reasonCode, selectionPolicyOwnerAbsentCode);
    });

    test('dismissing a suggestion is accepted and keeps the policy', () async {
      final outcome = await composition.actions.dismiss('suggestion-a');

      expect(outcome.accepted, isTrue);
      expect(outcome.reasonCode, isEmpty);
    });

    test('an unreadable policy is a failure, not an empty success', () async {
      final view = await composition.readPolicy();

      expect(view.phase, PresentationPhase.failed);
      expect(view.revisionInForce, isEmpty);
      expect(view.hasAdoptedPolicy, isFalse);
      expect(view.notice?.reasonCode, selectionPolicyOwnerAbsentCode);
    });

    test('unreadable facts are a failure, not an empty success', () async {
      final projection = await composition.readFacts('kimi-code');

      expect(projection.phase, PresentationPhase.failed);
      expect(projection.entries, isEmpty);
      expect(projection.notice?.reasonCode, selectionFactsSourceAbsentCode);
    });

    test('rendering the surfaces dispatches no action', () async {
      // The composition exposes the surfaces for a caller that already read a
      // view; building them is passive and takes no policy action.
      final view = await composition.readPolicy();
      expect(composition.policySection(view), isNotNull);
      expect(composition.factsSection(await composition.readFacts('a')), isNotNull);
    });
  });

  group('SelectionPolicyView', () {
    test('separates a suggestion from an adopted policy', () {
      final view = SelectionPolicyView(
        revisionInForce: '',
        suggestions: [
          SelectionSuggestionView(
            suggestionId: 'suggestion-a',
            evaluatorId: 'judging-agent',
            evaluation: SelectionEvaluation.usable,
            rationale: 'cheaper at equal acceptance',
            evidenceDigest: 'outcome-1',
            evidenceLimits: 'one project, two samples',
            promotionSubject: SelectionPromotionSubject.routingOnly,
            proposedEffects: const ['next task prefers the cheaper route'],
          ),
        ],
        phase: PresentationPhase.ready,
      );

      // A usable suggestion is actionable while nothing is adopted yet: a
      // proposal is not a policy.
      expect(view.hasAdoptedPolicy, isFalse);
      expect(view.actionableSuggestions, hasLength(1));
    });

    test('an invalidated suggestion is no longer actionable', () {
      final view = SelectionPolicyView(
        revisionInForce: 'policy-1',
        suggestions: [
          SelectionSuggestionView(
            suggestionId: 'suggestion-a',
            evaluatorId: 'judging-agent',
            evaluation: SelectionEvaluation.usable,
            rationale: 'cheaper at equal acceptance',
            evidenceDigest: 'outcome-1',
            evidenceLimits: 'one project, two samples',
            promotionSubject: SelectionPromotionSubject.routingOnly,
            proposedEffects: const [],
            invalidated: true,
          ),
        ],
        phase: PresentationPhase.ready,
      );

      expect(view.hasAdoptedPolicy, isTrue);
      expect(view.actionableSuggestions, isEmpty);
    });
  });
}

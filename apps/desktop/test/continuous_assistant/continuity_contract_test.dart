import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant.dart';

import 'support/continuous_assistant_test_harness.dart';

Directory _fixturesRoot() {
  final fromDesktop = Directory(
    '../../tests/fixtures/continuous-assistant/contracts',
  );
  if (fromDesktop.existsSync()) {
    return fromDesktop;
  }
  return Directory('tests/fixtures/continuous-assistant/contracts');
}

Map<String, Object?> _readFixture(String relative) {
  return jsonDecode(
        File('${_fixturesRoot().path}/$relative').readAsStringSync(),
      )
      as Map<String, Object?>;
}

Object? _parse(String typeName, Object? payload) {
  switch (typeName) {
    case 'SourceRef':
      return ContinuitySourceRef.parse(payload);
    case 'Matter':
      return ContinuityMatter.parse(payload);
    case 'Agreement':
      return ContinuityAgreement.parse(payload);
    case 'GoalContract':
      return ContinuityGoalContract.parse(payload);
    case 'GoalProgress':
      return ContinuityGoalProgress.parse(payload);
    case 'InterpretationProposal':
      return ContinuityInterpretationProposal.parse(payload);
    case 'ContextManifest':
      return ContinuityContextManifest.parse(payload);
    case 'WorkContext':
      return ContinuityWorkContext.parse(payload);
    case 'Wake':
      return ContinuityWake.parse(payload);
    case 'QualificationRecord':
      return ContinuityQualificationRecord.parse(payload);
    case 'ParentCardAnchor':
      return ContinuityParentCardAnchor.parse(payload);
    case 'GoalCompletionTransition':
      return ContinuityGoalCompletionTransition.parse(payload);
    case 'ParentContextGrant':
      return ContinuityParentContextGrant.parse(payload);
    case 'TaskChildAdmission':
      return ContinuityTaskChildAdmission.parse(payload);
    case 'TaskConversationRelation':
      return ContinuityTaskConversationRelation.parse(payload);
    case 'ParentGrantBasis':
      return ContinuityParentGrantBasis.parse(payload);
    case 'ContextCompositionRequest':
      return ContinuityContextCompositionRequest.parse(payload);
    default:
      throw StateError('unknown fixture type $typeName');
  }
}

Map<String, Object?> _toJson(Object parsed) {
  return switch (parsed) {
    ContinuitySourceRef value => value.toJson(),
    ContinuityMatter value => value.toJson(),
    ContinuityAgreement value => value.toJson(),
    ContinuityGoalContract value => value.toJson(),
    ContinuityGoalProgress value => value.toJson(),
    ContinuityInterpretationProposal value => value.toJson(),
    ContinuityContextManifest value => value.toJson(),
    ContinuityWorkContext value => value.toJson(),
    ContinuityWake value => value.toJson(),
    ContinuityQualificationRecord value => value.toJson(),
    ContinuityParentCardAnchor value => value.toJson(),
    ContinuityGoalCompletionTransition value => value.toJson(),
    ContinuityParentContextGrant value => value.toJson(),
    ContinuityTaskChildAdmission value => value.toJson(),
    ContinuityTaskConversationRelation value => value.toJson(),
    ContinuityParentGrantBasis value => value.toJson(),
    ContinuityContextCompositionRequest value => value.toJson(),
    _ => throw StateError('unserializable ${parsed.runtimeType}'),
  };
}

void main() {
  test('legal fixtures parse and round-trip through generated Dart types', () {
    final legal = Directory('${_fixturesRoot().path}/legal');
    var accepted = 0;
    for (final file in legal.listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      final fixture =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final expectation = fixture['expect']! as Map<String, Object?>;
      if (expectation['check'] == 'span') {
        final text = fixture['text']! as String;
        final payload = fixture['payload']! as Map<String, Object?>;
        expect(
          continuityUtf8SpanIsValid(
            text,
            payload['startByte']! as int,
            payload['endByte']! as int,
          ),
          isTrue,
        );
        accepted += 1;
        continue;
      }
      if (expectation['check'] == 'sibling-order') {
        expect(_parse('ParentCardAnchor', fixture['left']), isNotNull);
        expect(_parse('ParentCardAnchor', fixture['right']), isNotNull);
        accepted += 1;
        continue;
      }
      final parsed = _parse(expectation['type']! as String, fixture['payload']);
      final encoded = _toJson(parsed!);
      expect(encoded, fixture['payload']);
      expect(
        _toJson(_parse(expectation['type']! as String, encoded)!),
        encoded,
      );
      accepted += 1;
    }
    expect(accepted, greaterThanOrEqualTo(9));
  });

  test('unknown fields and invalid UTF-8 spans are rejected', () {
    final unknown = _readFixture('illegal/unknown-field.json');
    expect(
      () => ContinuityMatter.parse(unknown['payload']),
      throwsA(isA<ContinuityContractException>()),
    );
    final span = _readFixture('illegal/invalid-span.json');
    final payload = span['payload']! as Map<String, Object?>;
    expect(
      continuityUtf8SpanIsValid(
        span['text']! as String,
        payload['startByte']! as int,
        payload['endByte']! as int,
      ),
      isFalse,
    );
  });

  test(
    'missing and wrongly typed scalars fail as ContinuityContractException',
    () {
      Matcher typedFailure() {
        return throwsA(
          isA<ContinuityContractException>().having(
            (error) => error.code,
            'code',
            ContinuityFailureCode.invalidRequest,
          ),
        );
      }

      final source = Map<String, Object?>.from(
        _readFixture('legal/source-ref.json')['payload']! as Map,
      );
      expect(
        () => ContinuitySourceRef.parse(
          Map<String, Object?>.from(source)..remove('opaqueId'),
        ),
        typedFailure(),
      );
      expect(
        () => ContinuitySourceRef.parse(
          Map<String, Object?>.from(source)..['opaqueId'] = 1,
        ),
        typedFailure(),
      );

      final matter = Map<String, Object?>.from(
        _readFixture('legal/matter.json')['payload']! as Map,
      );
      expect(
        () => ContinuityMatter.parse(
          Map<String, Object?>.from(matter)..['revision'] = '3',
        ),
        typedFailure(),
      );
      expect(
        () => ContinuityMatter.parse(
          Map<String, Object?>.from(matter)
            ..['createdEvent'] = 'event:fixture-one',
        ),
        typedFailure(),
      );

      final qualification = Map<String, Object?>.from(
        _readFixture('legal/qualification.json')['payload']! as Map,
      );
      expect(
        () => ContinuityQualificationRecord.parse(
          Map<String, Object?>.from(qualification)..['revoked'] = 'false',
        ),
        typedFailure(),
      );

      final progress = Map<String, Object?>.from(
        _readFixture('legal/goal-progress.json')['payload']! as Map,
      );
      expect(
        () => ContinuityGoalProgress.parse(
          Map<String, Object?>.from(progress)..['nextAttention'] = true,
        ),
        typedFailure(),
      );
      expect(
        () => ContinuityGoalProgress.parse(
          Map<String, Object?>.from(progress)
            ..['criterionEvidenceRefs'] = 'none',
        ),
        typedFailure(),
      );
    },
  );

  testWidgets(
    'projection renders unavailable effect class without synthesizing a goal',
    (tester) async {
      const failure = ContinuityFailure(
        code: ContinuityFailureCode.unsupportedCapability,
        stage: ContinuityFailureStage.continuityCommit,
        recovery: ContinuityRecoveryClass.reviewOrWait,
        effectClass: ContinuityEffectClass.none,
        decisionLayer: ContinuityDecisionLayer.effects,
        retryable: false,
      );
      await tester.pumpWidget(
        wrapContinuousAssistant(
          const ContinuousAssistantProjection(failure: failure),
        ),
      );
      expect(find.byKey(ContinuousAssistantKeys.unavailable), findsOneWidget);
      expect(find.byKey(ContinuousAssistantKeys.timeline), findsNothing);
      expect(
        find.textContaining('unsupported_capability:none'),
        findsOneWidget,
      );
    },
  );
}

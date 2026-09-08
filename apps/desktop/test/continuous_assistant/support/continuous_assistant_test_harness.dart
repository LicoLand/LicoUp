import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

Directory _fixturesRoot() {
  final fromDesktop = Directory(
    '../../tests/fixtures/continuous-assistant/contracts',
  );
  if (fromDesktop.existsSync()) {
    return fromDesktop;
  }
  return Directory('tests/fixtures/continuous-assistant/contracts');
}

Map<String, Object?> readContinuityFixture(String relative) {
  return jsonDecode(
        File('${_fixturesRoot().path}/$relative').readAsStringSync(),
      )
      as Map<String, Object?>;
}

ContinuitySourceRef testSourceRef({
  String opaqueId = 'event:fixture-one',
  String? partId,
  int sourceRevision = 1,
}) {
  return ContinuitySourceRef(
    ownerKind: ContinuitySourceOwnerKind.event,
    opaqueId: opaqueId,
    partId: partId,
    sourceRevision: sourceRevision,
    digest:
        'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    visibilityScope: ContinuityVisibilityScope.conversation,
    validity: ContinuitySourceValidity.current,
  );
}

ContinuityParentCardAnchor testCardAnchor({
  required String eventId,
  required int sequence,
  String parentConversationId = 'conversation:parent',
  String? partId,
}) {
  return ContinuityParentCardAnchor(
    parentConversationId: parentConversationId,
    eventId: eventId,
    sequence: sequence,
    partId: partId,
  );
}

ContinuityTaskConversationRelation testRelation({
  required String goalId,
  required String childConversationId,
  required ContinuityParentCardAnchor cardAnchor,
  ContinuityGoalCompletionTransition? completionTransition,
  int revision = 1,
}) {
  return ContinuityTaskConversationRelation(
    goalId: goalId,
    parentConversationId: cardAnchor.parentConversationId,
    childConversationId: childConversationId,
    cardAnchor: cardAnchor,
    listingKind: ContinuityTaskListingKind.childTask,
    followThroughKind: ContinuityFollowThroughKind.durable,
    completionTransition: completionTransition,
    revision: revision,
    createdEvent: testSourceRef(
      opaqueId: cardAnchor.eventId,
      partId: cardAnchor.partId,
      sourceRevision: cardAnchor.sequence,
    ),
  );
}

ContinuityGoalProgress testProgress({
  required String goalId,
  ContinuityGoalLifecycle lifecycle = ContinuityGoalLifecycle.active,
  ContinuityGoalControl control = ContinuityGoalControl.enabled,
  ContinuityNextAttention? nextAttention,
  List<ContinuityEvidenceRef> evidence = const <ContinuityEvidenceRef>[],
  List<String> activeExecutionRefs = const <String>[],
  int revision = 1,
}) {
  return ContinuityGoalProgress(
    goalId: goalId,
    revision: revision,
    lifecycle: lifecycle,
    control: control,
    criterionEvidenceRefs: evidence,
    activeExecutionRefs: activeExecutionRefs,
    blockers: const <String>[],
    nextAttention: nextAttention,
  );
}

ContinuityMatter testMatter({required String id, required String label}) {
  return ContinuityMatter(
    id: id,
    conversationId: 'conversation:parent',
    revision: 1,
    label: label,
    associationRefs: <ContinuitySourceRef>[testSourceRef()],
    createdEvent: testSourceRef(),
    status: ContinuityMatterStatus.open,
  );
}

ContinuityGoalContract testContract({
  required String id,
  required String matterId,
  String expectedResult = 'Draft the notes',
  String responsibleRoleRef = 'membership:assistant',
}) {
  return ContinuityGoalContract(
    id: id,
    matterId: matterId,
    sourceIntentRefs: <ContinuitySourceRef>[testSourceRef()],
    contractRevision: 1,
    expectedResult: expectedResult,
    criteria: const <ContinuityCriterion>[],
    scopeRefs: const <ContinuitySourceRef>[],
    responsibleRoleRef: responsibleRoleRef,
    resourceEnvelopeRef: 'envelope:default',
    acceptanceMethod: 'user-acceptance',
    createdEvent: testSourceRef(),
  );
}

ContinuityWorkContext testWorkContext({
  required String conversationId,
  required String membershipId,
  required String matterId,
}) {
  return ContinuityWorkContext(
    conversationId: conversationId,
    membershipId: membershipId,
    matterId: matterId,
    generation: 1,
    privateBindingRef: 'binding:opaque',
    capabilitySnapshotRef: 'capability:opaque',
    sourceManifestRef: 'manifest:1',
    status: ContinuityWorkContextStatus.bound,
    lastReconciled: 10,
  );
}

ContinuityEvidenceRef testEvidence({
  required String opaqueId,
  required String issuer,
}) {
  return ContinuityEvidenceRef(
    source: testSourceRef(opaqueId: opaqueId),
    issuer: issuer,
    subjectVersion: 1,
    criterionId: 'criterion:draft',
    observedAt: 20,
    result: ContinuityEvidenceResult.pass,
    verificationKind: ContinuityVerificationKind.userAcceptance,
    scope: ContinuityVisibilityScope.goal,
    validity: ContinuitySourceValidity.current,
  );
}

ContinuityGoalCompletionTransition testCompletion({
  required String goalId,
  String notificationId = 'notice:goal:notes:achieved',
}) {
  return ContinuityGoalCompletionTransition(
    transitionId: 'transition:$goalId:achieved',
    goalId: goalId,
    fromLifecycle: ContinuityGoalLifecycle.verifying,
    toLifecycle: ContinuityGoalLifecycle.achieved,
    goalRevision: 3,
    authorityKind: ContinuityClosureAuthorityKind.goalEvaluation,
    evaluationRef: testSourceRef(opaqueId: goalId),
    notificationId: notificationId,
  );
}

ContinuousAssistantTaskView testTask({
  required String goalId,
  required String childConversationId,
  required int sequence,
  String eventId = '',
  String label = 'Release notes',
  ContinuityGoalLifecycle lifecycle = ContinuityGoalLifecycle.active,
  ContinuityGoalControl control = ContinuityGoalControl.enabled,
  ContinuityNextAttention? nextAttention,
  List<ContinuityWorkContext>? workContexts,
  List<ContinuityEvidenceRef> evidence = const <ContinuityEvidenceRef>[],
  ContinuityGoalCompletionTransition? completion,
  String? longLabel,
}) {
  final cardEvent = eventId.isEmpty ? 'event:$goalId' : eventId;
  final matterId = 'matter:$goalId';
  return ContinuousAssistantTaskView(
    relation: testRelation(
      goalId: goalId,
      childConversationId: childConversationId,
      cardAnchor: testCardAnchor(
        eventId: cardEvent,
        sequence: sequence,
        partId: 'part:$goalId',
      ),
      completionTransition: completion,
    ),
    progress: testProgress(
      goalId: goalId,
      lifecycle: lifecycle,
      control: control,
      nextAttention: nextAttention,
      evidence: evidence,
      activeExecutionRefs:
          nextAttention is ContinuityNextAttentionActiveExecution
          ? <String>[nextAttention.executionRef]
          : const <String>[],
    ),
    contract: testContract(id: goalId, matterId: matterId),
    matter: testMatter(id: matterId, label: longLabel ?? label),
    childWorkContexts:
        workContexts ??
        <ContinuityWorkContext>[
          testWorkContext(
            conversationId: childConversationId,
            membershipId: 'membership:worker',
            matterId: matterId,
          ),
          testWorkContext(
            conversationId: childConversationId,
            membershipId: 'membership:reviewer',
            matterId: matterId,
          ),
        ],
  );
}

Widget wrapContinuousAssistant(
  Widget child, {
  Size size = const Size(800, 720),
  bool disableAnimations = false,
  Locale locale = const Locale('en'),
}) {
  return MediaQuery(
    data: MediaQueryData(size: size, disableAnimations: disableAnimations),
    child: MaterialApp(
      locale: locale,
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      home: Scaffold(body: child),
    ),
  );
}

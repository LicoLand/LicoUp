import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

import 'support/continuous_assistant_test_harness.dart';

ContinuousAssistantTaskView _taskA({
  ContinuityGoalLifecycle lifecycle = ContinuityGoalLifecycle.active,
  ContinuityGoalControl control = ContinuityGoalControl.enabled,
  ContinuityNextAttention? nextAttention,
  List<ContinuityEvidenceRef> evidence = const <ContinuityEvidenceRef>[],
  ContinuityGoalCompletionTransition? completion,
}) {
  return testTask(
    goalId: 'goal:a',
    childConversationId: 'conversation:child-a',
    sequence: 4,
    eventId: 'event:card-a',
    label: 'Notes A',
    lifecycle: lifecycle,
    control: control,
    nextAttention:
        nextAttention ??
        const ContinuityNextAttentionActiveExecution(
          executionRef: 'dispatch:a',
        ),
    evidence: evidence,
    completion: completion,
  );
}

ContinuousAssistantTaskView _taskB({
  ContinuityGoalLifecycle lifecycle = ContinuityGoalLifecycle.active,
}) {
  return testTask(
    goalId: 'goal:b',
    childConversationId: 'conversation:child-b',
    sequence: 7,
    eventId: 'event:card-b',
    label: 'Discussion B',
    lifecycle: lifecycle,
    nextAttention: const ContinuityNextAttentionWait(
      triggerRef: 'wake:b',
      reviewPolicy: 'review-on-reply',
      responsibleParty: 'membership:user',
    ),
  );
}

void main() {
  test('sibling cards stay ordered by typed sequence, not completion', () {
    final reversed = <ContinuousAssistantTaskView>[
      _taskB(lifecycle: ContinuityGoalLifecycle.achieved),
      _taskA(),
    ];
    final ordered = orderContinuousAssistantTasksByCardSequence(reversed);
    expect(ordered.map((task) => task.relation.goalId), <String>[
      'goal:a',
      'goal:b',
    ]);
    expect(ordered.first.relation.cardAnchor.sequence, 4);
    expect(ordered.last.relation.cardAnchor.sequence, 7);
  });

  test('collapsed progress uses supplied attention, not a percentage', () {
    expect(
      continuousAssistantCollapsedProgress(
        testProgress(
          goalId: 'goal:a',
          nextAttention: const ContinuityNextAttentionActiveExecution(
            executionRef: 'dispatch:a',
          ),
        ),
      ),
      'dispatch:a',
    );
    expect(
      continuousAssistantCollapsedProgress(
        testProgress(
          goalId: 'goal:a',
          lifecycle: ContinuityGoalLifecycle.waiting,
          nextAttention: const ContinuityNextAttentionWait(
            triggerRef: 'wake:a',
            reviewPolicy: 'review-on-due',
            responsibleParty: 'membership:user',
          ),
        ),
      ),
      'review-on-due',
    );
    expect(
      continuousAssistantCollapsedProgress(
        testProgress(goalId: 'goal:a', control: ContinuityGoalControl.paused),
      ),
      ContinuityGoalControl.paused.wireName,
    );
    expect(
      continuousAssistantCollapsedProgress(testProgress(goalId: 'goal:a')),
      contains('active'),
    );
    expect(
      continuousAssistantCollapsedProgress(testProgress(goalId: 'goal:a')),
      isNot(contains('%')),
    );
  });

  testWidgets('main entry has composer and no mode ceremony', (tester) async {
    await tester.pumpWidget(
      wrapContinuousAssistant(const ContinuousAssistantProjection()),
    );
    expect(find.byKey(ContinuousAssistantKeys.composer), findsOneWidget);
    expect(find.text('Goal'), findsNothing);
    expect(find.text('Code'), findsNothing);
    expect(find.text('Knowledge'), findsNothing);
    expect(find.text('New session'), findsNothing);
    expect(find.text('Submit task'), findsNothing);
    expect(find.text('任务模式'), findsNothing);
    expect(find.byKey(ContinuousAssistantKeys.unavailable), findsNothing);
  });

  testWidgets('A stays A when B is focused and A later completes', (
    tester,
  ) async {
    final opened = <String>[];
    final commands = <ContinuousAssistantCommandIntent>[];
    final composerFocus = FocusNode();
    final composer = TextEditingController();
    addTearDown(composerFocus.dispose);
    addTearDown(composer.dispose);

    var tasks = <ContinuousAssistantTaskView>[_taskB(), _taskA()];
    Future<void> pump() async {
      await tester.pumpWidget(
        wrapContinuousAssistant(
          ContinuousAssistantProjection(
            tasks: tasks,
            composerFocusNode: composerFocus,
            composerController: composer,
            onOpenChild: (task) =>
                opened.add(task.relation.childConversationId),
            onCommand: commands.add,
          ),
        ),
      );
      await tester.pump();
    }

    await pump();
    await tester.tap(find.byKey(ContinuousAssistantKeys.composer));
    await tester.enterText(
      find.byKey(ContinuousAssistantKeys.composer),
      'continuing B',
    );
    await tester.pump();
    expect(composerFocus.hasFocus, isTrue);

    tasks = <ContinuousAssistantTaskView>[
      _taskB(),
      _taskA(
        lifecycle: ContinuityGoalLifecycle.achieved,
        nextAttention: null,
        evidence: <ContinuityEvidenceRef>[
          testEvidence(
            opaqueId: 'artifact:a-result',
            issuer: 'membership:worker',
          ),
        ],
        completion: testCompletion(
          goalId: 'goal:a',
          notificationId: 'notice:goal:a:achieved',
        ),
      ),
    ];
    await pump();

    expect(composerFocus.hasFocus, isTrue);
    expect(composer.text, 'continuing B');
    expect(commands, isEmpty);
    expect(find.byKey(ContinuousAssistantKeys.card('goal:a')), findsOneWidget);
    expect(find.byKey(ContinuousAssistantKeys.card('goal:b')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(ContinuousAssistantKeys.card('goal:a'))).dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(ContinuousAssistantKeys.card('goal:b')))
            .dy,
      ),
    );
    expect(
      find.byKey(ContinuousAssistantKeys.lifecycle('goal:a')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(find.byKey(ContinuousAssistantKeys.lifecycle('goal:a')))
          .data,
      ContinuityGoalLifecycle.achieved.wireName,
    );
    expect(
      tester
          .widget<Text>(find.byKey(ContinuousAssistantKeys.lifecycle('goal:b')))
          .data,
      ContinuityGoalLifecycle.active.wireName,
    );
    expect(find.text('%'), findsNothing);

    await tester.tap(find.byKey(ContinuousAssistantKeys.openCard('goal:a')));
    await tester.pump();
    await tester.tap(
      find.byKey(ContinuousAssistantKeys.child('conversation:child-a')),
    );
    await tester.pump();
    expect(opened, <String>['conversation:child-a', 'conversation:child-a']);
    expect(composerFocus.hasFocus, isTrue);
  });

  testWidgets(
    'B completing first does not reorder or append a replacement card',
    (tester) async {
      final commands = <ContinuousAssistantCommandIntent>[];
      var tasks = <ContinuousAssistantTaskView>[_taskA(), _taskB()];
      Future<void> pump() async {
        await tester.pumpWidget(
          wrapContinuousAssistant(
            ContinuousAssistantProjection(
              tasks: tasks,
              onCommand: commands.add,
            ),
          ),
        );
        await tester.pump();
      }

      await pump();
      tasks = <ContinuousAssistantTaskView>[
        _taskB(lifecycle: ContinuityGoalLifecycle.achieved),
        _taskA(),
      ];
      await pump();

      final cards = tester
          .widgetList<Widget>(
            find.descendant(
              of: find.byKey(ContinuousAssistantKeys.timeline),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget.key is ValueKey<String> &&
                    (widget.key! as ValueKey<String>).value.startsWith(
                      'continuous-assistant-card:',
                    ),
              ),
            ),
          )
          .map((widget) => (widget.key! as ValueKey<String>).value)
          .toList();
      expect(cards, <String>[
        'continuous-assistant-card:goal:a',
        'continuous-assistant-card:goal:b',
      ]);
      expect(
        find.byKey(ContinuousAssistantKeys.card('goal:a')),
        findsOneWidget,
      );
      expect(
        find.byKey(ContinuousAssistantKeys.card('goal:b')),
        findsOneWidget,
      );
      expect(commands, isEmpty);
    },
  );

  testWidgets('close and reopen restore projection without cancel', (
    tester,
  ) async {
    final commands = <ContinuousAssistantCommandIntent>[];
    final tasks = <ContinuousAssistantTaskView>[_taskA(), _taskB()];

    await tester.pumpWidget(
      wrapContinuousAssistant(
        ContinuousAssistantProjection(tasks: tasks, onCommand: commands.add),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(ContinuousAssistantKeys.lifecycle('goal:a')))
          .data,
      ContinuityGoalLifecycle.active.wireName,
    );

    await tester.pumpWidget(wrapContinuousAssistant(const SizedBox.shrink()));
    await tester.pump();
    expect(commands, isEmpty);

    await tester.pumpWidget(
      wrapContinuousAssistant(
        ContinuousAssistantProjection(tasks: tasks, onCommand: commands.add),
      ),
    );
    await tester.pump();
    expect(commands, isEmpty);
    expect(
      tester
          .widget<Text>(find.byKey(ContinuousAssistantKeys.lifecycle('goal:a')))
          .data,
      isNot(ContinuityGoalLifecycle.achieved.wireName),
    );
    expect(
      tester
          .widget<Text>(find.byKey(ContinuousAssistantKeys.lifecycle('goal:a')))
          .data,
      ContinuityGoalLifecycle.active.wireName,
    );
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets(
    'expand shows evidence, executor, responsible party, wait reason',
    (tester) async {
      final waiting = testTask(
        goalId: 'goal:wait',
        childConversationId: 'conversation:child-wait',
        sequence: 2,
        label: 'Waiting item',
        lifecycle: ContinuityGoalLifecycle.waiting,
        nextAttention: const ContinuityNextAttentionWait(
          triggerRef: 'wake:user',
          reviewPolicy: 'review-on-reply',
          responsibleParty: 'membership:user',
        ),
        evidence: <ContinuityEvidenceRef>[
          testEvidence(opaqueId: 'artifact:draft', issuer: 'membership:worker'),
        ],
      );
      await tester.pumpWidget(
        wrapContinuousAssistant(
          ContinuousAssistantProjection(
            tasks: <ContinuousAssistantTaskView>[waiting],
          ),
        ),
      );
      expect(
        find.byKey(ContinuousAssistantKeys.collapsed('goal:wait')),
        findsOneWidget,
      );
      expect(find.text('review-on-reply'), findsOneWidget);
      expect(
        find.byKey(
          ContinuousAssistantKeys.evidence('goal:wait', 'artifact:draft'),
        ),
        findsNothing,
      );

      await tester.tap(find.byKey(ContinuousAssistantKeys.expand('goal:wait')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(ContinuousAssistantKeys.collapsed('goal:wait')),
        findsNothing,
      );
      expect(
        find.byKey(
          ContinuousAssistantKeys.evidence('goal:wait', 'artifact:draft'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          ContinuousAssistantKeys.executor('goal:wait', 'membership:worker'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          ContinuousAssistantKeys.participant(
            'goal:wait',
            'membership:reviewer',
          ),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(ContinuousAssistantKeys.responsible('goal:wait')),
            )
            .data,
        'membership:user',
      );
      expect(
        find.byKey(ContinuousAssistantKeys.waitReason('goal:wait')),
        findsOneWidget,
      );
      expect(find.textContaining('wake:user'), findsOneWidget);
    },
  );

  testWidgets('correct pause cancel emit command intents only', (tester) async {
    final commands = <ContinuousAssistantCommandIntent>[];
    await tester.pumpWidget(
      wrapContinuousAssistant(
        ContinuousAssistantProjection(
          tasks: <ContinuousAssistantTaskView>[_taskA()],
          onCommand: commands.add,
        ),
      ),
    );
    await tester.tap(find.byKey(ContinuousAssistantKeys.expand('goal:a')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ContinuousAssistantKeys.correct('goal:a')));
    await tester.tap(find.byKey(ContinuousAssistantKeys.pause('goal:a')));
    await tester.tap(find.byKey(ContinuousAssistantKeys.cancel('goal:a')));
    await tester.pump();

    expect(
      commands.map((intent) => intent.command).toList(),
      <ContinuityCommand>[
        ContinuityCommand.correctAssociation,
        ContinuityCommand.pauseGoal,
        ContinuityCommand.requestCancel,
      ],
    );
    expect(commands.every((intent) => intent.goalId == 'goal:a'), isTrue);
    expect(
      tester
          .widget<Text>(find.byKey(ContinuousAssistantKeys.lifecycle('goal:a')))
          .data,
      ContinuityGoalLifecycle.active.wireName,
    );
  });

  testWidgets('paused card shows Resume and tap emits resumeGoal', (
    tester,
  ) async {
    final commands = <ContinuousAssistantCommandIntent>[];
    await tester.pumpWidget(
      wrapContinuousAssistant(
        ContinuousAssistantProjection(
          tasks: <ContinuousAssistantTaskView>[
            _taskA(control: ContinuityGoalControl.paused),
          ],
          onCommand: commands.add,
        ),
      ),
    );
    await tester.tap(find.byKey(ContinuousAssistantKeys.expand('goal:a')));
    await tester.pumpAndSettle();
    expect(find.byKey(ContinuousAssistantKeys.pause('goal:a')), findsNothing);
    expect(
      find.byKey(ContinuousAssistantKeys.resume('goal:a')),
      findsOneWidget,
    );
    expect(
      find.byKey(ContinuousAssistantKeys.cancel('goal:a')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(ContinuousAssistantKeys.resume('goal:a')));
    await tester.pump();
    expect(commands, hasLength(1));
    expect(commands.single.command, ContinuityCommand.resumeGoal);
    expect(commands.single.goalId, 'goal:a');
  });

  testWidgets('keyboard activates pause and respects reduced motion', (
    tester,
  ) async {
    final commands = <ContinuousAssistantCommandIntent>[];
    await tester.pumpWidget(
      wrapContinuousAssistant(
        ContinuousAssistantProjection(
          tasks: <ContinuousAssistantTaskView>[_taskA()],
          onCommand: commands.add,
        ),
        disableAnimations: true,
      ),
    );
    await tester.tap(find.byKey(ContinuousAssistantKeys.expand('goal:a')));
    await tester.pump();
    expect(find.byType(AnimatedSize), findsNothing);

    final pauseButton = find.descendant(
      of: find.byKey(ContinuousAssistantKeys.pause('goal:a')),
      matching: find.byType(TextButton),
    );
    expect(pauseButton, findsOneWidget);
    tester.widget<TextButton>(pauseButton).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(commands, isNotEmpty);
    expect(commands.single.command, ContinuityCommand.pauseGoal);
  });

  testWidgets('screen reader labels exist in English and Chinese', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        wrapContinuousAssistant(
          ContinuousAssistantProjection(
            tasks: <ContinuousAssistantTaskView>[_taskA()],
          ),
        ),
      );
      expect(
        tester.getSemantics(
          find.byKey(ContinuousAssistantKeys.expand('goal:a')),
        ),
        isSemantics(label: 'Expand matter', isButton: true),
      );

      await tester.pumpWidget(
        wrapContinuousAssistant(
          ContinuousAssistantProjection(
            tasks: <ContinuousAssistantTaskView>[_taskA()],
          ),
          locale: const Locale('zh'),
        ),
      );
      expect(
        tester.getSemantics(
          find.byKey(ContinuousAssistantKeys.expand('goal:a')),
        ),
        isSemantics(label: '展开事项', isButton: true),
      );
      expect(find.byKey(ContinuousAssistantKeys.composer), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('narrow window keeps a long title without overflow', (
    tester,
  ) async {
    final previousOnError = FlutterError.onError;
    addTearDown(() => FlutterError.onError = previousOnError);
    FlutterError.onError = (details) {
      if (details.toString().contains('overflowed')) {
        fail(details.toString());
      }
      FlutterError.presentError(details);
    };
    await tester.pumpWidget(
      wrapContinuousAssistant(
        ContinuousAssistantProjection(
          tasks: <ContinuousAssistantTaskView>[
            testTask(
              goalId: 'goal:long',
              childConversationId: 'conversation:child-long',
              sequence: 1,
              longLabel:
                  'This is an extremely long matter title that must remain inspectable in a narrow window without inventing a second summary',
            ),
          ],
        ),
        size: const Size(280, 720),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final title = tester.widget<Text>(
      find.byKey(ContinuousAssistantKeys.title('goal:long')),
    );
    expect(title.maxLines, 2);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(title.data, contains('extremely long matter title'));
  });

  testWidgets('completion notice renders typed facts and does not publish', (
    tester,
  ) async {
    var publishCount = 0;
    final transition = testCompletion(goalId: 'goal:a');
    final task = _taskA(
      lifecycle: ContinuityGoalLifecycle.achieved,
      nextAttention: null,
      completion: transition,
    );
    await tester.pumpWidget(
      wrapContinuousAssistant(
        Builder(
          builder: (context) {
            publishCount += 0;
            return ContinuousAssistantCompletionNotice(
              transition: transition,
              task: task,
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(publishCount, 0);
    expect(
      find.byKey(ContinuousAssistantKeys.notice(transition.notificationId)),
      findsOneWidget,
    );
    expect(find.text(transition.notificationId), findsOneWidget);
    expect(find.text(transition.toLifecycle.wireName), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(ContinuousAssistantProjection), findsNothing);
  });

  testWidgets(
    'legal fixtures drive the parent card without a string projection',
    (tester) async {
      final relation = ContinuityTaskConversationRelation.parse(
        readContinuityFixture(
          'legal/task-conversation-relation.json',
        )['payload'],
      );
      final progress = ContinuityGoalProgress.parse(
        readContinuityFixture('legal/goal-progress.json')['payload'],
      );
      final matter = ContinuityMatter.parse(
        readContinuityFixture('legal/matter.json')['payload'],
      );
      final contract = ContinuityGoalContract.parse(
        readContinuityFixture('legal/goal-contract.json')['payload'],
      );
      final work = ContinuityWorkContext.parse(
        readContinuityFixture('legal/work-context.json')['payload'],
      );
      await tester.pumpWidget(
        wrapContinuousAssistant(
          ContinuousAssistantProjection(
            tasks: <ContinuousAssistantTaskView>[
              ContinuousAssistantTaskView(
                relation: relation,
                progress: progress,
                matter: matter,
                contract: contract,
                childWorkContexts: <ContinuityWorkContext>[work],
              ),
            ],
          ),
        ),
      );
      expect(
        find.byKey(ContinuousAssistantKeys.card(relation.goalId)),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(ContinuousAssistantKeys.lifecycle(relation.goalId)),
            )
            .data,
        progress.lifecycle.wireName,
      );
      expect(
        find.text(
          '${relation.goalId}:${progress.lifecycle.wireName}:${progress.control.wireName}',
        ),
        findsNothing,
      );
      expect(find.text(matter.label), findsWidgets);
    },
  );

  testWidgets(
    'reduced-motion expand uses the shared motion scale when enabled',
    (tester) async {
      await tester.pumpWidget(
        wrapContinuousAssistant(
          ContinuousAssistantProjection(
            tasks: <ContinuousAssistantTaskView>[_taskA()],
          ),
        ),
      );
      final animated = tester.widget<AnimatedSize>(find.byType(AnimatedSize));
      expect(animated.duration, LicoMotion.medium);
    },
  );
}

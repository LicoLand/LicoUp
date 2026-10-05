import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/composition/features/projects/projects_feature_composition.dart';
import 'package:licoup/src/contracts/project_management.dart';
import 'package:licoup/src/contracts/project_plan_document.dart';
import 'package:licoup/src/frontend/projects/project_plan_submission.dart';
import 'package:licoup/src/frontend/projects/project_work_item_card.dart';
import 'package:licoup/src/frontend/projects/projects_canvas_panel.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import '../fixtures/project_surface_fixture.dart';

/// The caller-converted document one test surface may submit.
final class _ConvertedPlan implements ProjectPlanSubmission {
  const _ConvertedPlan(this.document);

  final ProjectPlanDocument document;

  @override
  ProjectPlanDocument? get convertedDocument => document;
}

/// One project surface over a recorded gateway, at a desktop size.
Widget _surface(
  ProjectsFeatureComposition composition, {
  ProjectPlanSubmission submission = const UnconvertedProjectPlan(),
}) => MaterialApp(
  theme: buildLicoTheme(platformBrightness: Brightness.dark),
  home: Scaffold(
    body: SizedBox(
      width: 1280,
      height: 800,
      child: ProjectsCanvasPanel(
        binding: composition.binding,
        submission: submission,
      ),
    ),
  ),
);

/// The reads a surface issues when it opens: the catalog and each project's
/// declared and unresolved inputs. None of them is an insertion.
bool _isRead(String call) =>
    call.startsWith('listProjects') ||
    call.startsWith('listDependencies') ||
    call.startsWith('listUnresolvedArtifacts') ||
    call.startsWith('listBlockedConsumers');

void main() {
  setUp(() {
    // A desktop-sized surface: the panel is a desktop region, and the default
    // 800x600 test viewport would clip the scoped controls column.
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 1000);
    view.devicePixelRatio = 1;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
  });

  testWidgets('the mounted surface states the incomplete-import rule', (
    tester,
  ) async {
    final composition = ProjectsFeatureComposition(twoProjectGateway());
    addTearDown(composition.dispose);

    await tester.pumpWidget(_surface(composition));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('project-import-disclosure')),
      findsOneWidget,
      reason: 'the canvas states the caller-converted document rule',
    );
    expect(find.text(ProjectImportDisclosure.conversionText), findsOneWidget);
    expect(
      find.text(ProjectImportDisclosure.noSourceReadingText),
      findsOneWidget,
    );
    expect(find.text(ProjectImportDisclosure.noProgressText), findsOneWidget);
    expect(
      find.byKey(const Key('project-no-converted-document')),
      findsOneWidget,
      reason: 'no converted document is reachable, so nothing is submitted',
    );
    expect(
      find.text(ProjectFactLabels.runtimeNotObserved),
      findsWidgets,
      reason:
          'the surface states that no run, completion or acceptance is read',
    );
  });

  testWidgets('opening the surface reads facts and starts no work', (
    tester,
  ) async {
    final gateway = twoProjectGateway();
    final composition = ProjectsFeatureComposition(gateway);
    addTearDown(composition.dispose);

    await tester.pumpWidget(_surface(composition));
    await tester.pumpAndSettle();

    expect(gateway.calls, isNotEmpty);
    expect(
      gateway.calls.where((call) => !_isRead(call)),
      isEmpty,
      reason: 'opening a project view reads and nothing else',
    );
    expect(projectCallsWithPrefix(gateway.calls, 'applyPlanImport'), 0);
    expect(projectCallsWithPrefix(gateway.calls, 'previewPlanImport'), 0);
    expect(gateway.submitted, isEmpty);
    expect(find.byKey(const Key('projects-canvas')), findsOneWidget);
    expect(find.byKey(const Key('project-canvas-node-docs')), findsOneWidget);
  });

  testWidgets('a drag moves the card locally and sends no command', (
    tester,
  ) async {
    final gateway = twoProjectGateway();
    final composition = ProjectsFeatureComposition(gateway);
    addTearDown(composition.dispose);
    await tester.pumpWidget(_surface(composition));
    await tester.pumpAndSettle();
    final factsBefore = composition.binding.projection.current;
    final mark = gateway.callCount;

    await tester.drag(
      find.byKey(const Key('project-canvas-node-docs')),
      const Offset(40, 24),
    );
    await tester.pumpAndSettle();

    expect(gateway.calls.sublist(mark), isEmpty);
    final placement = composition.binding.layout.current.placementOf(
      'alpha/docs',
    );
    expect(placement?.movedByUser, isTrue);
    expect(placement!.x, greaterThan(0));
    expect(placement.y, greaterThan(0));
    expect(
      placement.x,
      lessThanOrEqualTo(40),
      reason: 'the card follows the pointer, never past it',
    );
    expect(
      composition.binding.projection.current,
      same(factsBefore),
      reason: 'moving a card republishes no fact and marks nothing executed',
    );
    expect(projectCallsWithPrefix(gateway.calls, 'applyPlanImport'), 0);
    expect(gateway.submitted, isEmpty);
  });

  testWidgets('a view switch sends no command and keeps the same facts', (
    tester,
  ) async {
    final gateway = twoProjectGateway();
    final composition = ProjectsFeatureComposition(gateway);
    addTearDown(composition.dispose);
    await tester.pumpWidget(_surface(composition));
    await tester.pumpAndSettle();
    final factsBefore = composition.binding.projection.current;
    final mark = gateway.callCount;

    await tester.tap(find.byKey(const Key('projects-view-list')));
    await tester.pumpAndSettle();

    expect(gateway.calls.sublist(mark), isEmpty);
    expect(find.byKey(const Key('projects-list')), findsOneWidget);
    expect(find.byKey(const Key('projects-canvas')), findsNothing);
    expect(find.byKey(const Key('project-list-row-docs')), findsOneWidget);
    expect(composition.binding.projection.current, same(factsBefore));

    await tester.tap(find.byKey(const Key('projects-view-canvas')));
    await tester.pumpAndSettle();

    expect(gateway.calls.sublist(mark), isEmpty);
    expect(find.byKey(const Key('projects-canvas')), findsOneWidget);
    expect(composition.binding.projection.current, same(factsBefore));
  });

  testWidgets(
    'a change shows what it affects and acts only after confirmation',
    (tester) async {
      final gateway = twoProjectGateway(
        previewResult: projectImportChangeFacts(),
        applyResult: ProjectPlanImportOutcomeFacts(
          applied: true,
          change: projectImportChangeFacts(),
        ),
      );
      final composition = ProjectsFeatureComposition(gateway);
      addTearDown(composition.dispose);
      await tester.pumpWidget(
        _surface(
          composition,
          submission: _ConvertedPlan(projectPlanDocument()),
        ),
      );
      await tester.pumpAndSettle();

      // Nothing is inserted before a preview reported the change.
      expect(find.byKey(const Key('project-confirm-insert')), findsNothing);
      expect(
        find.byKey(const Key('project-insert-requires-preview')),
        findsOneWidget,
      );
      expect(projectCallsWithPrefix(gateway.calls, 'applyPlanImport'), 0);

      // Scope the controls to one work item and read what it really affects.
      await tester.tap(find.byKey(const Key('project-canvas-node-docs')));
      await tester.pumpAndSettle();
      final readAffected = find.byKey(
        const Key('project-stop-read-dependents-docs'),
      );
      await tester.ensureVisible(readAffected);
      await tester.pumpAndSettle();
      await tester.tap(readAffected);
      await tester.pumpAndSettle();
      expect(
        projectCallsWithPrefix(gateway.calls, 'listBlockedConsumers'),
        1,
        reason: 'one read of the affected consumers, and no more',
      );
      expect(
        find.byKey(const Key('project-stop-affected-docs')),
        findsOneWidget,
      );

      // The preview reports the change; it inserts nothing.
      final preview = find.byKey(const Key('project-preview-change'));
      await tester.ensureVisible(preview);
      await tester.pumpAndSettle();
      await tester.tap(preview);
      await tester.pumpAndSettle();
      expect(projectCallsWithPrefix(gateway.calls, 'previewPlanImport'), 1);
      expect(projectCallsWithPrefix(gateway.calls, 'applyPlanImport'), 0);
      expect(
        find.byKey(const Key('project-change-confirmation')),
        findsOneWidget,
        reason: 'the previewed change is shown before anything is inserted',
      );
      expect(
        find.byKey(const Key('project-change-affected-docs')),
        findsOneWidget,
        reason: 'the confirmation shows the work this change affects',
      );
      expect(find.textContaining('alpha/release'), findsWidgets);
      expect(find.textContaining('revision 3'), findsWidgets);

      // The confirmation inserts the exact previewed revision, once.
      final insert = find.byKey(const Key('project-confirm-insert'));
      await tester.ensureVisible(insert);
      await tester.pumpAndSettle();
      await tester.tap(insert);
      await tester.pumpAndSettle();
      expect(projectCallsWithPrefix(gateway.calls, 'applyPlanImport'), 1);
      expect(gateway.calls, contains('applyPlanImport:alpha@3'));
      expect(projectCallsWithPrefix(gateway.calls, 'previewPlanImport'), 1);
    },
  );

  testWidgets('an action on the second project never names the first', (
    tester,
  ) async {
    final gateway = twoProjectGateway();
    final composition = ProjectsFeatureComposition(gateway);
    addTearDown(composition.dispose);
    await tester.pumpWidget(_surface(composition));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('project-canvas-node-docs')), findsOneWidget);

    // Selecting the other project is local: it sends no command and switches
    // which facts the surface presents.
    final selectionMark = gateway.callCount;
    await tester.tap(find.byKey(const Key('projects-project-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('projects-project-beta')).last);
    await tester.pumpAndSettle();

    expect(gateway.calls.sublist(selectionMark), isEmpty);
    expect(find.byKey(const Key('project-canvas-node-report')), findsOneWidget);
    expect(find.byKey(const Key('project-canvas-node-docs')), findsNothing);

    // The scoped read names beta's work item and nothing else.
    await tester.tap(find.byKey(const Key('project-canvas-node-report')));
    await tester.pumpAndSettle();
    final readAffected = find.byKey(
      const Key('project-stop-read-dependents-report'),
    );
    await tester.ensureVisible(readAffected);
    await tester.pumpAndSettle();
    final actionMark = gateway.callCount;
    await tester.tap(readAffected);
    await tester.pumpAndSettle();

    expect(gateway.calls.sublist(actionMark), const <String>[
      'listBlockedConsumers:beta/report',
    ]);
  });

  testWidgets('stop and handoff are stated, never offered', (tester) async {
    final gateway = twoProjectGateway();
    final composition = ProjectsFeatureComposition(gateway);
    addTearDown(composition.dispose);
    await tester.pumpWidget(_surface(composition));
    await tester.pumpAndSettle();
    final mark = gateway.callCount;

    expect(find.byKey(const Key('project-stop-unavailable')), findsOneWidget);
    expect(
      find.byKey(const Key('project-handoff-unavailable')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('project-stop-confirm')), findsNothing);
    expect(find.byKey(const Key('project-handoff-confirm')), findsNothing);
    expect(gateway.calls.sublist(mark), isEmpty);
  });

  testWidgets('an unbound client states the absence, not an empty catalog', (
    tester,
  ) async {
    final composition = ProjectsFeatureComposition(
      const UnboundProjectManagementGateway(),
    );
    addTearDown(composition.dispose);

    await tester.pumpWidget(_surface(composition));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(unboundProjectManagementCode),
      findsWidgets,
      reason: 'the surface reports the unbound owner instead of no projects',
    );
    expect(find.text(ProjectImportDisclosure.conversionText), findsNothing);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_test/flutter_test.dart';

import './workbench_desktop_test_harness.dart';

void main() {
  testWidgets('medium and expanded variants honor desktop constraints', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final size in const [Size(900, 720), Size(1280, 800)]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      final environment = workbenchDesktopEnvironment(
        width: size.width,
        height: size.height,
      );
      final counter = DestinationBuildCounter();

      await tester.pumpWidget(
        WorkbenchDesktopShellHarness(
          environment: environment,
          destination: CountingDestination(
            counter: counter,
            label: environment.viewport.name,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          ValueKey<String>(
            'workbench-desktop-${environment.viewport.name}-shell',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('workbench-desktop-command-region')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('workbench-desktop-workspace-surface'),
        ),
        findsOneWidget,
      );
      expect(counter.builds, 1);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('semantic navigation supports keyboard and pointer activation', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final selected = <ClientSection>[];
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      WorkbenchDesktopShellHarness(
        environment: workbenchDesktopEnvironment(width: 1100),
        activeDestination: ClientSection.agents,
        destination: const SizedBox(),
        onSelectDestination: selected.add,
      ),
    );
    await tester.pumpAndSettle();

    final agents = find.byKey(
      const ValueKey<String>('workbench-desktop-nav-agents'),
    );
    final agentsSemantics = tester.getSemantics(agents);
    expect(
      agentsSemantics,
      isSemantics(
        label: 'agents',
        isButton: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
    expect(find.byIcon(Icons.keyboard_command_key_rounded), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selected, [ClientSection.controlPanel]);

    selected.clear();
    final settings = find.byKey(
      const ValueKey<String>('workbench-desktop-nav-settings'),
    );
    await tester.ensureVisible(settings);
    await tester.pumpAndSettle();
    await tester.tap(settings);
    await tester.pump();
    expect(selected, [ClientSection.settings]);
    semantics.dispose();
  });

  testWidgets('large text remains bounded and reduced motion is immediate', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 820);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final environment = workbenchDesktopEnvironment(
      width: 900,
      height: 820,
      textScale: 2.4,
      reducedMotion: true,
    );

    await tester.pumpWidget(
      WorkbenchDesktopShellHarness(
        environment: environment,
        destination: const Center(child: Text('Scaled destination')),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Lico Arc'), findsNothing);
    expect(
      tester.widgetList<AnimatedPadding>(find.byType(AnimatedPadding)),
      everyElement(
        isA<AnimatedPadding>().having(
          (widget) => widget.duration,
          'duration',
          Duration.zero,
        ),
      ),
    );
  });

  testWidgets('appearance palette composes into accessible selected chrome', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xff7257d9),
          brightness: Brightness.dark,
        ).copyWith(
          primaryContainer: const Color(0xff1b1038),
          onPrimaryContainer: const Color(0xffffffff),
        );

    await tester.pumpWidget(
      WorkbenchDesktopShellHarness(
        environment: workbenchDesktopEnvironment(width: 1100),
        activeDestination: ClientSection.agents,
        destination: const SizedBox(),
        colorScheme: scheme,
      ),
    );
    await tester.pumpAndSettle();

    final selectedNavigation = find.byKey(
      const ValueKey<String>('workbench-desktop-nav-agents'),
    );
    final selectedMaterial = tester
        .widgetList<Material>(
          find.descendant(
            of: selectedNavigation,
            matching: find.byType(Material),
          ),
        )
        .first;
    final selectedLabel = tester.widget<Text>(
      find.descendant(of: selectedNavigation, matching: find.text('agents')),
    );

    expect(selectedMaterial.color, scheme.primaryContainer);
    expect(selectedLabel.style?.color, scheme.onPrimaryContainer);
    expect(
      _contrastRatio(scheme.primaryContainer, scheme.onPrimaryContainer),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets('shell constructs only the destination passed by its host', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final counter = DestinationBuildCounter();

    await tester.pumpWidget(
      WorkbenchDesktopShellHarness(
        environment: workbenchDesktopEnvironment(width: 900),
        destination: CountingDestination(
          counter: counter,
          label: 'Only active destination',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(counter.builds, 1);
    expect(find.byKey(const Key('passed-destination')), findsOneWidget);
  });
}

double _contrastRatio(Color first, Color second) {
  final lighter = first.computeLuminance() > second.computeLuminance()
      ? first
      : second;
  final darker = identical(lighter, first) ? second : first;
  return (lighter.computeLuminance() + 0.05) /
      (darker.computeLuminance() + 0.05);
}

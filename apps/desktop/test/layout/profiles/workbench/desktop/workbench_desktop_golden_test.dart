import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/workbench_desktop.dart';
import 'package:flutter_test/flutter_test.dart';

import './workbench_desktop_test_harness.dart';

void main() {
  testWidgets('preview is deterministic', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(640, 400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff6650a4)),
          useMaterial3: true,
        ),
        home: Center(
          child: SizedBox(
            width: 512,
            height: 320,
            child: Builder(builder: workbenchDesktopBundle.previewBuilder),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const ValueKey<String>('workbench-desktop-preview')),
      matchesGoldenFile(
        '../../../../goldens/layout/workbench/desktop/preview.png',
      ),
    );
  });

  testWidgets('medium shell has a stable workbench composition', (
    tester,
  ) async {
    await _expectShellGolden(
      tester,
      size: const Size(900, 720),
      fileName: 'medium-shell.png',
    );
  });

  testWidgets('expanded shell has a stable workbench composition', (
    tester,
  ) async {
    await _expectShellGolden(
      tester,
      size: const Size(1280, 800),
      fileName: 'expanded-shell.png',
    );
  });
}

Future<void> _expectShellGolden(
  WidgetTester tester, {
  required Size size,
  required String fileName,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    WorkbenchDesktopShellHarness(
      environment: workbenchDesktopEnvironment(
        width: size.width,
        height: size.height,
      ),
      destination: const _GoldenDestination(),
    ),
  );
  await tester.pumpAndSettle();

  await expectLater(
    find.byKey(const ValueKey<String>('workbench-desktop-topbar-shell')),
    matchesGoldenFile('../../../../goldens/layout/workbench/desktop/$fileName'),
  );
}

final class _GoldenDestination extends StatelessWidget {
  const _GoldenDestination();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: _GoldenCard(
                color: colors.surfaceContainer,
                icon: Icons.auto_awesome_rounded,
                title: 'Active work',
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              flex: 2,
              child: Column(
                children: [
                  Expanded(
                    child: _GoldenCard(
                      color: colors.primaryContainer,
                      icon: Icons.bolt_rounded,
                      title: 'Quick actions',
                    ),
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: _GoldenCard(
                      color: colors.secondaryContainer,
                      icon: Icons.schedule_rounded,
                      title: 'Recent activity',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _GoldenCard extends StatelessWidget {
  const _GoldenCard({
    required this.color,
    required this.icon,
    required this.title,
  });

  final Color color;
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 26),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shell/layout_palette_projection.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_folder_sidebar.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('folder sidebar lists every destination with the house rule', (
    tester,
  ) async {
    await tester.pumpWidget(
      _sidebarTestApp(section: ClientSection.agents, onSelectSection: (_) {}),
    );
    await tester.pump();

    for (final section in ClientSection.values) {
      expect(
        find.byKey(Key('dashboard-folder-nav-${section.name}')),
        findsOneWidget,
        reason: '${section.name} keeps a folder row',
      );
    }

    final colors = tester
        .element(find.byKey(const Key('dashboard-folder-sidebar')))
        .licoColors;
    Color? rowColor(ClientSection section) {
      final container = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byKey(Key('dashboard-folder-nav-${section.name}')),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      return (container.decoration as BoxDecoration?)?.color;
    }

    expect(rowColor(ClientSection.agents), colors.primary);
    expect(rowColor(ClientSection.settings), isNot(colors.primary));
    final selectedIcon = tester.widget<Icon>(
      find
          .descendant(
            of: find.byKey(const Key('dashboard-folder-nav-agents')),
            matching: find.byType(Icon),
          )
          .first,
    );
    expect(selectedIcon.color, colors.textOnPrimary);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder rows fire the destination selection callback', (
    tester,
  ) async {
    final selected = <ClientSection>[];
    await tester.pumpWidget(
      _sidebarTestApp(
        section: ClientSection.agents,
        onSelectSection: selected.add,
      ),
    );
    await tester.pump();

    final navSections = [for (final section in ClientSection.values) section];
    for (final section in navSections) {
      await tester.tap(find.byKey(Key('dashboard-folder-nav-${section.name}')));
      await tester.pump();
    }
    expect(selected, navSections);
    expect(tester.takeException(), isNull);
  });

  testWidgets('global search stays reachable at the sidebar top', (
    tester,
  ) async {
    await tester.pumpWidget(
      _sidebarTestApp(section: ClientSection.agents, onSelectSection: (_) {}),
    );
    await tester.pump();

    expect(find.byKey(const Key('shell-global-search')), findsOneWidget);
    expect(
      find.byKey(
        const Key('dashboard-folder-sidebar-traffic-light-reservation'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _sidebarTestApp({
  required ClientSection section,
  required ValueChanged<ClientSection> onSelectSection,
}) {
  final theme = buildLicoTheme(
    platformBrightness: Brightness.dark,
  ).copyWith(platform: TargetPlatform.macOS);
  return MaterialApp(
    locale: const Locale('en'),
    supportedLocales: LicoStrings.supportedLocales,
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    theme: theme,
    home: Builder(
      builder: (context) {
        final colors = context.licoColors;
        return LayoutPaletteScope(
          palette: layoutPaletteFromColors(colors),
          child: Scaffold(
            body: DashboardFolderSidebar(
              section: section,
              onSelectSection: onSelectSection,
              width: 216,
            ),
          ),
        );
      },
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';

void main() {
  testWidgets('scope exposes strategies without a profile identity', (
    tester,
  ) async {
    const agents = _AgentsPresentation();
    const settings = _SettingsPresentation();
    LayoutAgentsPresentation? foundAgents;
    LayoutSettingsPresentation? foundSettings;

    await tester.pumpWidget(
      LayoutDestinationPresentationScope(
        agents: agents,
        settings: settings,
        child: Builder(
          builder: (context) {
            foundAgents = LayoutDestinationPresentationScope.agentsOf(context);
            foundSettings = LayoutDestinationPresentationScope.settingsOf(
              context,
            );
            return const SizedBox();
          },
        ),
      ),
    );

    expect(foundAgents, same(agents));
    expect(foundSettings, same(settings));
  });

  testWidgets('missing destination strategies fail closed', (tester) async {
    Object? agentsError;
    Object? settingsError;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          try {
            LayoutDestinationPresentationScope.agentsOf(context);
          } catch (value) {
            agentsError = value;
          }
          try {
            LayoutDestinationPresentationScope.settingsOf(context);
          } catch (value) {
            settingsError = value;
          }
          return const SizedBox();
        },
      ),
    );

    expect(agentsError, isA<StateError>());
    expect(settingsError, isA<StateError>());
  });
}

final class _AgentsPresentation implements LayoutAgentsPresentation {
  const _AgentsPresentation();

  @override
  Color canvasColor(LayoutPalette palette) => palette.background;

  @override
  EdgeInsetsGeometry get collapsedSidebarControlPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get expandedSidebarControlPadding => EdgeInsets.zero;

  @override
  double get detailOuterHorizontalExtent => 0;

  @override
  bool get showCollapsedSidebarControl => false;

  @override
  bool get showConversationSidebarControl => true;

  @override
  bool get showExpandedSidebarControl => false;

  @override
  double get sidebarOuterHorizontalExtent => 0;

  @override
  Widget frameDetail(
    BuildContext context, {
    required Key key,
    required bool sidebarCollapsed,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget frameWorkspace(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget frameSidebar(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);
}

final class _SettingsPresentation implements LayoutSettingsPresentation {
  const _SettingsPresentation();

  @override
  bool get indexHostedByNavigation => false;

  @override
  EdgeInsetsGeometry get contentPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get indexPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get rowPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get sectionHeaderPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get selectorGridPadding => EdgeInsets.zero;

  @override
  Widget frameIndex(
    BuildContext context, {
    required bool hovered,
    required Widget child,
  }) => child;

  @override
  Widget frameSection(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget frameSelector(BuildContext context, {required Widget child}) => child;
}

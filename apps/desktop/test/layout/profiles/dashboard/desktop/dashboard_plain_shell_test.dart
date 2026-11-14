import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_card_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_plain_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/client_platform_ports.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_traffic_light_anchor.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_navigation.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_self_avatar.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_ambient_layer.dart';
import 'package:licoup/src/frontend/shared/ui/lico_selection_highlight.dart';
import 'package:licoup/src/frontend/shared/ui/lico_window_drag_region.dart';

import '../../../fixtures/layout_chrome_features_fixture.dart';
import '../../../fixtures/production_client_shell_fixture.dart';
import 'dashboard_desktop_test_harness.dart';

void main() {
  final style = BuiltInLayoutSpec.dashboardPlainStyleId;

  Future<void> pumpPlainShell(
    WidgetTester tester, {
    required ClientSection activeDestination,
    required DashboardDesktopHarness harness,
    LayoutDestinationContentPort? content,
    FixtureLayoutChromeFeatures? chromeFeatures,
    double width = 1280,
    double height = 700,
    Brightness brightness = Brightness.dark,
  }) async {
    configureDashboardTestView(tester, Size(width, height));
    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: width, height: height),
        activeDestination: activeDestination,
        content: content ?? DashboardDesktopFixtureContent(harness),
        harness: harness,
        chromeFeatures: chromeFeatures,
        style: style,
        brightness: brightness,
      ),
    );
    await tester.pump();
  }

  testWidgets('the rail top strip is the single 72x52 anchor reporter', (
    tester,
  ) async {
    final harness = DashboardDesktopHarness();
    await pumpPlainShell(
      tester,
      activeDestination: ClientSection.agentHub,
      harness: harness,
    );

    // No window-wide band: the detail runs to the window's top edge.
    expect(find.byKey(const Key('dashboard-plain-band')), findsNothing);
    expect(find.byKey(const Key('dashboard-plain-band-title')), findsNothing);

    final strip = find.byKey(const Key('dashboard-plain-light-strip'));
    expect(strip, findsOneWidget);
    expect(tester.getSize(strip), const Size(72, 52));
    expect(tester.getTopLeft(strip), Offset.zero);

    final anchors = find.byType(MessagingTrafficLightAnchor);
    expect(anchors, findsOneWidget);
    expect(
      tester.getSize(anchors),
      const Size(
        DashboardPlainMetrics.railExtent,
        MessagingDesktopMetrics.sidebarTopRowExtent,
      ),
    );
  });

  testWidgets('the list column first row is the 52px search row', (
    tester,
  ) async {
    final harness = DashboardDesktopHarness();
    await pumpPlainShell(
      tester,
      activeDestination: ClientSection.monitoring,
      harness: harness,
    );

    final row = find.byKey(const Key('messaging-sidebar-search-row'));
    expect(row, findsOneWidget);
    expect(
      tester.getSize(row).height,
      MessagingDesktopMetrics.sidebarTopRowExtent,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.byKey(const Key('messaging-sidebar-search')),
      ),
      findsOneWidget,
    );
    // Flat style: no column title anywhere under the list column.
    expect(find.byKey(const Key('messaging-sidebar-title')), findsNothing);
  });

  testWidgets('the search icon centres on the traffic-light line', (
    tester,
  ) async {
    // Features and Settings: the icon's vertical centre equals the
    // 52 px strip's midpoint — window y == 26.
    final harness = DashboardDesktopHarness();
    for (final destination in [
      ClientSection.monitoring,
      ClientSection.settings,
    ]) {
      await pumpPlainShell(
        tester,
        activeDestination: destination,
        harness: harness,
      );
      final centre = tester
          .getCenter(find.byKey(const Key('messaging-sidebar-search')))
          .dy;
      expect(
        centre,
        moreOrLessEquals(
          MessagingDesktopMetrics.sidebarTopRowExtent / 2,
          epsilon: 0.5,
        ),
        reason: '${destination.name} search icon must centre on the lights',
      );
    }
    // Messages: search and the compose action share the same centre line.
    final fixture = await ProductionClientShellFixture.create(
      profileId: BuiltInLayoutSpec.dashboard.id,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      size: const Size(1280, 800),
      brightness: Brightness.dark,
      layoutStyleId: style,
    );
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      fixture.buildApp(
        semanticsKey: const Key('plain-centre-semantics'),
        repaintBoundaryKey: const Key('plain-centre-repaint'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      tester.getCenter(find.byKey(const Key('messaging-sidebar-search'))).dy,
      moreOrLessEquals(
        MessagingDesktopMetrics.sidebarTopRowExtent / 2,
        epsilon: 0.5,
      ),
    );
    expect(
      tester
          .getCenter(find.byKey(const Key('messaging-create-conversation')))
          .dy,
      moreOrLessEquals(
        MessagingDesktopMetrics.sidebarTopRowExtent / 2,
        epsilon: 0.5,
      ),
    );
  });

  testWidgets('the Messages list column keeps compose beside the search row', (
    tester,
  ) async {
    final fixture = await ProductionClientShellFixture.create(
      profileId: BuiltInLayoutSpec.dashboard.id,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      size: const Size(1280, 800),
      brightness: Brightness.dark,
      layoutStyleId: style,
    );
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      fixture.buildApp(
        semanticsKey: const Key('plain-shell-semantics'),
        repaintBoundaryKey: const Key('plain-shell-repaint'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    final row = find.byKey(const Key('messaging-sidebar-search-row'));
    expect(row, findsOneWidget);
    expect(
      tester.getSize(row).height,
      MessagingDesktopMetrics.sidebarTopRowExtent,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.byKey(const Key('messaging-sidebar-search')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.byKey(const Key('messaging-create-conversation')),
      ),
      findsOneWidget,
    );
    // The filter chips follow the search row, then the list.
    expect(find.byKey(const Key('messaging-sidebar-filters')), findsOneWidget);
  });

  testWidgets('rail shows the avatar, the three sections and bottom settings', (
    tester,
  ) async {
    final harness = DashboardDesktopHarness();
    await pumpPlainShell(
      tester,
      activeDestination: ClientSection.agentHub,
      harness: harness,
    );

    expect(find.byKey(const Key('dashboard-plain-shell')), findsOne);
    expect(find.byKey(const Key('dashboard-rail')), findsOneWidget);
    expect(find.byKey(const Key('dashboard-rail-self')), findsOneWidget);
    for (final item in <String>['messages', 'agents', 'features', 'settings']) {
      expect(
        find.byKey(Key('dashboard-rail-$item')),
        findsOneWidget,
        reason: 'missing rail entry $item',
      );
    }

    // The rail is the 72px strip on the window's left edge.
    final railWidth = tester.getSize(find.byKey(const Key('dashboard-rail')));
    expect(railWidth.width, DashboardPlainMetrics.railExtent);
    expect(railWidth.width, 72);

    // Avatar sits above Messages; Settings is pinned to the bottom.
    final avatarTop = tester
        .getTopLeft(find.byKey(const Key('dashboard-rail-self')))
        .dy;
    final messagesTop = tester
        .getTopLeft(find.byKey(const Key('dashboard-rail-messages')))
        .dy;
    final featuresTop = tester
        .getTopLeft(find.byKey(const Key('dashboard-rail-features')))
        .dy;
    final settingsTop = tester
        .getTopLeft(find.byKey(const Key('dashboard-rail-settings')))
        .dy;
    expect(avatarTop, lessThan(messagesTop));
    expect(messagesTop, lessThan(featuresTop));
    expect(settingsTop, greaterThan(featuresTop));
    final settingsBottom = tester.getBottomRight(
      find.byKey(const Key('dashboard-rail-settings')),
    );
    expect(settingsBottom.dy, greaterThan(700 - 80));
  });

  testWidgets('dark plain marks the rail selection at the window edge', (
    tester,
  ) async {
    final harness = DashboardDesktopHarness();
    await pumpPlainShell(
      tester,
      activeDestination: ClientSection.settings,
      harness: harness,
    );

    // Starlight: a small light sits at the rail's window edge, centred on
    // the selected button — never the lamp's rounded card behind the icon.
    final indicators = find.byKey(const Key('dashboard-rail-indicator'));
    expect(indicators, findsWidgets);
    final railLeft = tester
        .getTopLeft(find.byKey(const Key('dashboard-rail')))
        .dx;
    for (final indicator in indicators.evaluate()) {
      expect(tester.getTopLeft(find.byWidget(indicator.widget)).dx, railLeft);
    }
    final selectedIndicator = find.descendant(
      of: find.byKey(const Key('dashboard-rail-settings')),
      matching: indicators,
    );
    expect(
      tester.getCenter(selectedIndicator).dy,
      moreOrLessEquals(
        tester.getCenter(find.byKey(const Key('dashboard-rail-settings'))).dy,
        epsilon: 0.5,
      ),
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('dashboard-rail')),
        matching: find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is LicoSelectionHighlightPainter,
        ),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('light plain keeps the lamp rail selection', (tester) async {
    final harness = DashboardDesktopHarness();
    await pumpPlainShell(
      tester,
      activeDestination: ClientSection.settings,
      harness: harness,
      brightness: Brightness.light,
    );

    expect(find.byKey(const Key('dashboard-rail-indicator')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('dashboard-rail-settings')),
        matching: find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is LicoSelectionHighlightPainter,
        ),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('rail routes every entry to its destination', (tester) async {
    final harness = DashboardDesktopHarness();
    await pumpPlainShell(
      tester,
      activeDestination: ClientSection.agents,
      harness: harness,
    );

    await tester.tap(find.byKey(const Key('dashboard-rail-agents')));
    await tester.pump();
    expect(harness.selections, [ClientSection.agentHub]);

    // From a non-feature destination the Features entry lands on its first
    // hosted section rather than Agent Hub, which has its own rail entry.
    await tester.tap(find.byKey(const Key('dashboard-rail-features')));
    await tester.pump();
    expect(harness.selections.last, ClientSection.models);

    await tester.tap(find.byKey(const Key('dashboard-rail-messages')));
    await tester.pump();
    expect(harness.selections.last, ClientSection.agents);

    await tester.tap(find.byKey(const Key('dashboard-rail-settings')));
    await tester.pump();
    expect(harness.selections.last, ClientSection.settings);
  });

  testWidgets('rail Features keeps the current hosted feature destination', (
    tester,
  ) async {
    final harness = DashboardDesktopHarness();
    await pumpPlainShell(
      tester,
      activeDestination: ClientSection.monitoring,
      harness: harness,
    );

    await tester.tap(find.byKey(const Key('dashboard-rail-features')));
    await tester.pump();
    expect(harness.selections, [ClientSection.monitoring]);
  });

  testWidgets('rail badges Messages with the pending collaboration decisions', (
    tester,
  ) async {
    final harness = DashboardDesktopHarness();
    await pumpPlainShell(
      tester,
      activeDestination: ClientSection.agents,
      harness: harness,
      chromeFeatures: FixtureLayoutChromeFeatures(
        collaboration: const LayoutCollaborationAppState(pendingDecisions: 3),
      ),
    );

    final badge = find.byKey(const Key('dashboard-rail-badge'));
    expect(badge, findsOneWidget);
    expect(find.descendant(of: badge, matching: find.text('3')), findsOne);
  });

  testWidgets('avatar opens the floating self card to the avatar right', (
    tester,
  ) async {
    final harness = DashboardDesktopHarness();
    await pumpPlainShell(
      tester,
      activeDestination: ClientSection.agentHub,
      harness: harness,
    );

    expect(find.byKey(const Key('member-profile-card-self')), findsNothing);
    await tester.tap(find.byKey(const Key('dashboard-rail-self')));
    // The dark detail's ambient animates continuously — settle the card's
    // open with bounded pumps instead of pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final card = find.byKey(const Key('member-profile-card-self'));
    expect(card, findsOneWidget);
    expect(find.text('Local User'), findsOneWidget);
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Edit profile'), findsOneWidget);
    // The card hugs the avatar's right edge like the demo's mountPop.
    expect(
      tester.getTopLeft(card).dx,
      greaterThanOrEqualTo(
        tester.getTopRight(find.byKey(const Key('dashboard-rail-self'))).dx,
      ),
    );

    // The workspace stays mounted beneath the popover — no page swap, no
    // destination selection.
    expect(
      find.byKey(const Key('dashboard-fake-content-agentHub')),
      findsOneWidget,
    );
    expect(harness.selections, isEmpty);

    // Barrier dismiss closes the card; rail entries still navigate.
    await tester.tapAt(const Offset(640, 350));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(card, findsNothing);
    await tester.tap(find.byKey(const Key('dashboard-rail-messages')));
    await tester.pump();
    expect(harness.selections, [ClientSection.agents]);
  });

  testWidgets(
    'a feature destination shows the search-row list column and detail',
    (tester) async {
      final harness = DashboardDesktopHarness();
      await pumpPlainShell(
        tester,
        activeDestination: ClientSection.monitoring,
        harness: harness,
      );

      expect(find.byKey(const Key('dashboard-plain-sidebar')), findsOneWidget);
      // Flat style: the column's first row is the centred search row —
      // no title text anywhere.
      expect(find.byKey(const Key('messaging-sidebar-title')), findsNothing);
      expect(
        find.byKey(const Key('messaging-sidebar-search-row')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('messaging-sidebar-search')), findsOneWidget);
      expect(
        find.byKey(const Key('messaging-sidebar-feature-list')),
        findsOneWidget,
      );
      // The rail owns navigation: no bottom tabs, no traffic light row in
      // the list column.
      expect(
        find.byKey(const Key('messaging-sidebar-bottom-nav')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('messaging-sidebar-traffic-light-row')),
        findsNothing,
      );
      // Agent Hub has its own rail entry, so the list hides it.
      expect(
        find.byKey(const Key('messaging-sidebar-list-agentHub')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('messaging-sidebar-list-statsPanel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('dashboard-fake-content-monitoring')),
        findsOneWidget,
      );
    },
  );

  testWidgets('the list column selects a feature destination', (tester) async {
    final harness = DashboardDesktopHarness();
    await pumpPlainShell(
      tester,
      activeDestination: ClientSection.monitoring,
      harness: harness,
    );

    await tester.tap(
      find.byKey(const Key('messaging-sidebar-list-modelGateway')),
    );
    await tester.pump();
    expect(harness.selections, [ClientSection.models]);
  });

  testWidgets('Agent Hub renders one main view without the shell list column', (
    tester,
  ) async {
    final harness = DashboardDesktopHarness();
    await pumpPlainShell(
      tester,
      activeDestination: ClientSection.agentHub,
      harness: harness,
    );

    expect(find.byKey(const Key('dashboard-plain-sidebar')), findsNothing);
    expect(
      find.byKey(const Key('dashboard-fake-content-agentHub')),
      findsOneWidget,
    );
  });

  testWidgets('the rail avatar aligns with the first list band', (
    tester,
  ) async {
    final harness = DashboardDesktopHarness();
    for (final destination in [
      ClientSection.monitoring,
      ClientSection.settings,
    ]) {
      await pumpPlainShell(
        tester,
        activeDestination: destination,
        harness: harness,
      );
      final avatar = tester.getRect(
        find.byKey(const Key('dashboard-rail-self')),
      );
      // The avatar's visible artwork fills the whole 44 box — the hover
      // ring paints outside it — so it matches the row's height exactly.
      final artwork = tester.getRect(
        find.descendant(
          of: find.byKey(const Key('dashboard-rail-self')),
          matching: find.byType(MessagingSelfAvatar),
        ),
      );
      final firstRow = tester.getRect(
        find.byType(MessagingSidebarIndexRow).first,
      );
      // One compact gap under the top strip; the avatar footprint and the
      // first index row's painted surface share top and height.
      expect(
        artwork.top,
        MessagingDesktopMetrics.sidebarTopRowExtent +
            LicoContentSpacing.compact,
      );
      expect(artwork.height, MessagingDesktopMetrics.sidebarIndexRowExtent);
      expect(firstRow.top, avatar.top);
      expect(
        firstRow.height - MessagingDesktopMetrics.sidebarRowGap,
        avatar.height,
      );
    }

    // Messages: the filter chips centre in a 44 px band at the same top.
    final fixture = await ProductionClientShellFixture.create(
      profileId: BuiltInLayoutSpec.dashboard.id,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      size: const Size(1280, 800),
      brightness: Brightness.dark,
      layoutStyleId: style,
    );
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      fixture.buildApp(
        semanticsKey: const Key('plain-align-semantics'),
        repaintBoundaryKey: const Key('plain-align-repaint'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final avatar = tester.getRect(find.byKey(const Key('dashboard-rail-self')));
    final chipsBand = tester.getRect(
      find.byKey(const Key('messaging-sidebar-filters')),
    );
    expect(chipsBand.top, avatar.top);
    expect(chipsBand.height, avatar.height);
  });

  testWidgets('non-messages details are flat opaque with no ambient layer', (
    tester,
  ) async {
    final harness = DashboardDesktopHarness();
    for (final destination in [
      ClientSection.monitoring,
      ClientSection.settings,
      ClientSection.agentHub,
    ]) {
      await pumpPlainShell(
        tester,
        activeDestination: destination,
        harness: harness,
      );
      // The detail fills to the window's top edge — no band above it — and
      // always right of the rail.
      final detailTopLeft = tester.getTopLeft(
        find.byKey(Key('dashboard-fake-content-${destination.name}')),
      );
      // Settings carries the page padding; the other details still reach
      // the window top.
      expect(
        detailTopLeft.dy,
        destination == ClientSection.settings
            ? DashboardPlainMetrics.mainViewPadding.top
            : 0,
        reason: '${destination.name} detail top inset',
      );
      expect(
        detailTopLeft.dx,
        greaterThanOrEqualTo(DashboardPlainMetrics.railExtent),
      );
      // Dark: the detail ground keeps the ambient under a flat
      // black-mask plane; light stays a solid flat surface.
      expect(find.byType(LicoAmbientLayer), findsOneWidget);
    }
  });

  testWidgets('the Messages detail owns the ambient ground', (tester) async {
    final fixture = await ProductionClientShellFixture.create(
      profileId: BuiltInLayoutSpec.dashboard.id,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      size: const Size(1280, 800),
      brightness: Brightness.dark,
      layoutStyleId: style,
    );
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      fixture.buildApp(
        semanticsKey: const Key('plain-shell-semantics'),
        repaintBoundaryKey: const Key('plain-shell-repaint'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    // The shell's window ground owns the one ambient layer covering the
    // whole window; the conversation detail mounts no ambient of its own.
    final detail = find.byKey(const Key('agents-workspace-detail-pane'));
    expect(detail, findsOneWidget);
    expect(find.byType(LicoAmbientLayer), findsOneWidget);
    expect(
      find.descendant(of: detail, matching: find.byType(LicoAmbientLayer)),
      findsNothing,
    );
  });

  testWidgets('Settings hosts its section index inside the list column', (
    tester,
  ) async {
    final harness = DashboardDesktopHarness();
    await pumpPlainShell(
      tester,
      activeDestination: ClientSection.settings,
      harness: harness,
    );

    // The rail -> sub-list structure: the section index lives in the shell's
    // list column beside the flat settings content.
    final sidebar = find.byKey(const Key('dashboard-plain-sidebar'));
    expect(sidebar, findsOneWidget);
    final index = find.byKey(const Key('messaging-sidebar-settings-list'));
    expect(index, findsOneWidget);
    expect(find.descendant(of: sidebar, matching: index), findsOneWidget);
    expect(
      find.byKey(const Key('dashboard-fake-content-settings')),
      findsOneWidget,
    );

    // The index writes the shared section channel: tapping a row changes the
    // selected index the settings content reads.
    await tester.tap(
      find.byKey(const Key('messaging-sidebar-settings-general')),
    );
    await tester.pump();
    expect(find.byKey(const Key('dashboard-rail-settings')), findsOneWidget);
  });

  testWidgets('the agents destination installs the plain presentation', (
    tester,
  ) async {
    final harness = DashboardDesktopHarness();
    final presentations = <LayoutAgentsPresentation?>[];
    final content = _RecordingAgentsContent(harness, presentations);
    await pumpPlainShell(
      tester,
      activeDestination: ClientSection.agents,
      harness: harness,
      content: content,
    );

    expect(presentations, hasLength(1));
    expect(
      identical(presentations.single, dashboardPlainAgentsPresentation),
      isTrue,
    );
    final presentation = presentations.single!;
    expect(presentation.sidebarHeader, LayoutAgentsSidebarHeader.search);
    expect(presentation.showConversationFilters, isTrue);
    expect(presentation.showSidebarBottomNav, isFalse);
    expect(
      presentation.conversationHeaderStyle,
      LayoutConversationHeaderStyle.bar,
    );
    expect(
      presentation.groupMembersPlacement,
      LayoutGroupMembersPlacement.sidePanel,
    );
  });

  testWidgets('search-row controls fire once and only empty pixels zoom', (
    tester,
  ) async {
    final previousZoom = ClientPlatformPorts.toggleZoom;
    final previousDrag = ClientPlatformPorts.dragWindow;
    addTearDown(() {
      ClientPlatformPorts.toggleZoom = previousZoom;
      ClientPlatformPorts.dragWindow = previousDrag;
    });
    var zooms = 0;
    ClientPlatformPorts.toggleZoom = () async => zooms++;
    ClientPlatformPorts.dragWindow = () async {};

    final fixture = await ProductionClientShellFixture.create(
      profileId: BuiltInLayoutSpec.dashboard.id,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      size: const Size(1280, 800),
      brightness: Brightness.dark,
      layoutStyleId: style,
    );
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      fixture.buildApp(
        semanticsKey: const Key('plain-band-semantics'),
        repaintBoundaryKey: const Key('plain-band-repaint'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    // The compose action in the column's search row: one tap fires the
    // action exactly once — the drag layer sits below the row's controls.
    final compose = find.byKey(const Key('messaging-create-conversation'));
    expect(compose, findsOneWidget);
    await tester.tap(compose);
    await tester.pump();
    expect(
      find.byKey(const Key('messaging-create-conversation-menu')),
      findsOneWidget,
    );
    expect(zooms, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('messaging-create-conversation-menu')),
      findsNothing,
    );
  });

  testWidgets('empty sidebar-top pixels zoom on a double tap', (tester) async {
    final previousZoom = ClientPlatformPorts.toggleZoom;
    final previousDrag = ClientPlatformPorts.dragWindow;
    addTearDown(() {
      ClientPlatformPorts.toggleZoom = previousZoom;
      ClientPlatformPorts.dragWindow = previousDrag;
    });
    var zooms = 0;
    ClientPlatformPorts.toggleZoom = () async => zooms++;
    ClientPlatformPorts.dragWindow = () async {};

    final harness = DashboardDesktopHarness();
    await pumpPlainShell(
      tester,
      activeDestination: ClientSection.monitoring,
      harness: harness,
    );

    // The rail's top strip: empty pixels beside the lights reach the drag
    // region below the strip's content.
    final region = find.descendant(
      of: find.byKey(const Key('dashboard-plain-drag-strip')),
      matching: find.byType(LicoWindowDragRegion),
    );
    expect(region, findsOneWidget);
    await tester.tap(region);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(region);
    await tester.pump();
    expect(zooms, 1);
    // Let the recognizer's tap timeout expire before teardown.
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('the card style keeps the classic Dashboard presentation', (
    tester,
  ) async {
    configureDashboardTestView(tester, const Size(1280, 700));
    final harness = DashboardDesktopHarness();
    final presentations = <LayoutAgentsPresentation?>[];
    final content = _RecordingAgentsContent(harness, presentations);
    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.agents,
        content: content,
        harness: harness,
        style: BuiltInLayoutSpec.dashboardCardStyleId,
      ),
    );
    await tester.pump();

    expect(presentations, hasLength(1));
    expect(
      identical(presentations.single, dashboardCardAgentsPresentation),
      isTrue,
    );
    expect(find.byKey(const Key('dashboard-rail')), findsNothing);
  });
}

/// Records the agents presentation the destination scope installs so the
/// style dispatch is observable end to end.
final class _RecordingAgentsContent implements LayoutDestinationContentPort {
  _RecordingAgentsContent(this.harness, this.presentations);

  final DashboardDesktopHarness harness;
  final List<LayoutAgentsPresentation?> presentations;
  late final DashboardDesktopFixtureContent _delegate =
      DashboardDesktopFixtureContent(harness);

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    presentations.add(maybeLayoutAgentsPresentationOf(context));
    return _delegate.buildDestination(context, destination);
  }
}

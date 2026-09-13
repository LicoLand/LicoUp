import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/dashboard_feature_order.dart';
import 'package:licoup/src/frontend/shared/dashboard_feature_order_store.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/dashboard_desktop.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_navigation.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import '../../../fixtures/layout_scoped_state_fixture.dart';

final class _RecordingOrderStore extends DashboardFeatureOrderStore {
  _RecordingOrderStore(this._stored);

  List<String> _stored;
  List<String>? lastSaved;

  @override
  Future<List<String>> load(Object portableData) async => _stored;

  @override
  Future<void> save(Object portableData, List<String> order) async {
    lastSaved = order;
    _stored = order;
  }
}

Future<void> _pumpFeatureList(
  WidgetTester tester, {
  required _RecordingOrderStore store,
  required List<ClientSection> selections,
  ClientSection current = ClientSection.agentHub,
  Locale locale = const Locale('zh'),
}) async {
  final bundle = dashboardDesktopBundle;
  final scopedState = buildLayoutScopedStateFixture(
    profile: bundle.profile,
    surface: LayoutRuntimeSurface.desktop,
    stateNamespaces: bundle.stateNamespaces,
    destination: current,
  );
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      // Keep the layout palette above the Navigator so drag-proxy rows built
      // in the root overlay still resolve it.
      builder: (context, child) => LayoutPaletteScope(
        palette: layoutPaletteFromColors(context.licoColors),
        child: child!,
      ),
      home: MessagingFeatureOrderScope(
        orderStore: store,
        portableData: Object(),
        child: LayoutScope(
          profileId: bundle.profile.id,
          environment: LayoutEnvironment.fromConstraints(
            surface: LayoutRuntimeSurface.desktop,
            width: 1280,
            height: 700,
            textScale: 1,
          ),
          restorationNamespace: bundle.restorationNamespace,
          tokens: bundle.tokens,
          state: scopedState,
          child: Scaffold(
            body: SizedBox(
              width: 280,
              height: 600,
              child: MessagingFeatureSidebarList(
                current: current,
                onSelectDestination: selections.add,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('stored custom order applies on load', (tester) async {
    final selections = <ClientSection>[];
    await _pumpFeatureList(
      tester,
      store: _RecordingOrderStore(const [
        'statsPanel',
        'agentHub',
        'modelGateway',
        'mobilePairing',
      ]),
      selections: selections,
    );

    double dyOf(String id) =>
        tester.getTopLeft(find.byKey(Key('messaging-sidebar-list-$id'))).dy;
    expect(
      find.byKey(const Key('messaging-sidebar-list-chatChannels')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-list-pluginManagement')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-list-skillHub')),
      findsNothing,
    );
    expect(dyOf('statsPanel'), lessThan(dyOf('agentHub')));
    expect(dyOf('agentHub'), lessThan(dyOf('modelGateway')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long-press drag reorders entries and persists the order', (
    tester,
  ) async {
    final selections = <ClientSection>[];
    final store = _RecordingOrderStore(DashboardFeatureOrder.defaultOrder);
    await _pumpFeatureList(tester, store: store, selections: selections);

    final first = find.byKey(const Key('messaging-sidebar-list-agentHub'));
    expect(first, findsOneWidget);

    // Row pitch is 48 (padding 10×2 + icon 20 + row gap 8): 80 carries the
    // first row past two boundaries without reaching a third.
    final gesture = await tester.startGesture(tester.getCenter(first));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 30));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pumpAndSettle();
    await gesture.moveBy(const Offset(0, 40));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(store.lastSaved, isNotNull);
    expect(store.lastSaved!.first, 'modelGateway');
    expect(store.lastSaved!, [
      'modelGateway',
      'mobilePairing',
      'agentHub',
      'statsPanel',
    ]);

    // A remount restores the reordered list from the store.
    await _pumpFeatureList(tester, store: store, selections: selections);
    double dyOf(String id) =>
        tester.getTopLeft(find.byKey(Key('messaging-sidebar-list-$id'))).dy;
    expect(dyOf('modelGateway'), lessThan(dyOf('mobilePairing')));
    expect(dyOf('mobilePairing'), lessThan(dyOf('agentHub')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('model gateway and mobile pairing select their destinations', (
    tester,
  ) async {
    final selections = <ClientSection>[];
    await _pumpFeatureList(
      tester,
      store: _RecordingOrderStore(DashboardFeatureOrder.defaultOrder),
      selections: selections,
      current: ClientSection.models,
    );
    await tester.tap(
      find.byKey(const Key('messaging-sidebar-list-mobilePairing')),
    );
    await tester.tap(
      find.byKey(const Key('messaging-sidebar-list-modelGateway')),
    );
    await tester.pump();
    expect(selections, [ClientSection.mobileRelay, ClientSection.models]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection highlight follows the active pane', (tester) async {
    final selections = <ClientSection>[];
    await _pumpFeatureList(
      tester,
      store: _RecordingOrderStore(DashboardFeatureOrder.defaultOrder),
      selections: selections,
      current: ClientSection.models,
    );

    final colors = tester
        .element(find.byKey(const Key('messaging-sidebar-feature-list')))
        .licoColors;
    AnimatedContainer rowContainer(String id) =>
        tester.widget<AnimatedContainer>(
          find.descendant(
            of: find.byKey(Key('messaging-sidebar-list-$id')),
            matching: find.byType(AnimatedContainer),
          ),
        );

    expect(
      (rowContainer('modelGateway').decoration! as BoxDecoration).color,
      colors.primary,
    );
    expect(
      (rowContainer('mobilePairing').decoration! as BoxDecoration).color,
      isNot(colors.primary),
    );
    expect(tester.takeException(), isNull);
  });
}

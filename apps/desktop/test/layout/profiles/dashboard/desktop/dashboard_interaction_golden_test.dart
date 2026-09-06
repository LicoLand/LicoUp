// Rendered proof for the interactive Dashboard navigation behaviors, driven
// against the real production shell (production fixture: real controller,
// real composition, deterministic fixture backends):
//   - 模型网关 / 聊天频道 open the models destination on their distinct panes
//   - long-press drag reorders the 功能 list and the order survives a remount
// Golden PNGs double as the visual-verification evidence for these bullets.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_navigation.dart';
import 'package:licoup/src/platform/layout/dashboard_feature_order_store.dart';

import '../../../fixtures/production_client_shell_fixture.dart';

final class _GoldenOrderStore extends DashboardFeatureOrderStore {
  List<String> _stored = DashboardFeatureOrderStore.defaultOrder;

  @override
  Future<List<String>> load(Object portableData) async => _stored;

  @override
  Future<void> save(Object portableData, List<String> order) async {
    _stored = order;
  }
}

void main() {
  testWidgets('dashboard navigation interactions render correctly', (
    tester,
  ) async {
    final fixture = await ProductionClientShellFixture.create(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agentHub,
      size: const Size(1280, 800),
      brightness: Brightness.dark,
    );
    addTearDown(fixture.controller.dispose);
    final store = _GoldenOrderStore();
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> pumpApp() async {
      await tester.pumpWidget(
        MessagingFeatureOrderScope(
          orderStore: store,
          portableData: Object(),
          child: fixture.buildApp(
            semanticsKey: const Key('dashboard-interaction-semantics'),
            repaintBoundaryKey: const Key('dashboard-interaction-repaint'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();
    }

    await pumpApp();

    // The 功能 list shows the seven frozen entries in order.
    const frozenOrder = <String>[
      'agentHub',
      'modelGateway',
      'mobilePairing',
      'statsPanel',
      'pluginManagement',
      'skillHub',
      'chatChannels',
    ];
    double? previousDy;
    for (final id in frozenOrder) {
      final row = find.byKey(Key('messaging-sidebar-list-$id'));
      expect(row, findsOneWidget, reason: 'missing 功能 row $id');
      final dy = tester.getTopLeft(row).dy;
      if (previousDy != null) {
        expect(dy, greaterThan(previousDy), reason: 'order broken at $id');
      }
      previousDy = dy;
    }

    // 聊天频道 opens the models destination on the chat-channels pane.
    await tester.tap(
      find.byKey(const Key('messaging-sidebar-list-chatChannels')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(fixture.controller.currentSection, ClientSection.models);
    expect(
      find.byKey(const Key('models-panel-chat-channels')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('models-panel-licoup-keys-layout-v3-gateway-first')),
      findsNothing,
    );
    final paneNamespace = LayoutStateNamespace(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.models,
      channel: LayoutStateChannels.communicationSection,
    );
    final paneState = fixture.layoutStateStore.read(paneNamespace);
    expect(paneState, isA<LayoutTabState>());
    expect((paneState! as LayoutTabState).index, 1);
    await expectLater(
      find.byKey(const Key('dashboard-interaction-repaint')),
      matchesGoldenFile('goldens/dashboard_models_chat_channels_pane.png'),
    );

    // 模型网关 opens the same destination on the gateway pane. The pane
    // selection lands through the retained channel on entry, matching the
    // pre-redesign communication list semantics.
    await tester.tap(
      find.byKey(const Key('messaging-sidebar-nav-conversations')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(fixture.controller.currentSection, ClientSection.agents);
    await tester.tap(find.byKey(const Key('messaging-sidebar-nav-features')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(fixture.controller.currentSection, ClientSection.agentHub);
    await tester.tap(
      find.byKey(const Key('messaging-sidebar-list-modelGateway')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(fixture.controller.currentSection, ClientSection.models);
    expect(
      find.byKey(const Key('models-panel-licoup-keys-layout-v3-gateway-first')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('models-panel-chat-channels')), findsNothing);
    final gatewayPaneState = fixture.layoutStateStore.read(paneNamespace);
    expect((gatewayPaneState! as LayoutTabState).index, 0);
    await expectLater(
      find.byKey(const Key('dashboard-interaction-repaint')),
      matchesGoldenFile('goldens/dashboard_models_gateway_pane.png'),
    );

    // Long-press drag reorders the 功能 list vertically.
    final firstRow = find.byKey(const Key('messaging-sidebar-list-agentHub'));
    expect(firstRow, findsOneWidget);
    final gesture = await tester.startGesture(tester.getCenter(firstRow));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 30));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pumpAndSettle();
    await gesture.moveBy(const Offset(0, 70));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 120));
    expect(store._stored, [
      'modelGateway',
      'mobilePairing',
      'statsPanel',
      'agentHub',
      'pluginManagement',
      'skillHub',
      'chatChannels',
    ]);
    await expectLater(
      find.byKey(const Key('dashboard-interaction-repaint')),
      matchesGoldenFile('goldens/dashboard_features_reordered.png'),
    );

    // A fresh mount restores the custom order.
    await pumpApp();
    double dyOf(String id) =>
        tester.getTopLeft(find.byKey(Key('messaging-sidebar-list-$id'))).dy;
    expect(dyOf('modelGateway'), lessThan(dyOf('mobilePairing')));
    expect(dyOf('mobilePairing'), lessThan(dyOf('statsPanel')));
    expect(dyOf('statsPanel'), lessThan(dyOf('agentHub')));
    await expectLater(
      find.byKey(const Key('dashboard-interaction-repaint')),
      matchesGoldenFile('goldens/dashboard_features_reorder_restored.png'),
    );
    expect(tester.takeException(), isNull);
  });
}

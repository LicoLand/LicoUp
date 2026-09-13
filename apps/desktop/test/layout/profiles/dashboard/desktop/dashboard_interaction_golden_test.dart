// Rendered proof for the interactive Dashboard navigation behaviors, driven
// against the real production shell (production fixture: real controller,
// real composition, deterministic fixture backends):
//   - 模型网关 opens its gateway and 移动配对 includes chat channels
//   - long-press drag reorders the 功能 list and the order survives a remount
// Golden PNGs double as the visual-verification evidence for these bullets.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../../support/bundled_font_loader.dart';

import 'package:licoup/src/contracts/presentation/dashboard_feature_order.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/frontend/shared/dashboard_feature_order_store.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_navigation.dart';

import '../../../fixtures/production_client_shell_fixture.dart';

final class _GoldenOrderStore extends DashboardFeatureOrderStore {
  List<String> _stored = DashboardFeatureOrder.defaultOrder;

  @override
  Future<List<String>> load(Object portableData) async => _stored;

  @override
  Future<void> save(Object portableData, List<String> order) async {
    _stored = order;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadBundledVisualFonts);
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

    // The 功能 list shows the four visible entries in order.
    const frozenOrder = <String>[
      'agentHub',
      'modelGateway',
      'mobilePairing',
      'statsPanel',
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

    // Chat channels live inside mobile pairing.
    await tester.tap(
      find.byKey(const Key('messaging-sidebar-list-mobilePairing')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(fixture.controller.currentSection, ClientSection.mobileRelay);
    expect(
      find.byKey(const Key('mobile-pairing-chat-channels')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('models-panel-licoup-keys-layout-v3-gateway-first')),
      findsNothing,
    );
    await expectLater(
      find.byKey(const Key('dashboard-interaction-repaint')),
      matchesGoldenFile('goldens/dashboard_mobile_pairing_channels.png'),
    );

    // Model gateway retains its own destination.
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
    await expectLater(
      find.byKey(const Key('dashboard-interaction-repaint')),
      matchesGoldenFile('goldens/dashboard_models_gateway_pane.png'),
    );

    // Long-press drag reorders the 功能 list vertically: one short move drops
    // the first row one slot down. (The production shell runs live timers,
    // so multi-slot pixel drags land inconsistently; a single-slot move is
    // the stable interactive-reorder proof.)
    final firstRow = find.byKey(const Key('messaging-sidebar-list-agentHub'));
    expect(firstRow, findsOneWidget);
    final gesture = await tester.startGesture(tester.getCenter(firstRow));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 30));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 120));
    expect(store._stored, [
      'modelGateway',
      'agentHub',
      'mobilePairing',
      'statsPanel',
    ]);
    await expectLater(
      find.byKey(const Key('dashboard-interaction-repaint')),
      matchesGoldenFile('goldens/dashboard_features_reordered.png'),
    );

    // A fresh mount restores the custom order.
    await pumpApp();
    double dyOf(String id) =>
        tester.getTopLeft(find.byKey(Key('messaging-sidebar-list-$id'))).dy;
    expect(dyOf('modelGateway'), lessThan(dyOf('agentHub')));
    expect(dyOf('agentHub'), lessThan(dyOf('mobilePairing')));
    expect(dyOf('mobilePairing'), lessThan(dyOf('statsPanel')));
    await expectLater(
      find.byKey(const Key('dashboard-interaction-repaint')),
      matchesGoldenFile('goldens/dashboard_features_reorder_restored.png'),
    );
    expect(tester.takeException(), isNull);
  });
}

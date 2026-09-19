import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_providers.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import 'panel_test_harness.dart';

void main() {
  testWidgets('panel composes the desktop pairing workspace', (tester) async {
    final projection = mobileRelayProjectionFixture(
      stationLabel: 'https://station.example.test',
      stationConfigured: true,
    );
    final fixture = MobileRelayBindingFixture(projection: projection);
    final presentation = MobileRelayPresentationFixture(projection: projection);
    addTearDown(fixture.dispose);
    addTearDown(presentation.dispose);

    await tester.pumpWidget(
      mobileRelayPanelTestApp(
        presentation: presentation,
        child: MobileRelayPanel(binding: fixture.binding),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The panel inherits the standard feature-page structure: pane title bar
    // (移动配对 + refresh) above, content below.
    expect(find.byType(LicoPaneScaffold), findsOneWidget);
    expect(find.text('Mobile Pairing'), findsOneWidget);
    expect(find.byKey(const Key('mobile-relay-refresh')), findsOneWidget);
    expect(find.text('Communication'), findsNothing);
    expect(find.byKey(const Key('pairing-qr-workspace-card')), findsOneWidget);
    expect(find.byKey(const Key('pairing-qr-frame')), findsOneWidget);
    expect(find.byType(MobileRelayScanPairingPrompt), findsNothing);
  });

  testWidgets('a home region change leaves the pairing card untouched', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final projection = mobileRelayProjectionFixture(
      stationLabel: 'https://station.example.test',
      stationConfigured: true,
    );
    final fixture = MobileRelayBindingFixture(projection: projection);
    final presentation = MobileRelayPresentationFixture(projection: projection);
    addTearDown(fixture.dispose);
    addTearDown(presentation.dispose);
    final homePeerCounts = <int>[];

    await tester.pumpWidget(
      mobileRelayPanelTestApp(
        presentation: presentation,
        child: Column(
          children: [
            MobileRelayHomeRegionProbe(
              actions: fixture.intents,
              onData: (home) => homePeerCounts.add(home.peers.length),
            ),
            Expanded(child: MobileRelayPanel(binding: fixture.binding)),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    MobileRelayPairingWorkspaceCard pairingCard() =>
        tester.widget<MobileRelayPairingWorkspaceCard>(
          find.byType(MobileRelayPairingWorkspaceCard),
        );
    final before = pairingCard();
    expect(homePeerCounts.last, 0);
    expect(presentation.home.openCount, 1);
    expect(presentation.pairing.openCount, 1);
    final buildsBeforeHomeChange = homePeerCounts.length;

    presentation.home.publish(
      MobileRelayPresentationFixture.homeOf(
        mobileRelayProjectionFixture(
          peers: const [
            RelayPeerProjection(
              id: 'device-1',
              displayName: 'Workstation',
              connected: true,
              selected: true,
            ),
          ],
          homeEntryOrder: const ['device:device-1'],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(homePeerCounts.last, 1, reason: '$homePeerCounts');
    expect(homePeerCounts.length, greaterThan(buildsBeforeHomeChange));
    expect(identical(before, pairingCard()), isTrue);
    final buildsAfterHomeChange = homePeerCounts.length;

    presentation.pairing.publish(
      MobileRelayPresentationFixture.pairingOf(
        mobileRelayProjectionFixture(
          stationLabel: 'https://station.updated.test',
          stationConfigured: true,
          paired: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(identical(before, pairingCard()), isFalse);
    expect(homePeerCounts.length, buildsAfterHomeChange);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is EditableText &&
            widget.controller.text == 'https://station.updated.test',
      ),
      findsOneWidget,
    );
    expect(find.text('Paired'), findsOneWidget);
  });
}

/// Minimal home-region consumer so the test publishes into a live observation
/// instead of an unlistened source.
final class MobileRelayHomeRegionProbe extends StatelessWidget {
  const MobileRelayHomeRegionProbe({
    super.key,
    required this.actions,
    required this.onData,
  });

  final IntentSink<MobileRelayIntent> actions;
  final ValueChanged<MobileRelayHomeInputs> onData;

  @override
  Widget build(BuildContext context) {
    return AsyncRegion<MobileRelayHomeInputs, IntentSink<MobileRelayIntent>>(
      source: mobileRelayHomeInputsProvider,
      actions: actions,
      loading: (_, _) => const SizedBox.shrink(),
      data: (context, home, _) {
        onData(home);
        return Text('home peers ${home.peers.length}');
      },
    );
  }
}

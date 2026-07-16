import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_client/src/application/features/catalog_convergence/controller/catalog_convergence_controller.dart';
import 'package:flutter_client/src/contracts/catalog_convergence/catalog_convergence_gateway.dart';
import 'package:flutter_client/src/contracts/catalog_convergence/catalog_convergence_models.dart';
import 'package:flutter_client/src/frontend/features/settings/ui/catalog_convergence_status_card.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'status card projects bounded facts without opaque partition keys',
    (tester) async {
      final controller = CatalogConvergenceController(
        gateway: _StatusGateway(),
      );
      addTearDown(controller.dispose);
      await controller.bootstrap();

      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          home: Scaffold(
            body: CatalogConvergenceStatusCard(controller: controller),
          ),
        ),
      );

      expect(find.text('Tool catalog sync'), findsOneWidget);
      expect(find.textContaining('Partitions: 1'), findsOneWidget);
      expect(find.textContaining('UI revision: 7'), findsOneWidget);
      expect(find.textContaining('opaque-private-partition'), findsNothing);
    },
  );
}

final class _StatusGateway implements CatalogConvergenceGateway {
  @override
  Future<CatalogConvergenceStatus> status() async =>
      const CatalogConvergenceStatus(
        partitionCount: 1,
        inFlightCount: 0,
        pendingInvalidationCount: 0,
        reconnectFence: false,
        lastKnownAudienceRevision: 7,
        uiObservedRevision: 7,
        appliedCohortCount: 1,
        pendingCohortCount: 0,
        fencedCohortCount: 0,
        disconnectedCohortCount: 0,
      );

  @override
  Future<void> beginReconnect() async {}

  @override
  Future<List<String>> invalidate(CatalogInvalidation notification) async =>
      notification.affectedPartitions;

  @override
  Future<CatalogDiscoveryResult> listTools(String partitionKey) =>
      throw UnimplementedError();

  @override
  Future<bool> observeUi(String partitionKey) async => true;

  @override
  Future<void> purge({String partitionKey = ''}) async {}

  @override
  Future<void> replacePartition(
    String partitionKey,
    CatalogFetchedSnapshot snapshot,
  ) async {}
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
import 'package:flutter_client/src/frontend/features/local_runtime/ui/local_runtime_panel.dart';
import 'package:flutter_client/src/frontend/shared/ui/panel_frame.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Runtime modules use a left module list and right detail pane', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dataDirectory = Directory.systemTemp.createTempSync(
      'lico-local-runtime-panel-',
    );
    addTearDown(() {
      if (dataDirectory.existsSync()) {
        dataDirectory.deleteSync(recursive: true);
      }
    });

    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: dataDirectory),
      agentService: AgentService(
        runCliExecutable: (_, _, _) async {
          throw StateError('local runtime panel test does not execute CLI');
        },
      ),
    );
    addTearDown(controller.dispose);

    controller.localRuntimeState = {
      'running': true,
      'runtimeModules': {
        'edition': 'client-local',
        'activeFeatures': [
          {
            'id': 'activity-snapshots',
            'label': 'Activity log and independent snapshot store',
            'category': 'activity',
            'packaging': 'runtime-capability',
            'required': true,
            'platforms': ['macos', 'linux'],
            'requires': ['portable-data'],
          },
          {
            'id': 'knowledge-cache',
            'label': 'Authorized KnowledgeCore mirror cache',
            'category': 'knowledge',
            'packaging': 'runtime-capability',
            'enabled': true,
            'status': 'enabled',
            'required': true,
            'platforms': ['macos'],
            'requires': ['native-sidecar', 'portable-data'],
          },
          {
            'id': 'mail-import-runtime',
            'label': 'macOS Mail scoped preview',
            'category': 'ingestion',
            'packaging': 'runtime-capability',
            'enabled': true,
            'ok': false,
            'status': 'unavailable',
            'platforms': ['macos'],
            'requires': ['portable-data'],
          },
        ],
        'disabledFeatures': [
          {
            'id': 'model-forwarding',
            'label': 'Thin model forwarding profiles',
            'category': 'model-forwarding',
            'packaging': 'runtime-capability',
            'enabled': false,
            'status': 'disabled',
            'platforms': ['macos'],
            'requires': ['native-sidecar'],
          },
        ],
      },
    };

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(),
        home: Scaffold(body: LocalRuntimePanel(controller: controller)),
      ),
    );
    await tester.pump();

    expect(find.byType(PanelFrame), findsNothing);
    expect(find.text('Runtime Modules'), findsOneWidget);
    expect(find.text('Modules'), findsOneWidget);
    expect(find.text('Module ID'), findsOneWidget);
    expect(find.text('3 active'), findsNothing);
    expect(
      find.textContaining('Current service runtime profile'),
      findsNothing,
    );
    expect(find.text('Edition'), findsNothing);
    expect(find.text('Feature modules'), findsNothing);
    expect(find.text('Server modules'), findsNothing);
    expect(find.text('Mounts'), findsNothing);
    expect(find.text('Runtime (2)'), findsNothing);
    expect(find.text('Server runtime modules (0)'), findsNothing);
    expect(find.text('Runtime mounts (0)'), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsWidgets);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byTooltip('Enabled'), findsWidgets);
    expect(find.byTooltip('Disabled'), findsOneWidget);
    expect(find.byTooltip('Warning'), findsOneWidget);

    expect(find.text('Activity Snapshots'), findsWidgets);
    expect(
      find.text('Activity log and independent snapshot store'),
      findsWidgets,
    );
    expect(find.text('Portable Data'), findsOneWidget);

    await tester.tap(find.text('Knowledge Cache').first);
    await tester.pump();

    expect(find.text('Authorized KnowledgeCore mirror cache'), findsWidgets);
    expect(find.text('Knowledge'), findsOneWidget);
    expect(find.text('Native Sidecar'), findsOneWidget);
  });
}

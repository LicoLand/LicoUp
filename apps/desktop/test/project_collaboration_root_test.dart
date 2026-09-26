import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/composition/project_collaboration_root.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_navigation.dart';
import 'package:licoup/src/presentation/layout/semantic_destination_catalog.dart';

void main() {
  test('project collaboration is a feature, not a primary destination', () {
    final destinations = SemanticDestinationCatalog.current();
    expect(
      destinations.supports(
        ClientSection.agentHub,
        LayoutRuntimeSurface.desktop,
      ),
      isTrue,
    );
    expect(
      destinations.supports(
        ClientSection.agentHub,
        LayoutRuntimeSurface.mobile,
      ),
      isFalse,
    );
    expect(
      messagingFeatureItemSection(MessagingFeatureItem.projectCollaboration),
      ClientSection.agentHub,
    );
    expect(messagingSidebarHostsFeatures(ClientSection.agentHub), isTrue);
    expect(
      ClientSection.values.map((value) => value.name),
      isNot(contains('projectCollaboration')),
    );
    expect(desktopFeatureApps, contains(DesktopAppId.projectCollaboration));
    expect(
      desktopAppSection(DesktopAppId.projectCollaboration),
      ClientSection.agentHub,
    );
  });

  testWidgets('unseeded root is honest and survives destination re-entry', (
    tester,
  ) async {
    final runtime = PresentationRuntime();
    final showGraph = ValueNotifier(true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [presentationRuntimeProvider.overrideWithValue(runtime)],
        child: MaterialApp(
          home: ProjectCollaborationRoot(
            child: ValueListenableBuilder<bool>(
              valueListenable: showGraph,
              builder: (context, visible, _) => visible
                  ? Consumer(
                      builder: (context, ref, _) {
                        expect(
                          ref.read(presentationRuntimeProvider),
                          same(runtime),
                        );
                        return ProjectCollaborationRoot.layerOf(context);
                      },
                    )
                  : const SizedBox(key: Key('other-destination')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('project-collaboration-unavailable')),
      findsOneWidget,
    );

    showGraph.value = false;
    await tester.pump();
    expect(find.byKey(const Key('other-destination')), findsOneWidget);
    showGraph.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('project-collaboration-unavailable')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    showGraph.dispose();
    runtime.dispose();
    expect(tester.takeException(), isNull);
  });
}

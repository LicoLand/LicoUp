import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/strategy.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets(
    'name toggles separately from edit and unconfigured name is disabled',
    (tester) async {
      var toggles = 0;
      var edits = 0;
      Future<void> mount(bool configured) => tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 180,
                  child: AssistantToggleButton(
                    active: true,
                    configured: configured,
                    label: 'A very long assistant display name',
                    status: configured
                        ? GroupAssistantStatusLight.ready
                        : GroupAssistantStatusLight.unconfigured,
                    onTap: () => toggles++,
                    onEdit: () => edits++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await mount(true);
      await tester.tap(
        find.byKey(const Key('canonical-group-assistant-control')),
      );
      expect(toggles, 1);
      expect(edits, 0);
      await tester.tap(find.byKey(const Key('canonical-group-assistant-edit')));
      expect(edits, 1);
      expect(toggles, 1);
      expect(tester.takeException(), isNull);
      await mount(false);
      await tester.tap(
        find.byKey(const Key('canonical-group-assistant-control')),
      );
      expect(toggles, 1);
      await tester.tap(find.byKey(const Key('canonical-group-assistant-edit')));
      expect(edits, 2);
    },
  );

  testWidgets('active name light moves and stops for reduced motion or pause', (
    tester,
  ) async {
    Future<void> mount({bool reduced = false, bool active = true}) =>
        tester.pumpWidget(
          MaterialApp(
            theme: buildLicoTheme(platformBrightness: Brightness.dark),
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 180,
                    child: AssistantToggleButton(
                      active: active,
                      configured: true,
                      label: 'Assistant',
                      status: active
                          ? GroupAssistantStatusLight.ready
                          : GroupAssistantStatusLight.paused,
                      onTap: () {},
                      onEdit: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
    await mount();
    final mask = find.descendant(
      of: find.byKey(const Key('canonical-group-assistant-control')),
      matching: find.byType(ShaderMask),
    );
    expect(mask, findsOneWidget);
    final first = tester.widget<ShaderMask>(mask);
    await tester.pump(const Duration(milliseconds: 500));
    expect(identical(first, tester.widget<ShaderMask>(mask)), isFalse);
    await mount(reduced: true);
    await tester.pumpAndSettle();
    expect(mask, findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await mount(active: false);
    await tester.pumpAndSettle();
    expect(mask, findsNothing);
    expect(
      find.byKey(const Key('canonical-group-assistant-status-paused')),
      findsOneWidget,
    );
  });
}

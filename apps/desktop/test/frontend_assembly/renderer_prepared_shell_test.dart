// V7-FI: the BindingShellRenderer chrome consumes prepared shell sources.
//
// The renderer must never read the raw projection owners for chrome, status,
// or locale. These tests drive the real composition over a bounded fixture
// controller and prove the behaviors the migration is accountable for:
// admitted values reach the chrome exposure, a value-equal republish is not a
// change, focused status/error/locale changes update exactly once, authority
// revocation clears it while the legacy owner still holds its value, and an
// explicit reconnect restores the freshly admitted value.
//
// The value-equal and focused-update assertions are the successors of the
// retired legacy chrome-port wrapper behavior test; they now run against the
// runtime-backed renderer path instead of the removed wrapper.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/presentation/shell/shell_providers.dart';
import 'package:licoup/src/projections/chrome/chrome_presentation_source.dart';

import '../layout/fixtures/production_client_shell_fixture.dart';

void main() {
  testWidgets('chrome notices follow the runtime source, not the owner', (
    tester,
  ) async {
    final fixture = await ProductionClientShellFixture.create(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agentHub,
      size: const Size(1280, 800),
      brightness: Brightness.dark,
    );
    addTearDown(fixture.dispose);
    final composition = ClientAppComposition(controller: fixture.controller);
    addTearDown(composition.dispose);
    final runtime = composition.presentationRuntime;
    final notices = composition.renderer
        .createChromeFeatures(ValueNotifier<bool>(false))
        .notificationNotices;
    var notifications = 0;
    void listener() => notifications += 1;
    notices.addListener(listener);
    addTearDown(() => notices.removeListener(listener));

    expect(notices.value.operationNotices, isEmpty);

    fixture.controller.messagingNotificationCenter.publish(
      id: 'assembly-notice',
      messageChinese: '装配任务完成',
      messageEnglish: 'Assembly task completed',
      tone: MessagingNotificationTone.success,
      code: 'assembly',
    );
    await tester.pump();
    expect(notices.value.operationNotices, hasLength(1));
    expect(notices.value.operationRevision, 1);
    expect(notifications, greaterThan(0));

    // Revocation clears the exposure even though the chrome owner still holds
    // the notice; the renderer never re-serves the withdrawn read.
    runtime.revoke(chromePresentationFieldGroup.resource);
    await tester.pump();
    expect(notices.value.operationNotices, isEmpty);
    expect(
      composition.chrome.projection.current.operationNotifications,
      hasLength(1),
    );

    final lease = runtime.own(composition.chromeSource);
    addTearDown(lease.release);
    await lease.reconnect();
    await tester.pump();
    expect(notices.value.operationNotices, hasLength(1));
    expect(notices.value.operationRevision, 1);
  });

  testWidgets('chrome status and locale follow admitted shell sources', (
    tester,
  ) async {
    final fixture = await ProductionClientShellFixture.create(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agentHub,
      size: const Size(1280, 800),
      brightness: Brightness.dark,
    );
    addTearDown(fixture.dispose);
    final composition = ClientAppComposition(controller: fixture.controller);
    addTearDown(composition.dispose);
    final runtime = composition.presentationRuntime;
    final chrome = composition.renderer.chrome;

    // The fixture seeds status through the controller owner; the port only
    // shows it once the runtime admits the shell status region.
    expect(chrome.value, const LayoutChromeSnapshot.empty());
    await tester.pump();
    expect(
      chrome.value.status.displayText,
      'Deterministic layout baseline ready.',
    );

    fixture.controller.statusMessage = 'Focused status';
    await tester.pump();
    expect(chrome.value.status.displayText, 'Focused status');

    // Locale changes resolve through the locale region, not the status owner.
    fixture.controller.setLocalizedStatusMessage('中文状态', 'English status');
    fixture.controller.localePreference = LocalePreference.chinese;
    await tester.pump();
    expect(chrome.value.status.displayText, '中文状态');
    fixture.controller.localePreference = LocalePreference.english;
    await tester.pump();
    expect(chrome.value.status.displayText, 'English status');

    // Revocation clears the chrome status while the legacy owner keeps the
    // value the renderer must not fall back to.
    fixture.controller.statusMessage = 'Focused status';
    await tester.pump();
    runtime.revoke(shellStatusPresentationFields.resource);
    await tester.pump();
    expect(chrome.value, const LayoutChromeSnapshot.empty());
    expect(composition.binding.status.current.messageEnglish, 'Focused status');

    final lease = runtime.own(composition.shellSources.status);
    addTearDown(lease.release);
    await lease.reconnect();
    await tester.pump();
    expect(chrome.value.status.displayText, 'Focused status');
  });

  testWidgets('chrome port keeps the focused status update semantics', (
    tester,
  ) async {
    final fixture = await ProductionClientShellFixture.create(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agentHub,
      size: const Size(1280, 800),
      brightness: Brightness.dark,
    );
    addTearDown(fixture.dispose);
    final composition = ClientAppComposition(controller: fixture.controller);
    addTearDown(composition.dispose);
    final chrome = composition.renderer.chrome;
    var notifications = 0;
    void listener() => notifications += 1;
    chrome.addListener(listener);
    addTearDown(() => chrome.removeListener(listener));

    expect(chrome.value, const LayoutChromeSnapshot.empty());
    await tester.pump();
    expect(
      chrome.value.status.displayText,
      'Deterministic layout baseline ready.',
    );
    final admitted = notifications;
    expect(admitted, 1, reason: 'the admitted regions publish one value');

    // Re-publishing the same status value is not a change.
    fixture.controller.statusMessage = 'Deterministic layout baseline ready.';
    await tester.pump();
    expect(
      chrome.value.status.displayText,
      'Deterministic layout baseline ready.',
    );
    expect(notifications, admitted);

    // A focused status update publishes exactly one new value.
    fixture.controller.statusMessage = 'Focused status';
    await tester.pump();
    expect(chrome.value.status.displayText, 'Focused status');
    expect(notifications, admitted + 1);

    // The focused error code travels inside the same status snapshot.
    fixture.controller.lastError = 'focused_error';
    await tester.pump();
    expect(chrome.value.status.errorCode, 'focused_error');
    expect(chrome.value.status.displayText, 'Focused status');
    expect(notifications, admitted + 2);

    // The same admitted status resolves in the newly selected language.
    fixture.controller.setLocalizedStatusMessage('聚焦状态', 'Focused status');
    fixture.controller.localePreference = LocalePreference.chinese;
    await tester.pump();
    expect(chrome.value.status.displayText, '聚焦状态');
    expect(notifications, admitted + 3);
  });
}

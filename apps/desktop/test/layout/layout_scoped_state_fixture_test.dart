import 'package:flutter_client/src/application/features/layout/layout_state_store.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_test/flutter_test.dart';

import './fixtures/layout_scoped_state_fixture.dart';

void main() {
  test('fixture admits only supplied presentation-state namespaces', () {
    final profile = LayoutProfileDescriptor(
      id: LayoutProfileId.parse('studio'),
      label: LayoutProfileCopy(english: 'Studio', chinese: '原生'),
      description: LayoutProfileCopy(
        english: 'Studio fixture',
        chinese: '原生夹具',
      ),
      styleIdentity: 'dense-docked-studio',
      isDefault: false,
    );
    final state = buildLayoutScopedStateFixture(
      profile: profile,
      surface: LayoutRuntimeSurface.mobile,
      stateNamespaces: {
        LayoutStateNamespace(
          profileId: profile.id,
          surface: LayoutRuntimeSurface.mobile,
          destination: ClientSection.agents,
          channel: const LayoutStateChannel(
            'conversation-scroll',
            LayoutStateValueKind.scroll,
          ),
        ),
        LayoutStateNamespace(
          profileId: profile.id,
          surface: LayoutRuntimeSurface.mobile,
          destination: ClientSection.settings,
          channel: LayoutStateChannels.settingsScroll,
        ),
      },
    );

    const conversationScroll = LayoutStateChannel(
      'conversation-scroll',
      LayoutStateValueKind.scroll,
    );
    state.write(conversationScroll, LayoutScrollState(24));
    expect((state.read(conversationScroll) as LayoutScrollState).offset, 24);
    expect(
      () =>
          state.write(LayoutStateChannels.settingsScroll, LayoutScrollState(8)),
      throwsFormatException,
    );
  });
}

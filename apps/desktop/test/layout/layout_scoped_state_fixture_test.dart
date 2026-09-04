import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/layout_state_port.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:flutter_test/flutter_test.dart';

import './fixtures/layout_scoped_state_fixture.dart';

void main() {
  test('fixture admits only supplied presentation-state namespaces', () {
    final profile = LayoutProfileDescriptor(
      id: LayoutProfileId.parse('atlas'),
      label: LayoutProfileCopy(english: 'Atlas', chinese: '图集'),
      description: LayoutProfileCopy(english: 'Atlas fixture', chinese: '图集夹具'),
      styleIdentity: 'glassy-rail-atlas',
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

  test('sibling destination channels stay readable for shell chrome', () {
    final profile = LayoutProfileDescriptor(
      id: LayoutProfileId.parse('atlas'),
      label: LayoutProfileCopy(english: 'Atlas', chinese: '图集'),
      description: LayoutProfileCopy(english: 'Atlas fixture', chinese: '图集夹具'),
      styleIdentity: 'glassy-rail-atlas',
      isDefault: false,
    );
    final agentsState = buildLayoutScopedStateFixture(
      profile: profile,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      stateNamespaces: {
        LayoutStateNamespace(
          profileId: profile.id,
          surface: LayoutRuntimeSurface.desktop,
          destination: ClientSection.agents,
          channel: LayoutStateChannels.agentsSidebar,
        ),
      },
    );
    expect(
      agentsState.writeIfDeclaredFor(
        ClientSection.agents,
        LayoutStateChannels.agentsSidebar,
        LayoutPaneExtentState(240),
      ),
      isTrue,
    );
    final settingsState = LayoutScopedState(
      profileId: agentsState.profileId,
      surface: agentsState.surface,
      destination: ClientSection.settings,
      store: agentsState.statePort,
    );
    final stored = settingsState.readIfDeclaredFor(
      ClientSection.agents,
      LayoutStateChannels.agentsSidebar,
    );
    expect(stored, isA<LayoutPaneExtentState>());
    expect((stored! as LayoutPaneExtentState).extent, 240);
  });
}

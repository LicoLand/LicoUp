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
      id: LayoutProfileId.studio,
      labelKey: 'layout.profile.studio.label',
      descriptionKey: 'layout.profile.studio.description',
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
          surfaceId: 'conversation-scroll',
        ),
      },
    );

    state.write(
      destination: ClientSection.agents,
      surfaceId: 'conversation-scroll',
      value: LayoutScrollState(24),
    );
    expect(
      (state.read(
                destination: ClientSection.agents,
                surfaceId: 'conversation-scroll',
              )
              as LayoutScrollState)
          .offset,
      24,
    );
    expect(
      () => state.write(
        destination: ClientSection.settings,
        surfaceId: 'undeclared',
        value: const LayoutExpansionState(true),
      ),
      throwsFormatException,
    );
  });
}

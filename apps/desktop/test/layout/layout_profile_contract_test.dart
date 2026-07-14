import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_variant.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('layout profile identities are semantic and stable', () {
    expect(LayoutProfileId.parse('workbench'), LayoutProfileId.workbench);
    expect(LayoutProfileId.parse('studio'), LayoutProfileId.studio);
    expect(
      () => LayoutProfileId.parse('layout-1'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => LayoutProfileId.parse('legacy'),
      throwsA(isA<FormatException>()),
    );
  });

  test('surface is part of the variant key', () {
    const desktopMedium = LayoutVariantKey(
      profileId: LayoutProfileId.workbench,
      surface: LayoutRuntimeSurface.desktop,
      viewport: LayoutViewportClass.medium,
    );
    const mobileMedium = LayoutVariantKey(
      profileId: LayoutProfileId.workbench,
      surface: LayoutRuntimeSurface.mobile,
      viewport: LayoutViewportClass.medium,
    );

    expect(desktopMedium, isNot(mobileMedium));
    expect({desktopMedium, mobileMedium}, hasLength(2));
    expect(desktopMedium.toString(), 'workbench/desktop/medium');
    expect(mobileMedium.toString(), 'workbench/mobile/medium');
  });

  test('profile descriptor metadata is immutable', () {
    final labels = <String, String>{'en': 'Workbench'};
    final descriptor = LayoutProfileDescriptor(
      id: LayoutProfileId.workbench,
      labels: labels,
      descriptionKeys: const {'en': 'layout.workbench.description'},
      styleIdentity: 'spacious-card-workbench',
      isDefault: true,
    );

    labels['en'] = 'Changed';
    expect(descriptor.labelFor('en'), 'Workbench');
    expect(() => descriptor.labels['en'] = 'Changed', throwsUnsupportedError);
  });
}

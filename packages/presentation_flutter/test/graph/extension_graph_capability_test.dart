import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

/// The resource-view capability: a view mounts only through the renderer
/// registered for its declared format, and an unknown format is refused
/// locally without disturbing anything else.
void main() {
  ExtensionUiContribution contribution({
    String id = 'example.view/project-collaboration',
    String kind = 'resource-view',
    String? format = extensionUiGraphResourceFormat,
    String? resourceRef = 'resource.example/project-collaboration',
  }) => ExtensionUiContribution.fromJson(<String, Object?>{
    'schema': extensionUiContributionSchema,
    'id': id,
    'kind': kind,
    'title': 'Project collaboration',
    if (resourceRef != null) 'resourceRef': resourceRef,
    if (format != null) 'resourceFormat': format,
  });

  test(
    'a resource view without a format is refused for its own reason only',
    () {
      final planned = planExtensionUiMount(
        <ExtensionUiContribution>[
          contribution(id: 'example.view/unformatted', format: null),
          contribution(id: 'example.view/graph'),
        ],
        servedProfiles: const <String>{},
        availablePrimitives:
            ExtensionUiMountRegistry.defaultExtensionUiPrimitives,
      );
      expect(planned[0].blocked, ExtensionUiMountBlock.resourceFormatMissing);
      expect(planned[1].isMounted, isTrue);
    },
  );

  test('the compiled renderer set decides which formats mount', () {
    final planned = planExtensionUiMount(
      <ExtensionUiContribution>[
        contribution(
          id: 'example.view/future',
          format: 'licoup.ui.graph-resource.v9',
        ),
        contribution(id: 'example.view/graph'),
      ],
      servedProfiles: const <String>{},
      availablePrimitives:
          ExtensionUiMountRegistry.defaultExtensionUiPrimitives,
      availableResourceFormats: const <String>{extensionUiGraphResourceFormat},
    );
    expect(
      planned[0].blocked,
      ExtensionUiMountBlock.resourceFormatUnavailable,
      reason: 'an unknown format is preserved and refused locally',
    );
    expect(planned[1].isMounted, isTrue);
  });

  test('a shell without the renderer refuses every graph resource view', () {
    final planned = planExtensionUiMount(
      <ExtensionUiContribution>[contribution()],
      servedProfiles: const <String>{},
      availablePrimitives:
          ExtensionUiMountRegistry.defaultExtensionUiPrimitives,
      availableResourceFormats: const <String>{},
    );
    expect(
      planned.single.blocked,
      ExtensionUiMountBlock.resourceFormatUnavailable,
    );
  });

  test('only a resource view may name a format', () {
    final refusal = contribution(
      id: 'example.settings/endpoint',
      kind: 'settings',
      format: extensionUiGraphResourceFormat,
      resourceRef: null,
    ).refusal();
    expect(refusal?.code, 'ui_contribution_invalid');
    expect(refusal?.field, 'resourceFormat');

    final planned = planExtensionUiMount(
      <ExtensionUiContribution>[
        contribution(
          id: 'example.settings/endpoint',
          kind: 'settings',
          format: extensionUiGraphResourceFormat,
          resourceRef: null,
        ),
        contribution(id: 'example.view/graph'),
      ],
      servedProfiles: const <String>{},
      availablePrimitives:
          ExtensionUiMountRegistry.defaultExtensionUiPrimitives,
    );
    expect(planned[0].blocked, ExtensionUiMountBlock.contributionInvalid);
    expect(planned[1].isMounted, isTrue);
  });

  test('the graph resource view names the published capability', () {
    expect(extensionUiGraphResourceFormat, 'licoup.ui.graph-resource.v1');
    expect(
      extensionUiResourceViewFormats,
      contains(extensionUiGraphResourceFormat),
    );
    // The capability carries data only: no action may smuggle a handler name
    // into a contribution the shell will render.
    final view = contribution();
    expect(view.resourceFormat, extensionUiGraphResourceFormat);
    expect(view.actionRef, isNull);
  });
}

import {
  DEFAULT_LAYOUT_BOUNDARY_CONFIG,
} from "../../verify-layout-boundaries.mjs";
import {
  bundlePath,
  bundleSymbol,
  resetFixture,
  writeRelative,
} from "./helpers.mjs";

const profileContractPath =
  "apps/desktop/lib/src/contracts/presentation/layout_profile.dart";

export async function writeStateAuthorityFixture(root) {
  await writeRelative(
    root,
    DEFAULT_LAYOUT_BOUNDARY_CONFIG.preferencesPath,
    `import 'package:licoup/src/platform/storage/portable_data_root.dart';
final class Preferences {
  static const _fileName = 'appearance-preferences.json';
  Future<void> file() async {
    final root = await _portableData.clientDirectory();
    return File(p.join(root.path, _fileName));
  }
}
`,
  );
  await writeRelative(
    root,
    DEFAULT_LAYOUT_BOUNDARY_CONFIG.portableDataRootPath,
    `final class PortableDataRoot {
  static const String _workspaceManifestFileName = '.licoup-workspace.json';
  Future<Directory> clientDirectory() async {
    final directory = Directory(p.join(dataDir.path, 'client-state'));
    return directory;
  }
}
`,
  );
  await writeRelative(
    root,
    DEFAULT_LAYOUT_BOUNDARY_CONFIG.workspaceManifestPath,
    "static const fileName = '.licoup-workspace.json';\nstatic const licoUpAppId = 'licoup-client';\n",
  );
}

export async function writeNeutralContracts(root) {
  const files = {
    "apps/desktop/lib/src/frontend/layout/layout_chrome_port.dart":
      "abstract interface class LayoutChromePort {}\n",
    "apps/desktop/lib/src/frontend/layout/layout_palette.dart":
      "final class LayoutPalette {}\n",
    "apps/desktop/lib/src/frontend/layout/layout_destination_presentation.dart":
      "abstract interface class LayoutDestinationPresentation {}\n",
  };
  for (const [relativePath, source] of Object.entries(files)) {
    await writeRelative(root, relativePath, source);
  }
}

export async function writeCatalogFixture(
  root,
  profiles,
  surfaces,
  {
    omitOwners = new Set(),
    duplicateDefinitionOwner = null,
    identityOverrides = new Map(),
  } = {},
) {
  await resetFixture(root);
  await writeRelative(
    root,
    profileContractPath,
    `final class LayoutProfileId {
  const LayoutProfileId._(this.value);
  factory LayoutProfileId.parse(String value) => LayoutProfileId._(value);
  final String value;
}
`,
  );
  await writeRelative(
    root,
    DEFAULT_LAYOUT_BOUNDARY_CONFIG.surfaceContractPath,
    `enum LayoutRuntimeSurface { ${surfaces.join(", ")} }\n`,
  );
  await writeNeutralContracts(root);
  await writeStateAuthorityFixture(root);

  const imports = [];
  const definitions = [];
  for (const profile of profiles) {
    const symbols = [];
    for (const surface of surfaces) {
      const owner = `${profile}/${surface}`;
      const symbol = bundleSymbol(profile, surface);
      const relativePath = bundlePath(profile, surface);
      const identity = identityOverrides.get(owner) ?? { profile, surface };
      await writeRelative(
        root,
        relativePath,
        `import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';

final LayoutSurfaceBundle ${symbol} = LayoutSurfaceBundle(
  profile: LayoutProfileDescriptor(id: LayoutProfileId.parse('${identity.profile}')),
  surface: LayoutRuntimeSurface.${identity.surface},
);
`,
      );
      await writeRelative(
        root,
        `${DEFAULT_LAYOUT_BOUNDARY_CONFIG.profileTestRoot}/${profile}/${surface}/${profile}_${surface}_bundle_test.dart`,
        `import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/${relativePath.slice("apps/desktop/lib/".length)}';
void main() {}
`,
      );
      if (!omitOwners.has(owner)) {
        imports.push(
          `import 'package:licoup/${relativePath.slice("apps/desktop/lib/".length)}';`,
        );
        symbols.push(symbol);
        if (duplicateDefinitionOwner === owner) {
          symbols.push(symbol);
        }
      }
    }
    definitions.push(`    LayoutDefinition([${symbols.join(", ")}]),`);
  }
  await writeRelative(
    root,
    DEFAULT_LAYOUT_BOUNDARY_CONFIG.compositionPath,
    `${imports.join("\n")}

final definitions = <LayoutDefinition>[
${definitions.join("\n")}
];
`,
  );
}

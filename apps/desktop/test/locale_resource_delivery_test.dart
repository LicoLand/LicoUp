import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:licoup/app.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/locale/locale_resource_pack.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// The claim the locale resolvers make: the interface strings the client renders
/// come from the language resources installed on this client, not from the table
/// compiled into the binary.
///
/// The resources here are real documents on disk in the client's own data
/// directory, read through the production catalogue service, published through
/// the production projection and rendered by the production application widget.
void main() {
  late Directory dataRoot;

  setUp(() {
    dataRoot = Directory.systemTemp.createTempSync('licoup-locale-resource-');
  });

  tearDown(() {
    if (dataRoot.existsSync()) dataRoot.deleteSync(recursive: true);
  });

  Future<void> install(String fileName, Map<String, Object?> document) async {
    final directory = Directory(
      p.join(dataRoot.path, 'client-state', 'locale-resources'),
    );
    await directory.create(recursive: true);
    await File(
      p.join(directory.path, fileName),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(document));
  }

  testWidgets('an installed language resource is what the app renders', (
    tester,
  ) async {
    // Installing writes real files and reading them is real I/O, so both run
    // outside the widget tester's fake clock.
    await tester.runAsync(() async {
      await install('zh.json', {
        'format': languageResourceFormat,
        'id': 'org.licoland.test.language.zh',
        'locale': 'zh-CN',
        'strings': {'agentHub': '智能体中心（已安装资源）'},
      });
      await install('en.json', {
        'format': languageResourceFormat,
        'id': 'org.licoland.test.language.en',
        'locale': 'en',
        'strings': {'agentHub': 'Agent Hub (installed resource)'},
      });
    });

    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: dataRoot),
    );
    final composition = ClientAppComposition(controller: controller);

    final loaded = (await tester.runAsync(
      controller.loadInstalledLocaleResources,
    ))!;
    expect(
      loaded.errors,
      isEmpty,
      reason: 'both installed documents are usable language resources',
    );
    // Load order is the installed file order, which is the precedence a later
    // resource has over an earlier one for the same key.
    expect(loaded.packs.map((pack) => pack.locale), ['en', 'zh']);

    controller.localePreference = 'zh';
    await tester.pumpWidget(
      LicoApp(
        compositionFactory: () => composition,
        initializeController: false,
        homeBuilder: (_, _, _) => Builder(
          builder: (context) => Text(
            LicoStrings.of(context).agentHub,
            key: const Key('agentHub'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('智能体中心（已安装资源）'), findsOneWidget);
    expect(
      find.text('智能体中心'),
      findsNothing,
      reason: 'the compiled string must not be what renders',
    );

    // Switching the language renders the other installed resource, again
    // instead of the compiled string.
    controller.localePreference = 'en';
    await tester.pump();

    expect(find.text('Agent Hub (installed resource)'), findsOneWidget);
    expect(
      find.text('Agent Hub'),
      findsNothing,
      reason: 'the compiled string must not be what renders',
    );

    await tester.runAsync(composition.dispose);
    controller.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a first launch renders the compiled baseline for every key', (
    tester,
  ) async {
    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: dataRoot),
    );
    final composition = ClientAppComposition(controller: controller);

    final loaded = (await tester.runAsync(
      controller.loadInstalledLocaleResources,
    ))!;
    expect(loaded.packs, isEmpty);
    expect(
      controller.localeResourceDirectoryPath,
      isNotEmpty,
      reason: 'the install location exists even when nothing is installed',
    );

    controller.localePreference = 'en';
    await tester.pumpWidget(
      LicoApp(
        compositionFactory: () => composition,
        initializeController: false,
        homeBuilder: (_, _, _) => Builder(
          builder: (context) => Text(
            LicoStrings.of(context).agentHub,
            key: const Key('agentHub'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Agent Hub'), findsOneWidget);

    await tester.runAsync(composition.dispose);
    controller.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}

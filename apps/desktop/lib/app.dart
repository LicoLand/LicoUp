import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/controllers/future_client_controller.dart';
import 'src/l10n/lico_strings.dart';
import 'src/ui/appearance_preset_config.dart';
import 'src/ui/client_shell.dart';
import 'src/ui/theme.dart';

class LicoApp extends StatefulWidget {
  const LicoApp({super.key});

  @override
  State<LicoApp> createState() => _LicoAppState();
}

class _LicoAppState extends State<LicoApp> {
  late final FutureClientController _controller;

  @override
  void initState() {
    super.initState();
    _controller = FutureClientController();
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final presetId = _controller.appearancePresetId;
        final presets = _controller.appearancePresetConfigs;
        return MaterialApp(
          onGenerateTitle: (context) => LicoStrings.of(context).appTitle,
          debugShowCheckedModeBanner: false,
          supportedLocales: LicoStrings.supportedLocales,
          localeListResolutionCallback: (locales, supportedLocales) {
            return LicoStrings.resolvePreferred(locales);
          },
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          themeMode: themeModeForAppearance(presetId, presets),
          theme: buildLicoTheme(
            presetId: presetId,
            presets: presets,
            platformBrightness: Brightness.light,
          ),
          darkTheme: buildLicoTheme(
            presetId: presetId,
            presets: presets,
            platformBrightness: Brightness.dark,
          ),
          home: ClientShell(controller: _controller),
        );
      },
    );
  }
}

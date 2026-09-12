import 'package:flutter/services.dart';

/// Production fonts for synthetic visual acceptance. Tests never read system
/// fonts or download assets, so the same scene renders on every host.
Future<void> loadBundledVisualFonts() async {
  for (final entry in const <String, List<String>>{
    'Geist Sans': [
      'assets/fonts/GeistSans-Regular.ttf',
      'assets/fonts/GeistSans-Medium.ttf',
      'assets/fonts/GeistSans-SemiBold.ttf',
      'assets/fonts/GeistSans-Bold.ttf',
    ],
    'Geist Mono': [
      'assets/fonts/GeistMono-Regular.ttf',
      'assets/fonts/GeistMono-Medium.ttf',
    ],
    'Noto Sans SC': ['assets/fonts/NotoSansSC.ttf'],
    'MaterialIcons': ['fonts/MaterialIcons-Regular.otf'],
  }.entries) {
    final loader = FontLoader(entry.key);
    for (final path in entry.value) {
      loader.addFont(rootBundle.load(path));
    }
    await loader.load();
  }
}

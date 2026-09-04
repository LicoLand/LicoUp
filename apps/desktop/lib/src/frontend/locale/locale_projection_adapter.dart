import 'dart:ui';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

Locale? localeFromProjection(LocaleProjection projection) =>
    LicoStrings.localeForPreference(projection.preference);

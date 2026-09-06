import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';

/// Owns the locale preference and its sole change signal.
final class LocalePreferenceOwner extends ApplicationStateOwner {
  LocalePreferenceOwner({String preference = LocalePreference.system})
    : _preference = LocalePreference.normalize(preference);

  String _preference;

  String get preference => _preference;

  bool replace(String value, {ApplicationCause? cause}) {
    final normalized = LocalePreference.normalize(value);
    if (_preference == normalized) return false;
    _preference = normalized;
    publishChange(cause);
    return true;
  }
}

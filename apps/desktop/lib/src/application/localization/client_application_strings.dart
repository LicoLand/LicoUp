import 'package:licoup/src/contracts/generated/client_error.g.dart';
import 'package:licoup/src/shared/l10n/lico_strings_catalog.dart';

/// Compatibility adapter over the single custom [LicoStrings] catalog.
///
/// It owns no localized values. Existing orchestration dependents can migrate
/// independently without keeping a second strings table alive.
@Deprecated('Use LicoStrings from shared/l10n/lico_strings_catalog.dart.')
final class ClientApplicationStrings {
  const ClientApplicationStrings._(this._strings);

  factory ClientApplicationStrings.forPreference(String preference) =>
      ClientApplicationStrings._(LicoStrings.forPreference(preference));

  final LicoStrings _strings;

  bool get isChinese => _strings.isChinese;
  String get defaultLabel => _strings.defaultLabel;
  String get defaultPolicy => _strings.defaultPolicy;
  String get notConfigured => _strings.notConfigured;
  String get newConversation => _strings.newConversation;
  String get directory => _strings.directory;

  String conversationClientError(ClientError error) =>
      _strings.conversationClientError(error);

  String statusCaptionLabel(String value) => _strings.statusCaptionLabel(value);
}

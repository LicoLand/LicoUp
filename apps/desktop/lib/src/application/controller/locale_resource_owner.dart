import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/locale/locale_resource_pack.dart';

/// Owns the language resources installed on this client.
///
/// The owner holds what was actually read from the data directory: a first
/// launch installs nothing, so the interface renders the compiled baseline until
/// a resource is present.
final class LocaleResourceOwner extends ApplicationStateOwner {
  LocaleResourceOwner();

  List<LocaleResourcePack> _packs = const <LocaleResourcePack>[];
  String _directoryPath = '';
  List<String> _loadErrors = const <String>[];

  /// Installed resources in load order; a later pack wins a repeated key.
  List<LocaleResourcePack> get packs => _packs;

  /// Where the client reads installed language resources from.
  String get directoryPath => _directoryPath;

  /// Stable codes for documents that were installed but unusable.
  List<String> get loadErrors => _loadErrors;

  bool applyInstalled({
    required Iterable<LocaleResourcePack> packs,
    required String directoryPath,
    Iterable<String> errorCodes = const <String>[],
    ApplicationCause? cause,
  }) {
    final next = List<LocaleResourcePack>.unmodifiable(packs);
    final errors = List<String>.unmodifiable(
      errorCodes.map(_safeCode).where((code) => code.isNotEmpty),
    );
    if (_samePacks(_packs, next) &&
        _directoryPath == directoryPath &&
        _sameCodes(_loadErrors, errors)) {
      return false;
    }
    _packs = next;
    _directoryPath = directoryPath;
    _loadErrors = errors;
    publishChange(cause);
    return true;
  }

  /// Installs nothing, which is the state a first launch and a failed read
  /// share: the interface keeps rendering the compiled baseline.
  bool clear({ApplicationCause? cause}) => applyInstalled(
    packs: const <LocaleResourcePack>[],
    directoryPath: '',
    cause: cause,
  );

  static bool _samePacks(
    List<LocaleResourcePack> left,
    List<LocaleResourcePack> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static bool _sameCodes(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static final RegExp _stableCode = RegExp(
    r'^[a-z][a-z0-9]*(?:[._:-][a-z0-9]+)*$',
  );

  static String _safeCode(String value) {
    final normalized = value.trim().toLowerCase();
    return _stableCode.hasMatch(normalized) ? normalized : '';
  }
}

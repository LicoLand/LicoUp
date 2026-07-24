import 'package:licoup/src/contracts/mobile_home_layout.dart';

class MobileHomeLayoutService {
  const MobileHomeLayoutService({required MobileHomeLayoutStore store})
    : _store = store;

  final MobileHomeLayoutStore _store;

  Future<MobileHomeLayout> load(Object portableData) async {
    try {
      final json = await _store.read(portableData);
      if (json is! Map) {
        return MobileHomeLayout.defaults();
      }
      return MobileHomeLayout.fromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      return MobileHomeLayout.defaults();
    }
  }

  Future<void> save(Object portableData, MobileHomeLayout layout) async {
    await _store.write(portableData, layout.toJson());
  }
}

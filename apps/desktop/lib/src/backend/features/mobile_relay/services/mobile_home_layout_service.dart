import 'package:licoup/src/contracts/mobile_home_layout.dart';

class MobileHomeLayoutService {
  const MobileHomeLayoutService({required MobileHomeLayoutStore store})
    : _store = store;

  final MobileHomeLayoutStore _store;

  Future<MobileHomeLayout> load(Object portableData) async {
    final json = await _store.read(portableData);
    if (json == null) {
      return MobileHomeLayout.defaults();
    }
    if (json is! Map) throw const FormatException('mobile_home_layout_invalid');
    return MobileHomeLayout.fromJson(Map<String, dynamic>.from(json));
  }

  Future<void> save(Object portableData, MobileHomeLayout layout) async {
    await _store.write(portableData, layout.toJson());
  }
}

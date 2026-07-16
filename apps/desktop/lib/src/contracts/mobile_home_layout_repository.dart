import 'package:flutter_client/src/contracts/mobile_home_layout.dart';

abstract interface class MobileHomeLayoutRepository {
  Future<MobileHomeLayout> load();
  Future<void> save(MobileHomeLayout layout);
}

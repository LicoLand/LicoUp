import 'package:flutter_client/src/backend/features/mobile_relay/services/mobile_home_layout_service.dart';
import 'package:flutter_client/src/contracts/mobile_home_layout.dart';
import 'package:flutter_client/src/contracts/mobile_home_layout_repository.dart';

final class MobileHomeLayoutRepositoryAdapter
    implements MobileHomeLayoutRepository {
  const MobileHomeLayoutRepositoryAdapter({
    required MobileHomeLayoutService service,
    required Object portableData,
  }) : _service = service,
       _portableData = portableData;

  final MobileHomeLayoutService _service;
  final Object _portableData;

  @override
  Future<MobileHomeLayout> load() => _service.load(_portableData);

  @override
  Future<void> save(MobileHomeLayout layout) =>
      _service.save(_portableData, layout);
}

import 'package:licoup/src/contracts/devices/devices_notice_repository.dart';
import 'package:licoup/src/platform/storage/client_json_document_store.dart';

/// File-backed acknowledgement of the one-time legacy pairing notice
/// (`devices-notice.json` under the client state directory).
final class PlatformDevicesNoticeStore implements DevicesNoticeRepository {
  const PlatformDevicesNoticeStore({
    required Object portableData,
    ClientJsonDocumentStore jsonStore = const ClientJsonDocumentStore(),
  }) : _portableData = portableData,
       _jsonStore = jsonStore;

  static const _fileName = 'devices-notice.json';

  final Object _portableData;
  final ClientJsonDocumentStore _jsonStore;

  @override
  Future<bool> readLegacyPairingNoticeAcknowledged() async {
    final decoded = await _jsonStore.readCurrent(_portableData, _fileName);
    if (decoded == null) return false;
    if (decoded is! Map || decoded['schemaVersion'] != 1) {
      throw const FormatException('devices_notice_document_invalid');
    }
    return decoded['legacyPairingNoticeAcknowledged'] == true;
  }

  @override
  Future<void> writeLegacyPairingNoticeAcknowledged() => _jsonStore.write(
    _portableData,
    _fileName,
    const {'schemaVersion': 1, 'legacyPairingNoticeAcknowledged': true},
    lock: true,
  );
}

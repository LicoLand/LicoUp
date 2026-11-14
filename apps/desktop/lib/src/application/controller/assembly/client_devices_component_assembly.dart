import 'package:licoup/src/application/features/devices/devices_controller.dart';
import 'package:licoup/src/backend/features/devices/devices_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/devices/devices_notice_repository.dart';
import 'package:licoup/src/platform/client_clipboard_service.dart';
import 'package:licoup/src/platform/devices/devices_notice_store.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

final class ClientDevicesComponentAssembly {
  ClientDevicesComponentAssembly({
    required PortableDataRoot portableData,
    required AgentCommandRunner runner,
    required ClientClipboardService clientClipboardService,
    DevicesNoticeRepository? noticeRepository,
  }) : controller = DevicesController(
         service: DevicesService(runner: runner),
         noticeRepository:
             noticeRepository ??
             PlatformDevicesNoticeStore(portableData: portableData),
         writeClipboard: (text) async {
           try {
             await clientClipboardService.writeText(text);
             return true;
           } on Object {
             return false;
           }
         },
       );

  final DevicesController controller;

  void dispose() => controller.dispose();
}

import 'package:flutter/services.dart';

class ClientClipboardService {
  const ClientClipboardService();

  Future<String> readText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text?.trim() ?? '';
  }

  Future<void> writeText(String text) {
    return Clipboard.setData(ClipboardData(text: text.trim()));
  }
}

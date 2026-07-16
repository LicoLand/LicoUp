import 'package:flutter/services.dart';

class ClientClipboardService {
  const ClientClipboardService();

  Future<void> writeText(String text) {
    return Clipboard.setData(ClipboardData(text: text.trim()));
  }
}

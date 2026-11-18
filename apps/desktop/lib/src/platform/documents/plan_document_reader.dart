import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/contracts/plan_document_reader.dart';

export 'package:licoup/src/contracts/plan_document_reader.dart';

final class LocalPlanDocumentReader implements PlanDocumentReader {
  const LocalPlanDocumentReader({this.maxBytes = 1024 * 1024});

  final int maxBytes;

  @override
  Future<String> read(String path) async {
    final candidate = path.trim();
    if (candidate.isEmpty) return '';
    final file = File(candidate);
    if (!await file.exists()) return '';
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size > maxBytes) {
      throw const FormatException('plan_document_invalid');
    }
    final handle = await file.open();
    try {
      return utf8.decode(
        await handle.read(maxBytes + 1),
        allowMalformed: false,
      );
    } finally {
      await handle.close();
    }
  }
}

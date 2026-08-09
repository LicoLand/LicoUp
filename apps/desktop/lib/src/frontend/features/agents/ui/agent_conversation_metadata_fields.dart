import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Reasonable rendering of consolidated metadata: `key: value` lines become
/// aligned key/value rows instead of a raw text dump. Lines without a `key:`
/// separator (for example a free-form note) render full width.
class ConversationMetadataFields extends StatelessWidget {
  const ConversationMetadataFields({
    super.key,
    required this.data,
    this.foreground,
  });

  final String data;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final foreground = this.foreground ?? colors.text;
    final rows = parseConversationMetadataFields(data);
    if (rows.isEmpty) {
      return Text(
        data,
        style: TextStyle(color: foreground, fontSize: 11.5),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < rows.length; index += 1) ...[
          if (index > 0) const SizedBox(height: 4),
          _MetadataRow(
            label: rows[index].key,
            value: rows[index].value,
            keyColor: colors.textMuted,
            valueColor: foreground,
          ),
        ],
      ],
    );
  }
}

final class _MetadataRow extends StatelessWidget {
  const _MetadataRow({
    required this.label,
    required this.value,
    required this.keyColor,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color keyColor;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            '$label:',
            style: TextStyle(
              color: keyColor,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.04,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

({String key, String value}) _splitMetadataLine(String line) {
  final separator = line.indexOf(': ');
  if (separator <= 0) {
    return (key: '', value: line.trim());
  }
  return (
    key: line.substring(0, separator).trim(),
    value: line.substring(separator + 2).trim(),
  );
}

List<({String key, String value})> parseConversationMetadataFields(String data) {
  final rows = <({String key, String value})>[];
  for (final line in data.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final parsed = _splitMetadataLine(trimmed);
    if (parsed.key.isEmpty) {
      // A free-form line keeps its own row spanning both columns.
      rows.add((key: '', value: parsed.value));
    } else {
      rows.add(parsed);
    }
  }
  return rows;
}

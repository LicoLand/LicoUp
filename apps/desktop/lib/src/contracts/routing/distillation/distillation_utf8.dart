import 'dart:convert';

String truncateDistillationUtf8(String value, int maxBytes) {
  if (utf8.encode(value).length <= maxBytes) {
    return value;
  }
  final buffer = StringBuffer();
  var used = 0;
  for (final rune in value.runes) {
    final fragment = String.fromCharCode(rune);
    final size = utf8.encode(fragment).length;
    if (used + size > maxBytes) {
      break;
    }
    buffer.write(fragment);
    used += size;
  }
  return buffer.toString();
}

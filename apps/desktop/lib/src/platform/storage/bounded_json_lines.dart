/// Bounded retention for one append-only JSON-lines file.
///
/// [current] is the file's existing bytes and [incoming] the encoded line about
/// to be appended. The result keeps the newest complete lines and never exceeds
/// [maxBytes]. A line is only cut when [incoming] alone is already at or above
/// the bound, in which case the newest bytes of that line are retained.
///
/// Both local bounded logs under the client's data root share this rule: they
/// serve diagnosis after a long session, so the newest samples are the ones
/// worth keeping.
List<int> retainJsonLinesTail(
  List<int> current,
  List<int> incoming,
  int maxBytes,
) {
  if (incoming.length >= maxBytes) {
    return incoming.sublist(incoming.length - maxBytes);
  }
  final combined = <int>[...current, ...incoming];
  if (combined.length <= maxBytes) {
    return combined;
  }
  final overflow = combined.length - maxBytes;
  var start = overflow;
  while (start < combined.length && combined[start] != 10) {
    start += 1;
  }
  if (start < combined.length && combined[start] == 10) {
    start += 1;
  }
  return combined.sublist(start);
}

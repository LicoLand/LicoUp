/// Tri-state motion preference: follows the operating system by default and
/// can be forced on or off. Persisted as `system`/`on`/`off`; documents saved
/// by the boolean schema read `true` as [on] and `false` as [system].
enum ReduceMotionPreference {
  system,
  on,
  off;

  static ReduceMotionPreference parse(Object? raw) {
    if (raw is bool) {
      return raw ? ReduceMotionPreference.on : ReduceMotionPreference.system;
    }
    if (raw is String) {
      for (final value in values) {
        if (value.name == raw) return value;
      }
    }
    return ReduceMotionPreference.system;
  }
}

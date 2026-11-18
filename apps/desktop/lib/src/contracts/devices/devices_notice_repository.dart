/// Durable record that the user has seen the one-time "pair your devices
/// again" notice shown when pre-0.3.0 pairings exist.
abstract interface class DevicesNoticeRepository {
  /// Whether the notice was acknowledged. Throws [FormatException] when the
  /// stored record exists but cannot be read, so the caller can keep the
  /// acknowledgement in memory without replacing the unreadable record.
  Future<bool> readLegacyPairingNoticeAcknowledged();

  Future<void> writeLegacyPairingNoticeAcknowledged();
}

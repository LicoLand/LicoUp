import { requireValue, text } from "./util.mjs";

export function assertAcceptancePrivacy(value) {
  if (Array.isArray(value)) {
    value.forEach(assertAcceptancePrivacy);
    return;
  }
  if (value && typeof value === "object") {
    for (const [key, nested] of Object.entries(value)) {
      requireValue(![
        "stdout",
        "stderr",
        "rawLog",
        "deviceSerial",
        "deviceModel",
        "signingIdentity",
        "keyMaterial",
      ].includes(key) &&
        !/(?:(?:signer|certificate|team).*(?:digest|sha(?:256)?|fingerprint)|(?:digest|sha(?:256)?|fingerprint).*(?:signer|certificate|team))/iu.test(key),
      "client release report contains a forbidden privacy field");
      assertAcceptancePrivacy(nested);
    }
    return;
  }
  if (typeof value === "string") {
    requireValue(!/(?:^|["'\s])\/(?:Users|home|private|tmp|var\/folders)\//u.test(value) &&
      !/-----BEGIN [A-Z ]*PRIVATE KEY-----/u.test(value) &&
      !/Bearer\s+(?!\[redacted\])\S+/u.test(value),
    "client release report contains a forbidden privacy value");
  }
}

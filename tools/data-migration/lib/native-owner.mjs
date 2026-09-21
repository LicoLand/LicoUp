// The boundary between the independent tool and transitions only the client's
// own owner can perform.
//
// Some domains are not "JSON files this tool rewrites". Their published format
// is produced by a writer whose move carries typed semantics the tool does not
// have — the canonical conversation store imports legacy projections through
// the Conversation owner, and the strategy store canonicalizes workflow
// documents through the workflow compiler. Fabricating the result would make
// the tool's claim ("converted") false in exactly the way fixtures must not:
// a version row with no shape behind it.
//
// The refusal is a first-class outcome, not a failure: the native startup
// admission runs the owner's move on the same root, under its own lock, and
// the ledger this tool writes stays a valid input for it. Callers report the
// domain as pending native admission, the way the custody domain is reported
// as pending authorization.

export const NATIVE_ADMISSION_REQUIRED = "migration_requires_native_admission";

export function nativeAdmissionRequired(domainId, detail) {
  const suffix = detail ? ` ${detail}` : "";
  const error = new Error(
    `${NATIVE_ADMISSION_REQUIRED}: ${domainId} must be converted by the native owner${suffix}`,
  );
  error.code = NATIVE_ADMISSION_REQUIRED;
  return error;
}

export function isNativeAdmissionRequired(error) {
  return Boolean(error) && error.code === NATIVE_ADMISSION_REQUIRED;
}

/**
 * A downgrade no published receiver can be shown to read, or that would drop
 * data the older shape cannot express.
 *
 * This is deliberately *not* the same code as a native deferral: a forward step
 * the owner can finish is reported as pending, while an unsupported downgrade
 * has no executor anywhere. The caller must treat it as a refusal, and the tool
 * must have written nothing before raising it.
 */
export const UNSUPPORTED_DOWNGRADE = "migration_unsupported_downgrade";

export function unsupportedDowngrade(domainId, detail) {
  const suffix = detail ? ` ${detail}` : "";
  const error = new Error(
    `${UNSUPPORTED_DOWNGRADE}: ${domainId} cannot be downgraded truthfully by this tool${suffix}`,
  );
  error.code = UNSUPPORTED_DOWNGRADE;
  return error;
}

export function isUnsupportedDowngrade(error) {
  return Boolean(error) && error.code === UNSUPPORTED_DOWNGRADE;
}

export const MAINTENANCE_CONFIRMATION_REQUIRED = "maintenance_confirmation_required";

/**
 * The tool's lock excludes other runs of this tool; it cannot constrain a
 * program that never heard of it, and the plan is explicit that a new lock file
 * does not prove an old writer stopped. A real conversion therefore requires
 * the operator's statement that every writer (including older clients) is
 * stopped. `inspect` and `--dry-run` stay read-only and need no confirmation.
 */
export function maintenanceConfirmationRequired(operation) {
  const error = new Error(
    `${MAINTENANCE_CONFIRMATION_REQUIRED}: ${operation} writes to the data root; ` +
      "stop every client and older writer first, then confirm with --writers-stopped " +
      "(or writersStopped: true). Use plan/inspect or --dry-run to preview without writing.",
  );
  error.code = MAINTENANCE_CONFIRMATION_REQUIRED;
  return error;
}

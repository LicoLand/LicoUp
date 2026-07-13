# Windows Fresh Evidence

- Current target authority has no complete independent x64 and arm64 builder, verifier, receipt and publication closure.
- Windows bundle verification and boundary tests provide a structural baseline, but no current Windows host build, PE inspection, signed installer, clean-machine launch, update continuity or physical/native authorization flow was run.
- Shared file replacement can misclassify rename failures, move the destination first, and follow a concurrently created symlink in its copy fallback. Skill install/rollback and journal paths add containment and crash-recovery gaps that affect Windows state integrity too.
- Secrets are no longer observed in adapter CLI arguments, but real DPAPI/Windows Hello authorization, deletion and hostile process/log scans remain unverified.
- Windows remains mandatory for the broad product-line security claim even when unselected for a narrower release.


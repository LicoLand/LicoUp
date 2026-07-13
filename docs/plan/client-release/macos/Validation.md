# macOS Validation

1. Validate the target catalog rejects wrong architecture, app-bundle/ZIP substitution, unknown identity and digest mismatch.
2. Build from a clean checkout; inspect the ZIP, app, main executable and embedded native CLI; bind all digests to one manifest and source revision.
3. Run LocalAuthentication/Keychain integration cases for one-flow success, denial, cancellation, unavailable interaction, background access, expiry, delete and memory-only fallback. Prove no ordinary-store path reports protected availability.
4. Run the canonical quality gate and macOS packaging/acceptance self-tests, then install and launch in isolated state with no source-tree dependency.
5. Through an authorized protected environment, sign, notarize, staple, publish and download the same digest; verify trust and update/rollback continuity.
6. Run the final privacy scan after the last receipt producer. The child reducer records the parent architecture Node, required shared Nodes, target tuple, source revision and artifact digest.

REQ-MAC-001 is proven by steps 1–2; REQ-MAC-002 by step 3; REQ-MAC-004 by step 4; REQ-MAC-003 by step 5. Missing external authority keeps only the affected criterion pending.


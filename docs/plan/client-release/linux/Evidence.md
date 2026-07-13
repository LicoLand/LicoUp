# Linux Fresh Evidence

- Acceptance consumes a direct distribution archive while receipt configuration consumes a VM archive. The producer and acceptance also disagree on the manifest filename, and identity configuration is coupled to a VM-specific key id.
- The current release authority declares only a subset of Linux target tuples; other glibc/musl and architecture combinations have no complete builder/verifier/receipt path.
- The selected Linux arm64 target remains blocked by preview Secure Mesh pairwise support.
- Local release Cargo, native smoke and configured VM helpers provide useful bounded baselines, but no clean target publication, real publisher identity, user-channel download, update continuity or real Secret Service session was observed.
- No current source-bound five-node topology receipt exists; historical validation-only signatures and VM runs are not accepted.


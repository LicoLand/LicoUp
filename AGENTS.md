# Agent Instructions

1. Use parallel subagents for independent migration or verification work when it
   materially reduces main-thread context pressure.
2. Do not disclose local machine information, personal data, secrets, tokens, or
   backend runtime data. Use placeholders in docs and examples.
3. Refactors must complete the full migration in one pass. Do not leave old
   implementations, compatibility shims, or parallel legacy paths behind.
4. For algorithm and data-structure work, compare established open-source
   designs, choose efficient data structures, reduce repeated computation,
   optimize scheduling and concurrency, and keep memory overhead low.

This repository is the private official client product layer. Public gateway
fabric work belongs in `LicoLite/LicoLite` unless the task explicitly changes
the official client.

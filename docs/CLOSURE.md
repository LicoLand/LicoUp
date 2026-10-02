# Change closure

Updated: 2026-10-02

Finish the approved implementation, production wiring, source review, and focused
checks before final delivery. After all writers have stopped, run:

```bash
npm run client:gate:verify -- --base origin/nightly --head HEAD --target delivery
```

This is the canonical closure entry for every development change. It executes all
applicable registered checks before the existing owners build, install, and open the
client. A failed, blocked, missing, or incomplete result exits nonzero and prevents
dependent delivery stages. The entry does not publish, sign, notarize, activate real
data, inspect the interface, or perform live Agent acceptance.

If the entry or an authorized observation fails, first establish whether required
coverage was missing or the product was wrong. Repair an actual workflow omission
through its existing subcheck and wiring, then repair the affected product. When the
workflow is correct, fix the product directly. Run the owning focused step, reuse
still-valid evidence, and return to the same closure entry. Stop after successful
delivery; do not repeat unchanged work or add unrelated governance.

A pull request that changes the delivery tooling itself runs the same engineering
profile with `--target pr` and does not install a client missing the integrated product
candidate. Once that tooling is integrated with the complete product candidate, that candidate
uses the delivery target above.

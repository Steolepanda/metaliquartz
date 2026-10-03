# Evidence pages

One page per verification event: commit, machine, scope, exact commands, results, and explicitly
what was **not** checked. See `../../docs/verification/README.md` for the evidence classes, the
template and the reporting rules.

| Date | Page | Class | Scope |
| --- | --- | --- | --- |
| 2026-10-03 | `2026-10-03-public-source-package.md` | automated | Public source ZIP, privacy audit and extracted-tree checks |
| 2026-09-25 | `2026-09-25-reorganization.md` | automated | Documentation tree build-out and its own audit |
| 2026-09-25 | `2026-09-25-docs-checker-proof.md` | automated | Proof that `Scripts/verify-docs` reports every failure class |

Rules, repeated because they are easy to get wrong:

- Never claim a result you did not observe; quote the command and its output.
- A blocked check is not a pass. Name the blocker and what the check would have covered.
- One page per event; a later run gets a later page.
- Keep `../CURRENT_STATE.md`'s verification snapshot in step with the newest pages.

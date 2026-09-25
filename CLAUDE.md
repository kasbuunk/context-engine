# context-engine

`SPEC.md` is the source of truth: model, schema, invariants, CLI surface and
milestones. Read it in full before writing code.

- Build one milestone at a time (M0 → M3). Stop when its "done when" check
  passes and show the result; don't start the next milestone unprompted.
- No implementation language is prescribed. Don't assume Go; pick one and say why.
- Anything the spec lists as out of scope stays out until M2 passes.
- Development happens in the `mage context-engine` container (see `.mage/`).
  SQLite there is 3.40 (Debian bookworm).

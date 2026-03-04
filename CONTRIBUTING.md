# Contributing to Bondi

## Development Setup

```bash
opam install . --deps-only --with-test
dune build
dune test
```

## Coding Principles

These principles govern every contribution. Listed in priority order.

### I. Separation of Concerns

Bondi uses the interpreter pattern: logic is split into a pure planning
phase and a thin impure execution phase. Both the CLI and server follow
the same gather/plan/interpret sandwich:

1. **Gather** (impure): Read current state (running containers, Docker version, etc.)
2. **Plan** (pure): Produce an `action list` from config + context
3. **Interpret** (impure): Execute the action list against Docker or SSH

**Three libraries with clear boundaries:**

- `bondi_common` — Shared types and utilities. No I/O.
- `bondi_client` — CLI commands. Reads `bondi.yaml`, SSHes to servers,
  calls server API.
- `bondi_server` — HTTP handlers + Docker Engine client. Manages
  containers, Traefik, and cron jobs.

A module is acceptable when it is:
- Self-contained with explicit, minimal dependencies
- Independently testable
- Documented with `(** ... *)` doc comments at every public value

### II. Test-First

All implementation follows strict TDD:
1. Write tests defining the intended behaviour
2. Confirm tests fail (`dune test` output required as evidence)
3. Write the minimum implementation to make them pass
4. Refactor under green

**Test types:**
- **Alcotest unit tests** — Pure plan functions tested with plain data,
  no mocking required. Located in `test/client/`, `test/server/`,
  `test/common/`.
- **Cram tests** — Shell-session snapshots for CLI behaviour. Located in
  `test/cram/`. Must be updated when CLI output changes.
- **Hurl tests** — HTTP integration tests against a running server.
  Located in `hurl_tests/`.

### III. Simplicity Gate

Keep the public API surface minimal. Each module exposes a focused interface
via its `.mli` file. Additional public modules require documented
justification.

### IV. Reversible by Default

Prefer approaches that are easy to change. The deploy strategy is
isolated in `strategy/simple.ml` — adding a new strategy (e.g.,
blue-green) means adding a new module, not modifying the existing one.

### V. Functional Patterns

**Immutable by Default**
All records are immutable unless mutation is explicitly justified.
`mutable` fields require a comment: `(* mutable: justified because ... *)`.

**Errors as Values**
Never `raise` for expected failure cases. All fallible public functions
return `('a, error) result`.

**Pattern Matching Over Conditionals**
Exhaustive `match` on variants. Never use catch-all `_` where the compiler
can enforce exhaustiveness.

**Interpreter Pattern (Gather, Plan, Interpret)**

No business logic may live in the interpret phase. If you find
yourself adding `if/then` logic to an interpreter, it belongs in the
plan phase instead.

**Composition Over Inheritance**
Use modules, functors, and first-class modules for polymorphism.
No class hierarchies.

### VI. No Inline Helpers

Helper functions belong in dedicated modules with tests and `.mli` files,
never inline in unrelated modules.

### VII. Quality Gate

Every commit must pass:
```bash
just    # build + test + fmt + lint
```

## Commit Style

Conventional Commits: `type: description`
Types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`, `perf`

Examples:
- `feat: add blue-green deployment strategy`
- `test: add cram tests for deploy argument validation`
- `fix: handle missing registry credentials in deploy payload`
- `refactor: extract SSH helpers into docker_common module`

# Decision: Controlled LLM-Assisted Development

## Decision

Allow large language models to assist with planning, code exploration,
implementation, refactoring, testing, documentation, and review in this fork.
Treat model output as untrusted engineering work: inspect changes, verify
claims against repository evidence, and run tests proportionate to risk before
committing or releasing them.

Disclose this policy prominently and distinguish it from the original Zine
project's contribution policy.

## Date And Status

- Date: 2026-08-20
- Status: accepted
- Owners: fork maintainers

## Context

This repository is intentionally an LLM-assisted fork. The development model
has enabled substantial parser, dependency, validation, and documentation work,
but model-generated changes can contain plausible-looking API mistakes,
unsupported assumptions, incomplete edge cases, or inaccurate completion
claims.

A blanket prohibition would conflict with the fork's purpose. Unrestricted use
without disclosure or validation would make the code difficult to trust.

## Options Considered

- Follow the original project's prohibition on LLM-assisted contributions.
- Allow LLM output without a repository-specific disclosure or verification
  policy.
- Permit and disclose LLM assistance while requiring evidence, review, and
  proportionate validation.

## Consequences

- The README identifies the repository as an LLM-assisted fork and links to
  original Zine.
- Human and AI-assisted contributors follow the same committed workflow,
  documentation, safety, and validation rules.
- A model's assertion that work passes, is compatible, or is complete is not
  evidence; commands, tests, diffs, source inspection, or primary references
  must support it.
- Important incorrect model assumptions belong in `docs/ops-memory/` when
  recording them will prevent recurrence.
- AI assistance does not grant permission for destructive, external, release,
  or upstream actions beyond the user's request.
- Work proposed to original Zine must comply with that project's current rules
  independently of this fork's policy.

## Evidence And Verification

- Public disclosure and attribution: `README.md`
- Agent workflow and shared-memory requirements: `AGENTS.md`
- Fork disclosure commit: `c738360`
- Shared engineering memory commit: `1e69926`

For each change, choose verification based on its risk. Typical project gates
include:

```sh
./build.sh check
./build.sh test
./build.sh test-workflows
./build.sh check-release-targets -Dpreview=true
```

Documentation-only changes should at minimum be inspected and pass
`git diff --check`.

## Revisit When

Revisit when the fork adopts a formal contribution or review policy, when its
release process changes, or when recurring model failure modes justify a more
specific mandatory gate.

## Search Keywords

LLM, AI-assisted development, Codex, disclosure, verification, review,
evidence, upstream contribution policy, untrusted output

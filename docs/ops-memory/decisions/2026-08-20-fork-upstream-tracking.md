# Decision: Fork And Upstream Branch Tracking

## Decision

Use `main` as the authoritative branch of the LLM-assisted fork. Configure
`origin` for `alogic0/zine-llm` and `upstream` for `kristoff-it/zine`.

Fetch original-project changes from `upstream/main` and integrate them into the
fork deliberately. Do not preserve a second local `main` that merely mirrors
upstream, and do not push fork history to the upstream repository.

## Date And Status

- Date: 2026-08-20
- Status: accepted
- Owners: fork maintainers

## Context

The fork has its own README, LLM-assisted development policy, Zig toolchain,
vendored dependencies, pure-Zig Markdown implementation, and image metadata
parser. Keeping local `main` identical to upstream would make the default
branch misrepresent the fork and force normal fork work onto a permanent
feature branch.

Remote names provide a clearer boundary: `origin` is where this fork is
published, while `upstream` is the source from which original Zine changes are
reviewed.

## Options Considered

- Keep local `main` synchronized exactly with original Zine and develop the
  fork indefinitely on another branch.
- Make `main` authoritative for the fork and track original Zine with an
  `upstream` remote.

## Consequences

- Fork releases and documentation come from `main` and `origin/main`.
- Upstream updates may require conflict resolution because this fork diverges
  intentionally.
- Integration of `upstream/main` must be reviewed like any other meaningful
  change and validated against the fork's test and release gates.
- Any contribution proposed to original Zine is separate work and must comply
  with that project's current contribution policy.
- Git remotes are local configuration; new clones must configure them with the
  same roles.

## Evidence And Verification

- Fork identity and upstream link: `README.md`
- Expected configuration:

  ```text
  origin    git@github.com:alogic0/zine-llm.git
  upstream  git@github.com:kristoff-it/zine.git
  ```

- Inspect before synchronizing:

  ```sh
  git remote -v
  git branch -vv
  git fetch upstream
  git log --oneline --left-right main...upstream/main
  ```

## Revisit When

Revisit if the fork is retired, renamed, or changes to a patch queue that is
intended to remain mechanically replayable on upstream.

## Search Keywords

fork, upstream, origin, main, upstream/main, origin/main, zine-llm,
kristoff-it/zine, synchronization, merge conflict

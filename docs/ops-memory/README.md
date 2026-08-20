# Engineering Operational Memory

This folder is durable, searchable engineering memory for this Zine fork. It
is stored in git so human and AI-assisted contributors can reuse important
context across branches and sessions.

It is not a work log, changelog, issue tracker, or substitute for stable
documentation.

## Search First

Before repeating a substantial investigation or revisiting a familiar
architecture, compatibility, build, release, or upstream-sync question, search:

```sh
rg -n "keyword|error|component|dependency" docs/ops-memory docs/plans docs
```

Use concrete terms such as an error fragment, Zig version, dependency name,
source path, build step, target triple, or upstream project.

## Structure

| Folder | Use |
| --- | --- |
| `decisions/` | Consequential architecture, compatibility, dependency, process, or release choices |
| `incidents/` | Significant release/build regressions and post-fix reviews |
| `learnings/` | Reusable investigation, debugging, implementation, or upstream-sync lessons |

Add another category only after multiple durable notes demonstrate a need for
it. In particular, operational commands should stay in validation/reference
documentation until there is a genuine collection of runbook knowledge.

## When To Write A Note

Add or update a note when at least one of these is true:

- A problem took meaningful investigation and is likely to recur.
- A failure has occurred more than once.
- A consequential choice constrains future implementation or compatibility.
- A release-blocking regression revealed a reusable guard or verification step.
- An upstream synchronization conflict established a reusable resolution.
- An LLM or contributor made an assumption that future work should explicitly
  avoid.

Do not add a note merely because work was completed. Routine implementation,
ordinary one-off bugs, commit summaries, and temporary investigation state do
not belong here.

## Naming

Use a date-prefixed, searchable filename:

```text
YYYY-MM-DD-short-topic.md
```

Examples:

```text
2026-08-20-upstream-main-tracking.md
2026-08-20-zig-module-serialization-workaround.md
2026-08-20-release-target-archive-regression.md
```

## What To Include

Keep entries concise and evidence-based. Include whichever details make the
note reusable:

- the decision, symptom, or lesson first;
- relevant Zig and dependency versions;
- exact error text or a short representative fragment;
- affected source paths, build steps, targets, or commits;
- the verified resolution or chosen approach;
- verification commands;
- links to plans, stable documentation, upstream issues, or commits;
- conditions under which the note should be revisited.

Prefer a summary and link over copied logs or duplicated documentation.

## Prohibited Content

Do not record:

- secrets, tokens, passwords, credentials, or private keys;
- personal or otherwise private data;
- lengthy raw logs, generated artifacts, or cache contents;
- speculative conclusions presented as facts;
- temporary chat summaries or agent scratch notes.

## Relationship To Other Documentation

| Information | Location |
| --- | --- |
| Proposed or unfinished work | `docs/plans/` |
| Stable commands and supported behavior | Relevant reference or validation document in `docs/` |
| Why a durable choice was made | `docs/ops-memory/decisions/` |
| Reusable debugging or implementation knowledge | `docs/ops-memory/learnings/` |
| Significant release/build failure and prevention | `docs/ops-memory/incidents/` |
| Required agent behavior | `AGENTS.md` |

When a learning becomes stable project behavior, promote it into the relevant
reference or validation document and leave a short link from the memory note.

## Templates

- Decisions: `docs/templates/decision-note.md`
- Incidents: `docs/templates/incident-note.md`
- Learnings: `docs/templates/learning-note.md`

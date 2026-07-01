______________________________________________________________________

## name: init-project description: Set up a new project-agent workspace mode: interactive disable-model-invocation: true

Write the project's **charter** — the `AGENTS.md` that will be prepended into every future agent session here. Grill the user until the charter is clear, then write it.

Ask one question at a time. Recommend an answer; wait for theirs before continuing.

## Phase 1: Charter

Grill until every item below has a specific, non-generic answer:

1. What is this project and what problem does it solve?
1. Tech stack — languages, frameworks, key tools
1. Domain language — terms an agent must know to avoid confusion
1. Conventions — commit style, code style, test approach, PR norms
1. Constraints — what must an agent never do here?

**Clear**: every answer is concrete. "We use TypeScript with strict mode" is clear. "We write clean code" is not — push until it is.

## Phase 2: Knowledge base

Ask what reference material agents in this project should always be able to reach:

- Existing files (architecture docs, API specs, domain glossaries)
- Files the user intends to create

Record each as `<path>: <one-line purpose>`.

**Complete**: the user says there is nothing else, or gives no answer.

## Phase 3: Recurring skills

Ask whether any tasks repeat on a schedule or frequently enough to automate. For each: what does it do, how often, what does it produce?

Skip this phase if the user has none.

## Write

### `AGENTS.md`

```markdown
# <project name>

<2–3 sentences: what the project is and who uses it>

## Tech stack

<bullets>

## Domain language

<key terms and definitions>

## Conventions

<commit style, code style, tests, PRs>

## Constraints

<what agents must never do>

<!-- agent:docs:start -->
<!-- agent:docs:end -->
```

Populate the `<!-- agent:docs -->` block with links to each file from Phase 2.

### Skill stubs

For each recurring skill from Phase 3, write `.agent/skills/<slug>/SKILL.md`:

```yaml
---
name: <name>
description: <one-line>
mode: batch
schedule: "<cron>"
---

<draft prompt based on what the user described — note it needs review>
```

Tell the user exactly which files were written and which need fleshing out before use.

### Artifact registration

For any output file you create that should appear in the project home screen (docs, reports, specs), append an entry to `.agent/outputs.json`:

```json
[
  {"path": "relative/path/to/file.md", "title": "Human-readable title", "timestamp": "2026-07-01T09:00:00Z"}
]
```

If the file already exists, replace the entry for that path. The timestamp is the current UTC time in ISO 8601 format.

# Phase progression rules

Earshot is built in phases (see `docs/phases/`). This rule file governs how Claude Code handles transitions between phases.

## Just-in-time phase docs

Detailed phase docs are written **as each phase begins**, not all at once. This ensures each phase plan reflects learnings from previous phases.

At project start, only Phase 0 and Phase 1 have detailed docs. Phases 2 through 10 are described at a high level in `docs/phases/README.md`.

## When a phase completes

When Michael indicates a phase is complete (or when Claude Code believes it is based on the Definition of Done), Claude Code must:

1. **Verify completion.** Walk through the Definition of Done checklist in the current phase doc. Report which items are done, which are partially done, and which are not done.

2. **Capture learnings.** Briefly summarize:
   - What was built
   - What we learned about the codebase, tooling, or process
   - What we deferred to a future phase and why
   - Any new dependencies, conventions, or architectural decisions made

3. **Update the CHANGELOG.** Add a "Phase N complete" entry under `[Unreleased]` summarizing user-visible additions.

4. **Wait for confirmation** that the phase is actually done before writing the next phase doc. Don't assume.

5. **Write the next phase doc.** Create `docs/phases/phase-{N+1}-{name}.md` following the exact structure of previous phase docs:
   - **Goal** (one sentence)
   - **Estimated duration**
   - **Prerequisites** (if any, beyond previous phase outputs)
   - **Tasks** (numbered, with checkboxes)
   - **Definition of done** (verifiable bullet list)
   - **Commands to use during this phase** (shell commands)
   - **Claude Code prompts for this phase** (3-5 ready-to-paste prompts)

6. **Stop and ask for confirmation** before starting the new phase. Don't begin coding work for Phase N+1 until Michael says go.

## Phase doc naming convention

`docs/phases/phase-{N}-{short-kebab-name}.md`

Examples:
- `phase-0-setup.md`
- `phase-1-data-model.md`
- `phase-2-playback-engine.md`
- `phase-3-accessibility-quick-actions.md`

The short name should match the high-level description in `docs/phases/README.md`. Keep it concise.

## Phase doc structure (template)

```markdown
# Phase N: {Title}

**Goal:** {One sentence describing what's true at the end of the phase.}

**Estimated duration:** {weeks, part-time}

## Prerequisites
{Anything beyond previous phase outputs that must exist.}

## Tasks
### 1. {Task name}
- [ ] Sub-step
- [ ] Sub-step

### 2. {Task name}
...

## Definition of done
- {Verifiable bullet}
- {Verifiable bullet}

## Commands to use during this phase
```bash
flutter ...
```

## Claude Code prompts for this phase

**Prompt 1: {goal}**
```
{full prompt}
```
```

## High-level phase reminders (until detailed doc is written)

While waiting to write a phase's detailed doc, Claude Code should treat the bullets in `docs/phases/README.md` for that phase as the working scope. Don't expand scope beyond what's there without explicit confirmation.

## When NOT to write the next phase doc

- When Michael says he wants to revise the high-level plan first
- When the current phase has significant deferred work that may belong in the next phase
- When new information (user feedback, technical discovery) suggests reordering phases

In those cases, propose the change first and wait for direction.

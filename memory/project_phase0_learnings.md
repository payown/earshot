---
name: Phase 0 deferred items and tooling notes
description: What was deferred from Phase 0 and non-obvious tooling decisions made during setup
type: project
---

VoiceOver manual test on WelcomeScreen was skipped in Phase 0. Should be verified in Phase 1 alongside the first real UI screens.

**Why:** Time constraint, moving to Phase 1. The widget test confirms the semantic header flag is set correctly; manual VoiceOver just verifies the announced experience.

**How to apply:** Add VoiceOver test note to the Phase 1 PR checklist for the subscriptions screens. Don't forget to test WelcomeScreen too.

---

CocoaPods must be installed via `brew install cocoapods`, not `sudo gem install cocoapods`. macOS system Ruby (2.6) is too old for the current ffi gem that CocoaPods depends on.

---

Community Access accessibility agents install as Claude Code hooks in `~/.claude/hooks/` and plugins in `~/.claude/plugins/`, not as agent `.md` files in `~/.claude/agents/`. The CLAUDE.md reference to `ls ~/.claude/agents/` as a verification step is incorrect for the current installer. The hooks fire correctly on every prompt.

---

GitHub repo is at `https://github.com/payown/earshot` (org is `payown`, not `payownmedia` as the PRD states).

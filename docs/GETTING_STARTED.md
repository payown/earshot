# Getting Started with Earshot Development

This guide walks you through everything you need to do today to start building Earshot.

You already have **Homebrew** and **Claude Code** installed. We just need to add the rest.

## Step 1: Install the remaining prerequisites

### Flutter
```bash
brew install --cask flutter
```

### CocoaPods (for iOS builds)
```bash
sudo gem install cocoapods
```

### Xcode and Android Studio
- **Xcode:** install from the App Store (this is a large download, several GB, plan accordingly)
- **Android Studio:** `brew install --cask android-studio`

After Android Studio installs, open it once to complete the SDK setup wizard.

### Verify everything
```bash
flutter doctor
```

Resolve any issues it reports before continuing. Common ones:
- "Xcode license not accepted" → `sudo xcodebuild -license accept`
- "CocoaPods not installed" → re-run the `sudo gem install cocoapods` step
- "Android SDK component is missing" → open Android Studio and let it install missing components
- "Android licenses not accepted" → `flutter doctor --android-licenses`

## Step 2: Install the Accessibility Agents

Earshot is built with the [Community Access](https://community-access.org) accessibility agents. They enforce WCAG 2.2 AA compliance inside Claude Code automatically. This is a perfect fit for Earshot because the agents are built by and for the blind and low vision community.

### Install
```bash
curl -fsSL https://raw.githubusercontent.com/Community-Access/accessibility-agents/main/install.sh | bash
```

The installer is safe and additive. It will not overwrite existing files.

### What you get
The install adds 57 accessibility agents, 17 shared skills, and 54 ready-to-use prompts across:

- **Web Accessibility** (17 agents): ARIA, contrast, keyboard, forms, headings, links, modals, mobile, cognitive
- **Document Accessibility** (9 agents): Word, Excel, PowerPoint, PDF, EPUB, Markdown
- **Markdown Accessibility** (3 agents): scanner and fixer for `.md` files
- **GitHub Workflow** (11 agents): PR review, issue triage, templates
- **Developer Tools** (7 agents): Python, wxPython, desktop a11y, NVDA addon work

The **Markdown Scanner** and **Markdown Fixer** run automatically on `.md` files. The **PR Review** agent checks accessibility on every pull request.

For Earshot's Flutter work, the most relevant agents are:
- **Mobile Accessibility** (touch targets, screen reader patterns)
- **Cognitive Accessibility** (reading level, error prevention)
- **Markdown Scanner / Fixer** (keeps your docs accessible)
- **PR Review** (catches issues before merge)
- **Accessibility Lead** (orchestrates full audits)

### Verify
After installation, check that the agents are loaded:

```bash
ls ~/.claude/agents/
```

You should see a long list of `.md` files. If they're not there, re-run the install with the `--global` flag:

```bash
curl -fsSL https://raw.githubusercontent.com/Community-Access/accessibility-agents/main/install.sh | bash -s -- --global
```

## Step 3: Set up the repository

Three options for where to put the starter pack:

### Option A: Use this starter pack (recommended)
You already have the `earshot/` folder. Move it where you want to keep the project, then:

```bash
cd earshot
git init
git add .
git commit -m "chore: initial project setup"
```

### Option B: Create the GitHub repo first
1. Create `payownmedia/earshot` on GitHub (public, no template)
2. Clone it locally
3. Copy the starter files into the clone
4. Commit and push

### Option C: Fresh Flutter project
If you want a clean Flutter scaffold and copy our docs and rules into it:

```bash
flutter create --org media.payown --project-name earshot --platforms ios,android earshot
cd earshot
# Then copy CLAUDE.md, .claude/, docs/, README.md, CONTRIBUTING.md, etc. from this starter pack
```

## Step 4: Start Claude Code in the project

From the project root:

```bash
claude
```

On first run, Claude Code reads:
- `CLAUDE.md` (project context)
- `.claude/rules/*.md` (modular rules)
- The Accessibility Agents you installed in Step 2

## Step 5: Begin Phase 0

Your first session with Claude Code kicks off Phase 0. Use this prompt:

```
Read docs/PRD.md and docs/phases/phase-0-setup.md. We're starting Phase 0 today. Walk me through the tasks one at a time. Confirm with me before making changes, especially anything that touches the iOS or Android platform configuration. Let's begin with task 2: creating the Flutter project scaffold.
```

Claude Code will then propose the next step, and you confirm before it acts.

## Step 6: How phase progression works

Earshot uses a **just-in-time phase doc** system. Detailed phase docs exist for Phase 0 and Phase 1 today. As each phase completes, Claude Code writes the next phase's detailed doc based on what you learned in the previous phase.

When a phase wraps up, use this prompt:

```
We just finished Phase N. Review what we built, what we learned, and what we deferred. Then write docs/phases/phase-{N+1}-{name}.md following the same structure as the previous phase docs. Include detailed tasks, definition of done, commands to use, and Claude Code prompts to run. Wait for me to confirm before starting Phase N+1.
```

This rule lives in `.claude/rules/phase-progression.md`. Claude Code will follow it automatically.

## Step 7: Establish a working rhythm

A good development rhythm with Claude Code:

1. **Start of session:** "Read CLAUDE.md and the current phase doc. What are we working on?"
2. **Plan first:** "Before writing code, outline what you're about to change."
3. **Confirm before commits:** "Show me the diff before committing."
4. **End of session:** "Summarize what we changed today. Update CHANGELOG.md."
5. **End of phase:** "Phase complete. Write the next phase doc."

## Step 8: Pace yourself

This is a solo, part-time project building a polished accessible app. Realistic timelines:

- **Phase 0:** 1-2 weeks
- **Phase 1:** 2-3 weeks
- **Phases 2-7:** 2-3 weeks each
- **Phase 8 (private alpha):** 6-8 weeks
- **Phase 9 (public beta):** 4-6 weeks
- **Phase 10 (launch):** 2-4 weeks

Total v1: realistically 6-9 months part-time. Don't try to compress this. Quality and accessibility take time.

## Helpful Claude Code commands

- `/help` — list commands
- `/memory` — view what Claude Code remembers
- `/clear` — clear context for a fresh start (use sparingly)
- `/compact` — compact context when getting full
- `/doctor` — check Claude Code health

## Useful Accessibility Agent prompts

Once the agents are installed, you can invoke them by name in Claude Code:

```
Use the Markdown Scanner to audit docs/PRD.md and report any accessibility issues.
```

```
Use the Mobile Accessibility agent to review the Quick Actions implementation in lib/features/.
```

```
Use the PR Review agent on this branch before I open a PR.
```

```
Use the Accessibility Lead to run a full audit of the subscriptions feature.
```

## When you get stuck

- **Build errors:** ask Claude Code to read the error and propose a fix
- **Flutter quirks:** Claude Code knows current Flutter best practices
- **Accessibility uncertainty:** invoke the relevant Accessibility Agent
- **Architecture decisions:** open an ADR in `docs/adr/` and capture the reasoning

## What to do this week

1. Run through Step 1 (Flutter, CocoaPods, Xcode, Android Studio)
2. Run `flutter doctor` and resolve any issues
3. Install the Accessibility Agents (Step 2)
4. Get the repo set up locally and pushed to GitHub (Step 3)
5. Start Claude Code (Step 4) and complete Phase 0 task 2 (Flutter scaffold)
6. Get a "Welcome to Earshot" screen running on the iOS simulator
7. Commit and push, watch CI run for the first time

That's a great first week. Don't rush past it.

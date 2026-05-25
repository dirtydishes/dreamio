# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

> **Architecture in one line:** Issues live in a local Dolt database
> (`.beads/dolt/`); cross-machine sync uses `bd dolt push/pull` (a
> git-compatible protocol), stored under `refs/dolt/data` on your git
> remote — separate from `refs/heads/*` where your code lives.
> `.beads/issues.jsonl` is a passive export, not the wire protocol.
>
> See [SYNC_CONCEPTS.md](https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md)
> for the one-screen overview and anti-patterns (don't treat JSONL as the
> source of truth; don't `bd import` during normal operation; don't
> reach for third-party Dolt hosting before trying the default).

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->

## Required Turn Documentation

At the end of every completed implementation task, before final handoff, create a user-readable HTML document describing the work.

This documentation is mandatory whenever code, configuration, tests, or project files were changed.

### Precedence and classification

Use this decision order before creating a turn document:

1. Check the minor/trivial exemption checklist below first.
2. If the task clearly matches an exemption, do not create a turn document.
3. If the task is a clearly substantive implementation change, create a turn document.
4. If classification is ambiguous or mixed, ask the user before creating a turn document.

The minor/trivial exemptions override the general mandatory turn-document rule.

For diff content in turn documentation (including "Code diffs" and "Relevant Diff Snippets"), use `@pierre/diffs` output by default. If `@pierre/diffs` is unavailable because of a real tool or blocking error, use a clearly labeled plain diff/code block fallback and note why.

### No turn document for minor/trivial checklist matches

Do not create a turn document when the change is minor/trivial and cleanly matches one of these categories:

- `AGENTS.md` changes or other documentation-only changes
- Syntax-only fixes
- Refactor-only changes with no behavior change
- PR/conflict reconciliation work
- Issue-tracker-only updates such as `beads/issues.json`
- Support-file changes that only accompany one of the exempt categories above (for example lockfile or manifest updates required for docs-workflow changes)

If a change does not cleanly fit either exempt or substantive buckets, ask the user before creating a turn document.

### When making a minor update to a previous change, update the existing documentation instead of creating a new file. Use the following format:

**"New Changes as of {time and date at which the change was made}"**
- **Summary of changes**
- **Why this change was made**
- **Code diffs** (use `@pierre/diffs` output by default; if unavailable, include a clearly labeled plain diff/code block and note why)
- **Related issues or PRs**

Additionally, add a note to each section explaining why the changes were made.

### Location

Save the document in:

```text
docs/turns/
```

Use a clear timestamped filename:

```text
docs/turns/YYYY-MM-DD-short-task-name.html
```

Example:

```text
docs/turns/2026-05-14-add-market-replay-controls.html
```

### Format

Use the `impeccable` skill to structure and style the document as clean, readable HTML.

For this repository, `impeccable` is the styling and layout authority for turn documents when available. Do not apply global non-repo computer-task house styling to repository turn documents.

If the `impeccable` skill is unavailable or blocked by an actual tool/file error, still create a well-structured standalone HTML file with:

- A concise summary at the top
- A detailed explanation of what changed
- Relevant context or background
- Specific code snippets or examples when helpful
- Issues, limitations, tradeoffs, or mitigations
- Validation performed, including tests, builds, linters, or manual checks
- Any remaining follow-up work, with corresponding Beads issue IDs when applicable

### Required Sections

Each turn document must include these sections:

1. **Summary**
2. **Changes Made**
3. **Context**
4. **Important Implementation Details**
5. **Relevant Diff Snippets** (render with `@pierre/diffs` output by default; if unavailable, include a clearly labeled plain diff/code block and note why)
6. **Expected Impact for End-Users**
7. **Validation**
8. **Issues, Limitations, and Mitigations**
9. **Follow-up Work**

### Completion Rule

A task that requires a turn document is not complete until:

1. The Beads workflow is updated
2. The turn document is created in `docs/turns`
3. Relevant quality gates have passed or failures are documented
4. Changes are committed
5. `bd dolt push` succeeds
6. `git push forgejo <branch>` succeeds
7. `git status` shows the branch is up to date with `forgejo/<branch>`

For tasks that do require turn documentation, the document may be brief when scope is small, but it must clearly explain what changed and how it was validated.

## Plan Mode Documentation

When working in plan mode, do not modify implementation files.

At the end of plan mode, provide a concise summary of the plan and ask the user whether they want to proceed with implementation.

If the user asks to save the plan, create a user-readable HTML plan document in:

```text
docs/plans/
```

Use a clear timestamped filename:

```text
docs/plans/YYYY-MM-DD-short-plan-name.html
```

The plan document should be labeled clearly as a plan and should include:

1. **Plan Summary**
2. **Goals**
3. **Proposed Changes**
4. **Relevant Context**
5. **Implementation Steps**
6. **Risks, Limitations, and Mitigations**
7. **Open Questions**

Always do the following when you finish a task, finish the beads workflow and and make a commit:
- Document the changes in a user-readable format
- Use the impeccable skill to structure the document as HTML 
- Create a clear, concise summary of the changes at the top, followed by a detailed description of the changes, including any relevant context or background as well as specific code snippets or examples.
- Note any relevant issues or limitations that were addressed or mitigated by the changes.
- The HTML file should be stored in the `docs/turns` directory. It should include the current date and time, as well as a brief explanation of changes. e.g. docs/turns/YYYY-MM-DD-{description}.html


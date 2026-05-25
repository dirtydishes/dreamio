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

At the end of repository work, use this decision flow:

1. **Classify the task.**
   - If the change is minor/trivial under the exemption list below, do not create a turn document.
   - If the task changed code, configuration, tests, project files, or substantive docs inside the repo, create or update a turn document.
   - If classification is ambiguous or mixed, ask the user before creating a turn document.
2. **Document substantive implementation work.**
   - New work: create `docs/turns/YYYY-MM-DD-short-task-name.html`.
   - Minor update to a previous substantive change: update that existing turn document instead of creating a duplicate.
3. **Complete the closeout for documented work.**
   - Update Beads.
   - Run relevant quality gates, or document any failures.
   - Commit changes.
   - Run `bd dolt push`.
   - Run `git push`.
   - Confirm `git status` shows the branch is up to date with `forgejo/<branch>`.

The minor/trivial exemptions override the general turn-document rule.

### Minor/Trivial Exemptions

Do not create a turn document when the change cleanly matches one of these categories:

- `AGENTS.md` changes or other documentation-only changes
- Syntax-only fixes
- Refactor-only changes with no behavior change
- PR/conflict reconciliation work
- Issue-tracker-only updates such as `beads/issues.json`
- Support-file changes that only accompany one of the exempt categories above, such as lockfile or manifest updates required for docs-workflow changes

If a change does not cleanly fit either exempt or substantive buckets, ask the user before creating a turn document.

### Turn Document Requirements

Use the `impeccable` skill to structure and style the document as clean, readable HTML. For this repository, `impeccable` is the styling and layout authority for turn documents when available. Do not apply global non-repo computer-task house styling to repository turn documents.

If `impeccable` is unavailable or blocked by an actual tool/file error, still create a well-structured standalone HTML file.

Each turn document must include these sections:

1. **Summary**
2. **Changes Made**
3. **Context**
4. **Important Implementation Details**
5. **Relevant Diff Snippets** (follow the **Rendered Diff Documentation** rule)
6. **Expected Impact for End-Users**
7. **Validation**
8. **Issues, Limitations, and Mitigations**
9. **Follow-up Work**

For a minor update to a previous substantive change, add this section to the existing document:

**"New Changes as of {time and date at which the change was made}"**
- **Summary of changes**
- **Why this change was made**
- **Code diffs** (follow the **Rendered Diff Documentation** rule)
- **Related issues or PRs**

### Rendered Diff Documentation

When turn documentation needs rendered code diffs, use `@pierre/diffs` through its ESM server-side renderer.

Use `@pierre/diffs/ssr` with Node ESM imports. Do not test, load, or diagnose this package with CommonJS `require()`, because `@pierre/diffs` is ESM and `require('@pierre/diffs/ssr')` can falsely look like an export or package failure.

Preferred availability check:

```bash
node --input-type=module -e "import { preloadPatchDiff } from '@pierre/diffs/ssr'; console.log(typeof preloadPatchDiff)"
```

Preferred rendering pattern:

```bash
node --input-type=module <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';
import { preloadPatchDiff } from '@pierre/diffs/ssr';

const patch = readFileSync('/tmp/change.patch', 'utf8');
const { prerenderedHTML } = await preloadPatchDiff({
  patch,
  options: { diffType: 'unified' }
});

writeFileSync('/tmp/rendered-diff.html', prerenderedHTML);
NODE
```

`preloadPatchDiff` expects exactly one file diff per call. If a git diff contains multiple files, split it into one patch per file, render each file patch separately, and concatenate the rendered HTML into the turn document.

Do not run `npx @pierre/diffs`; the package is a rendering library and does not expose a CLI executable.

Only use a clearly labeled plain diff or code-block fallback when the ESM import-and-render pattern above fails because of a real tool, install, or runtime error. Document the failure briefly in the turn document.

## Plan Mode Documentation

When working in plan mode, do not modify implementation files.

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

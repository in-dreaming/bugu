---
name: codex-task-orchestrator
description: Run a reusable, resumable sequence of Markdown implementation tasks with GPT-5.6 Terra implementing, GPT-5.6 Sol reviewing, and Terra fixing review findings until each task passes. Use when Codex needs to execute setup.md plus ordered TASK-*.md files, persist every prompt/event/result for incremental continuation, or serve a local task-progress dashboard.
---

# Codex Task Orchestrator

Use the bundled Node.js scripts. They require only Node 20+ and an authenticated `codex` CLI.

## Run tasks

From the target repository:

```powershell
node .agents/skills/codex-task-orchestrator/scripts/orchestrate.mjs run --repo . --setup docs/tasksv2/setup.md --tasks "docs/tasksv2/TASK-*.md" --run-id porffor-v2
```

The same command resumes an interrupted run. Use a stable `--run-id`; do not delete run data while
agents are active.

Useful controls:

```text
--from TASK-006
--only TASK-006,TASK-007
--max-cycles 5
--terra-model gpt-5.6-terra
--sol-model gpt-5.6-sol
--dry-run
--no-commit
```

Default runtime data is `.agents/task-orchestrator/runs/<run-id>/`. Inspect
`references/config-and-state.md` when changing models, schemas, sandbox policy, or integrating CI.

## Monitor

```text
node .agents/skills/codex-task-orchestrator/scripts/serve-dashboard.mjs --repo . --port 4173
```

Open `http://127.0.0.1:4173`. The server is read-only and polls persisted run state.

## Workflow guarantees

For each ordered task:

1. Give Terra the complete setup document, task document, repository path, and prior review findings.
2. Render Markdown as line-prefixed, checksummed snapshots so headings and code fences cannot escape
   their prompt boundary.
3. Persist prompts, Codex JSONL events, structured results, stage transitions, binary Git patches,
   source fingerprints, tests, acceptance evidence, and timestamps.
4. Give Sol the same specifications in `workspace-write` so it can execute tests, while rejecting any
   protected worktree mutation made during review. Ignore generated caches and untracked runner
   `.log`, `.tmp`, and `.lock` files, but continue protecting tracked files and untracked source/docs.
5. Require Sol to report every extracted `AC-NNN` criterion exactly once and return `pass`,
   `changes_required`, or `blocked`.
6. On `changes_required`, give the findings to a fresh Terra turn and repeat. A process retry resumes
   the incomplete stage without consuming another review cycle.
7. On `pass`, create one task-scoped parent-repository commit by default, then advance. Use
   `--no-commit` to disable this; the orchestrator never pushes.

Do not treat process exit alone as acceptance. The Sol verdict is the task acceptance record.
Failed, blocked, interrupted, or cycle-limited tasks are never committed.

## Safety

- Start with a clean or intentionally understood worktree.
- Keep both sandboxes at `workspace-write`; the reviewer prompt forbids source edits and before/after
  fingerprints enforce that boundary.
- Do not run two processes with the same run ID; the lock prevents accidental overlap.
- Run IDs are restricted to portable filename characters and cannot escape the data root.
- Automatic commits stage only paths absent from the task's baseline dirty set. Pre-existing staged
  changes stop automatic commit.
- A task that changes a submodule must commit inside that submodule first; the orchestrator records
  the resulting parent gitlink but never pushes either repository.
- Preserve run artifacts for audit and incremental repair.

---
name: codex-task-orchestrator
description: Run a reusable, resumable sequence of Markdown implementation tasks with GPT-5.6 Terra implementing, GPT-5.6 Sol reviewing, and Terra fixing review findings until each task passes. Use when Codex needs to execute setup.md plus ordered TASK-*.md files, persist every prompt/event/result for incremental continuation, or serve a local task-progress dashboard.
---

# Codex Task Orchestrator

Use the bundled Node.js scripts. They require only Node 20+ and an authenticated `codex` CLI.

## Run tasks

From the target repository:

```text
node .agents/skills/codex-task-orchestrator/scripts/orchestrate.mjs run \
  --repo . \
  --setup docs/tasksv2/setup.md \
  --tasks "docs/tasksv2/TASK-*.md" \
  --run-id porffor-v2
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
2. Persist the prompt, Codex JSONL events, structured final result, Git status, and timestamps.
3. Give Sol the same specifications and current repository state in read-only mode.
4. Require Sol to return `pass`, `changes_required`, or `blocked` with actionable findings.
5. On `changes_required`, give the findings to a fresh Terra turn and repeat.
6. Advance only on `pass`; stop on blocked work, process failure, or the configured cycle limit.

Do not treat process exit alone as acceptance. The Sol verdict is the task acceptance record.
The orchestrator does not commit or push changes.

## Safety

- Start with a clean or intentionally understood worktree.
- Keep the default implementer sandbox at `workspace-write` and reviewer at `read-only`.
- Do not run two processes with the same run ID; the lock prevents accidental overlap.
- Review `run.json` and task results before committing.
- Preserve run artifacts for audit and incremental repair.

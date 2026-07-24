# Configuration and persisted state

## Requirements

- Node.js 20 or newer.
- `codex` available on `PATH` and already authenticated.
- A Git repository containing one setup Markdown file and ordered task Markdown files.
- Model access for `gpt-5.6-terra` and `gpt-5.6-sol`, or explicit replacements.

## Commands

```text
orchestrate.mjs run     Create or resume a run.
orchestrate.mjs status  Print a persisted run summary.
orchestrate.mjs list    List runs under the data root.
serve-dashboard.mjs     Serve the read-only dashboard and JSON API.
```

Common `run` options:

| Option | Default | Meaning |
|---|---|---|
| `--repo` | current directory | Repository root |
| `--setup` | `docs/tasksv2/setup.md` | Setup document, relative to repo |
| `--tasks` | `docs/tasksv2/TASK-*.md` | Quoted task glob |
| `--run-id` | UTC timestamp | Stable resume identity |
| `--data-root` | `.agents/task-orchestrator/runs` | Runtime data, relative to repo |
| `--terra-model` | `gpt-5.6-terra` | Implement/fix model |
| `--sol-model` | `gpt-5.6-sol` | Review model |
| `--max-cycles` | `5` | Maximum implement/review cycles per task |
| `--from` | none | Start at an ID such as `TASK-006` |
| `--only` | none | Comma-separated task IDs |
| `--dry-run` | false | Build/resume plan without invoking Codex |

## Run layout

```text
.agents/task-orchestrator/runs/<run-id>/
  run.json
  run.log.jsonl
  lock.json
  schemas/
    implementation.schema.json
    review.schema.json
  tasks/
    TASK-001/
      task.json
      attempts/
        001/
          implement-prompt.md
          implement-events.jsonl
          implement-result.json
          implement-process.json
          review-prompt.md
          review-events.jsonl
          review-result.json
          review-process.json
```

Writes use temporary files plus rename for crash-resistant JSON state. `run.json` is the dashboard
source of truth. Detailed event streams remain append-only per attempt.

The run records SHA-256 for `setup.md` and every task. Pending task content may be refreshed on
resume, but changing `setup.md` or an already accepted task requires a new run ID so old acceptance
evidence is never silently reused.

## Structured results

Implementation result:

```text
status: completed | blocked
summary: string
changed_files: string[]
tests: [{ command, status, details }]
blockers: string[]
```

Review result:

```text
verdict: pass | changes_required | blocked
summary: string
findings: [{ severity, title, details, suggested_fix, files }]
acceptance_checks: [{ criterion, status, evidence }]
```

`pass` is the only verdict that advances to the next task. A failed subprocess, invalid/missing
structured output, `blocked`, or cycle exhaustion stops the run and preserves all evidence.

## Dashboard API

- `GET /api/runs` — summarized runs.
- `GET /api/runs/<run-id>` — full `run.json`.
- `GET /api/health` — server/data-root status.

The server does not mutate tasks or runs.

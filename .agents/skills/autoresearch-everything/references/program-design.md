# Program Design Reference

Use this reference when generating `program.md`, support skills, or subagent briefs for an autoresearch workspace.

## Required Sections for program.md

Include these sections unless the user's task clearly does not need one:

```markdown
# Autoresearch Program

## Mission
## Current Baseline
## Objective and Metric
## Workspace Contract
## Allowed Changes
## Forbidden Changes
## Setup
## Experiment Loop
## Validation and Metric Parsing
## Promotion Rule
## Failure Handling
## Research Log Format
## Search Strategy
## Optional Subagents
## Stop Conditions
```

## Mission

State the user's actual goal in one paragraph. Include enough domain context for a fresh agent to avoid rediscovery, but keep long transcripts out of `program.md`.

Good:

```markdown
Improve validation bits-per-byte for the fixed 5-minute training budget without changing dataset preparation or evaluation semantics.
```

Also good for non-ML:

```markdown
Reduce p95 request latency on the supplied benchmark while preserving API behavior and all existing tests.
```

## Objective and Metric

Prefer hard metrics:

- validation loss, `val_bpb`, accuracy, F1, latency, throughput
- failing tests fixed
- reproduction command changes from failing to passing
- static analyzer finding count
- memory peak or binary size

When no hard metric exists, define a rubric:

```markdown
Score each candidate from 0-3 on correctness, evidence coverage, simplicity, and reversibility. Promote only if total score improves and no category drops to 0.
```

## Workspace Contract

Define paths, not vibes:

```markdown
Editable:
- train.py
- experiments/*.py

Read-only:
- prepare.py
- data/
- baseline logs

Generated:
- logs/attempt-<n>.md
- artifacts/attempt-<n>/
```

If adapting upstream `karpathy/autoresearch`, keep the upstream meaning explicit:

- `prepare.py`: fixed data prep and utilities; do not modify unless the user's goal is to fork the benchmark itself.
- `train.py`: default experiment surface.
- `program.md`: research organization instructions.

## Experiment Loop

Use a tight loop:

1. Read `research_state.md` and latest logs.
2. Choose exactly one hypothesis.
3. Predict expected metric movement and failure modes.
4. Make the smallest meaningful edit.
5. Run the validation command.
6. Parse the metric.
7. Keep, revert, or mark inconclusive.
8. Append a log entry.

Avoid multi-change experiments unless the goal is specifically interaction effects.

## Promotion Rule

Examples:

```markdown
Promote if val_bpb is lower than the current best by at least 0.002 and the run completed without OOM, timeout, or evaluation changes.
```

```markdown
Promote if all regression tests pass and p95 latency improves by at least 5% across two consecutive benchmark runs.
```

Always include tie-breakers: simplicity, lower risk, less code churn, lower compute cost.

## Failure Handling

Classify failures:

- invalid: command did not run, metric missing, changed evaluation, or violated forbidden edits
- runtime failure: exception, OOM, timeout, dependency failure
- regression: metric worse or tests fail
- inconclusive: noisy result or insufficient evidence
- promoted: better result under the promotion rule

Tell the agent what to do for each class.

## Search Strategy Patterns

Choose a small number:

- Baseline tightening: first make the measurement reliable.
- Ablation: remove or isolate a suspected factor.
- Local search: tune one parameter family.
- Structural search: test architecture or algorithm changes.
- Error-driven search: prioritize failures seen in logs.
- Literature-guided search: apply ideas from supplied references.
- Adversarial review: search for ways the metric could be gamed.

## Support Skill Pattern

Use support skills when the same specialist instruction would otherwise bloat `program.md`.

Template:

```markdown
# Skill: <name>

Purpose:
Inputs:
Procedure:
Output:
Do not:
```

## Subagent Brief Pattern

Template:

```markdown
# Subagent: <role>

Mission:
Read:
May edit:
May run:
Search bias:
Output:
Non-goals:
```

Useful role set:

- `baseline-runner`: establish repeatable baseline and metric extraction.
- `hypothesis-scout`: propose independent experiment candidates.
- `executor`: run one candidate at a time and keep clean diffs.
- `critic`: reject metric gaming and invalid comparisons.
- `archivist`: summarize results and update research state.

## Research Log Format

Use a table for scanability:

```markdown
## Attempt <n>: <short name>

Hypothesis:
Change:
Command:
Metric:
Result class:
Decision:
Next:
Artifacts:
```

## Final Quality Checklist

- The first command a fresh agent should run is obvious.
- The editable boundary is explicit.
- The metric parser is specified.
- The baseline is named or the baseline-establishing command is given.
- The promotion rule cannot reward broken evaluation.
- Failure classes say whether to revert, retry, or investigate.
- Subagent briefs have different responsibilities.

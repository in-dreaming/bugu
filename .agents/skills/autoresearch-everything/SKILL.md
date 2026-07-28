---
name: autoresearch-everything
description: Generate a generalized autoresearch setup from a user's research goal, context, constraints, logs, or example investigation notes. Use when Codex should clone or update karpathy/autoresearch, design a domain-specific program.md, create supporting skills/reference notes, propose subagent roles, and scaffold an autonomous research loop with measurable objectives and experiment policy.
---

# Autoresearch Everything

## Purpose

Turn a user's goal plus available information into a runnable autoresearch workspace: upstream `karpathy/autoresearch`, a tailored `program.md`, optional local skill/reference files, and optional subagent briefs.

Use the upstream repo as the execution substrate, but generalize the `program.md` beyond nanochat when the user's domain is different. Preserve the core autoresearch idea: agents repeatedly propose small experiments, run objective checks, keep improvements, discard regressions, and maintain a research log.

## Quick Start

1. Extract the research brief:
   - Goal: what the user wants improved, discovered, explained, or optimized.
   - Evidence: logs, code, papers, benchmarks, screenshots, prior notes, constraints, and examples.
   - Objective: a measurable metric, pass/fail check, or ranked evidence standard.
   - Budget: wall time, compute, API cost, number of trials, risk tolerance.
   - Sandbox: files the agents may edit, commands they may run, and files they must not touch.

2. Bootstrap the workspace and optionally write a first `program.md`:

```bash
python scripts/bootstrap_autoresearch.py \
  --workspace ./runs/my-topic \
  --write-program \
  --goal "Improve validation bits-per-byte under the fixed time budget" \
  --metric "val_bpb, lower is better" \
  --experiment-command "uv run train.py" \
  --validation-command "uv run train.py"
```

Add `--no-pull` only when offline or when the user explicitly wants to preserve the current checkout.

3. Read `references/program-design.md` before writing the final `program.md`.

4. Generate or refine these outputs in the workspace:
   - `program.md`: the primary autonomous research instructions.
   - `skills/`: small domain-specific micro-skills only when repeated specialist knowledge is needed.
   - `subagents/`: role briefs only when parallel or adversarial review is useful.
   - `research_state.md`: compact initial state, hypotheses, metric contract, and known risks.

## Workflow

### 1. Normalize the Problem

Convert broad or messy user input into a research contract:

```markdown
Goal:
Metric:
Baseline:
Allowed edits:
Forbidden edits:
Experiment command:
Validation command:
Promotion rule:
Stop rule:
Known constraints:
```

If the objective is not directly measurable, define a proxy metric and a human-review rubric. Do not pretend subjective goals are numerical.

### 2. Mine the Inputs

Treat examples like long chat transcripts or investigation notes as raw evidence, not as templates to copy. Extract reusable structure:

- concrete observations
- commands that produced evidence
- failed hypotheses
- successful verification patterns
- recurring terms and code paths
- risk boundaries
- final decision criteria

Avoid preserving domain-specific assumptions from a specialized example unless the user's new task shares that domain.

### 3. Decide the Research Organization

Use one of these modes:

- Single-agent loop: default for small code experiments and tight budgets.
- Planner plus executor: use when experiments require careful sequencing or setup.
- Parallel scouts: use when several independent hypotheses can be tested.
- Critic/reviewer: use when false positives, benchmark leakage, or unsafe edits are likely.
- Archivist: use when many trials or long logs must be summarized.

Create subagent briefs only when they change behavior materially. Otherwise keep instructions in `program.md`.

### 4. Write `program.md`

Make `program.md` operational, not inspirational. It should tell an agent exactly how to:

- inspect the current state
- choose the next experiment
- edit only allowed files
- run setup and validation commands
- parse metrics
- compare against baseline
- revert or keep changes
- record results
- hand off remaining questions

For `karpathy/autoresearch`, remember the upstream defaults: `prepare.py` is fixed setup/utilities, `train.py` is the usual editable experiment file, and `program.md` is the agent instruction surface. When adapting to other domains, explicitly redefine the editable files and metric command.

### 5. Add Supporting Skills

Create a `skills/` directory inside the generated workspace only for compact, reusable specialist instructions, for example:

- `metric-reader.md`: how to parse domain-specific metrics from logs.
- `experiment-policy.md`: which edits are safe and comparable.
- `failure-triage.md`: how to classify OOM, timeout, flaky test, or invalid result.
- `literature-scout.md`: how to compare ideas against supplied papers.

Keep these files short. Put long evidence in `research_state.md` or separate references.

### 6. Add Subagent Briefs

Create `subagents/*.md` when useful. Each brief should include:

- role
- input files to read
- decisions it owns
- commands it may run
- output format
- non-goals

Subagents should not all optimize the same thing in the same way. Give them different search biases.

### 7. Validate the Scaffold

Before finishing:

1. Ensure upstream repo is present or document why it was not fetched.
2. Ensure `program.md` names exact commands and exact editable boundaries.
3. Ensure the metric can be read from command output or a file.
4. Ensure there is a baseline and promotion rule.
5. Ensure rollback/discard behavior is explicit.
6. Ensure generated skill/subagent files are referenced from `program.md`.

## References

Read `references/program-design.md` when designing a new `program.md` or research organization.

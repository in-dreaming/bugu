#!/usr/bin/env python3
"""Bootstrap an autoresearch workspace from karpathy/autoresearch."""

from __future__ import annotations

import argparse
import shutil
import subprocess
from pathlib import Path

UPSTREAM = "https://github.com/karpathy/autoresearch.git"


def run(cmd: list[str], cwd: Path | None = None) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, cwd=cwd, check=True)


def ensure_repo(workspace: Path, pull: bool) -> Path:
    repo = workspace / "upstream"
    if repo.exists():
        if not (repo / ".git").exists():
            raise SystemExit(f"{repo} exists but is not a git checkout")
        if pull:
            run(["git", "pull", "--ff-only"], cwd=repo)
        return repo

    workspace.mkdir(parents=True, exist_ok=True)
    run(["git", "clone", UPSTREAM, str(repo)])
    return repo


def write_if_missing(path: Path, text: str) -> None:
    if not path.exists():
        path.write_text(text, encoding="utf-8")


def render_program(args: argparse.Namespace) -> str:
    goal = args.goal or "TODO: state the research goal"
    metric = args.metric or "TODO: define the authoritative metric and whether lower or higher is better"
    experiment_command = args.experiment_command or "TODO: command to run one experiment"
    validation_command = args.validation_command or experiment_command
    editable = args.editable or ["train.py"]
    forbidden = args.forbidden or ["prepare.py", "data/"]

    def bullets(items: list[str]) -> str:
        return "\n".join(f"- {item}" for item in items)

    return f"""# Autoresearch Program

## Mission

{goal}

## Current Baseline

Before changing code, run the validation command once and record the metric in `../research_state.md`.

## Objective and Metric

Metric: {metric}

The metric must come from a completed, valid run. Reject partial runs, failed runs, and runs that change evaluation semantics.

## Workspace Contract

Editable:
{bullets(editable)}

Forbidden:
{bullets(forbidden)}

Generated artifacts:
- `../logs/attempt-<n>.md`
- `../artifacts/attempt-<n>/`

## Setup

Inspect the repository, read `../research_state.md`, then run any one-time setup required by the upstream README.

## Experiment Loop

1. Choose one hypothesis.
2. Predict expected metric movement and likely failure modes.
3. Make the smallest meaningful edit within the editable boundary.
4. Run the experiment command.
5. Run or parse the validation command.
6. Compare against the current best.
7. Keep the change only if the promotion rule is met; otherwise revert the source edit.
8. Append an attempt log and update `../research_state.md`.

Experiment command:

```bash
{experiment_command}
```

Validation command:

```bash
{validation_command}
```

## Promotion Rule

Promote only when the authoritative metric improves over the current best and the run is valid. Break ties by simpler code, lower risk, lower compute cost, and smaller diff.

## Failure Handling

- Invalid: revert and log why the result cannot be compared.
- Runtime failure: revert unless the failure teaches a narrow follow-up experiment.
- Regression: revert and record the result.
- Inconclusive: preserve notes, do not promote.
- Promoted: keep the diff and update the best metric.

## Research Log Format

For each attempt, write:

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

## Search Strategy

Start with baseline reliability, then explore one factor at a time. Prefer reversible experiments with clear metric interpretation. Avoid changing data preparation or evaluation unless the mission explicitly asks for benchmark redesign.

## Optional Subagents

Use `../subagents/critic.md` when a result looks too good, changes evaluation code, or depends on noisy measurements.

## Stop Conditions

Stop when the budget is exhausted, the metric cannot be measured reliably, the best result has plateaued across several valid attempts, or the next useful step needs human approval.
"""


def scaffold(workspace: Path, repo: Path, args: argparse.Namespace) -> None:
    write_if_missing(
        workspace / "research_state.md",
        """# Research State

Goal:
Baseline:
Best result:
Metric:
Allowed edits:
Forbidden edits:
Open hypotheses:
Known risks:

## Attempts
""",
    )

    skills = workspace / "skills"
    subagents = workspace / "subagents"
    skills.mkdir(exist_ok=True)
    subagents.mkdir(exist_ok=True)

    write_if_missing(
        skills / "metric-reader.md",
        """# Skill: metric-reader

Purpose: Parse the authoritative metric from experiment output.
Inputs: command output, log files, benchmark artifacts.
Procedure: identify the final valid metric, reject partial or failed runs, record units and direction.
Output: metric value, comparison direction, validity status, evidence path.
Do not: compare runs that changed evaluation semantics.
""",
    )

    write_if_missing(
        subagents / "critic.md",
        """# Subagent: critic

Mission: Review whether a proposed or completed experiment is valid.
Read: program.md, research_state.md, latest attempt log, relevant diff.
May edit: review notes only.
May run: validation commands that do not mutate source files.
Search bias: find metric gaming, changed evaluation, hidden regressions, and overfitting to noise.
Output: accept/reject/inconclusive with evidence.
Non-goals: propose large new experiments unless asked.
""",
    )

    program = repo / "program.md"
    if program.exists():
        backup = repo / "program.upstream.md"
        if not backup.exists():
            shutil.copy2(program, backup)
    if args.write_program:
        program.write_text(render_program(args), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", required=True, help="Workspace directory to create or update")
    parser.add_argument("--no-pull", action="store_true", help="Do not pull an existing upstream checkout")
    parser.add_argument("--write-program", action="store_true", help="Write a generated upstream/program.md scaffold")
    parser.add_argument("--goal", help="Research mission to place in generated program.md")
    parser.add_argument("--metric", help="Authoritative metric and direction")
    parser.add_argument("--experiment-command", help="Command that runs one experiment")
    parser.add_argument("--validation-command", help="Command that validates or parses the metric")
    parser.add_argument("--editable", action="append", help="Editable path; may be repeated")
    parser.add_argument("--forbidden", action="append", help="Forbidden/read-only path; may be repeated")
    args = parser.parse_args()

    workspace = Path(args.workspace).resolve()
    repo = ensure_repo(workspace, pull=not args.no_pull)
    scaffold(workspace, repo, args)
    print(f"workspace={workspace}")
    print(f"upstream={repo}")
    print("next: write upstream/program.md using the autoresearch-everything skill")


if __name__ == "__main__":
    main()

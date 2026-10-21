#!/usr/bin/env python3
"""Derived same-graph Debug test command; never an archived live_tick argv.

Without --execute, only validate identities and print the proposed command.
Execution compiles and runs once, sharing a 600-second process deadline.
No source edits, target registration, installs, cache deletion, or retries.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import time

HERE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def git(repo, *args):
    return subprocess.check_output(
        ["git", "-C", str(repo), *args], text=True,
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"}, timeout=15,
    ).strip()


def source_identity(repo):
    return {
        "head": git(repo, "rev-parse", "HEAD"),
        "tree": git(repo, "rev-parse", "HEAD^{tree}"),
        "status": git(repo, "status", "--porcelain=v1", "--untracked-files=all"),
        "diff_sha256": hashlib.sha256(git(repo, "diff", "--binary", "HEAD").encode()).hexdigest(),
    }


def derive(manifest, repo, zig, output, global_cache):
    template = HERE / manifest["template"]["file"]
    options = HERE / manifest["options"]["file"]
    assert digest(template) == manifest["template"]["sha256"], "template SHA mismatch"
    assert digest(options) == manifest["options"]["sha256"], "options SHA mismatch"
    assert digest(zig) == manifest["toolchain"]["sha256"], "Zig SHA mismatch"
    original = shlex.split(template.read_text())
    assert len(original) == manifest["template"]["argc"], "template argc mismatch"
    args = [v.replace(manifest["template"]["original_repo"], str(repo)) for v in original]
    roots = [i for i, v in enumerate(args) if v.startswith("-Mroot=")]
    assert len(roots) == 1
    assert args[roots[0]] == "-Mroot=" + str(repo / manifest["template"]["original_root"])
    args[roots[0]] = "-Mroot=" + str(repo / manifest["derived_root"])
    assert args.count("--listen=-") == 1
    args.remove("--listen=-")
    assert "--test-filter" not in args and "--test-no-exec" not in args
    assert not any(v.startswith("-femit-bin") for v in args)
    # Native -cflags include their existing -O2; do not reinterpret or alter
    # those C flags when validating the independently specified Zig modules.
    assert "-ODebug" in args and not any(v in ("-OReleaseSafe", "-OReleaseFast", "-OReleaseSmall") for v in args), "not Debug Zig modules"
    for flag, value in (
        ("--name", "legacy_filtered_compatibility"),
        ("--cache-dir", str(output / "cache-local")),
        ("--global-cache-dir", str(global_cache)),
        ("--zig-lib-dir", str(zig.parent / "lib")),
    ):
        assert args.count(flag) == 1, flag
        args[args.index(flag) + 1] = value
    option_args = [i for i, v in enumerate(args) if v.startswith("-Msme-causal-resource-options=")]
    assert len(option_args) == 1
    args[option_args[0]] = "-Msme-causal-resource-options=" + str(options)
    for value in args:
        if value.startswith("-M") and "=" in value:
            assert Path(value.split("=", 1)[1]).is_file(), "missing module: " + value
    for name in manifest["tests"]:
        args.extend(["--test-filter", name])
    executable = output / "legacy-filtered-tests"
    args.extend(["--test-no-exec", "-femit-bin=" + str(executable)])
    return [str(zig), "test", *args], [str(executable)]


def run_stage(argv, cwd, env, log, deadline, output, phase, guard):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return {"exit": None, "timed_out": True, "stop_reason": "deadline"}
    started = time.monotonic()
    with log.open("xb") as sink:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=sink,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        next_progress = 0.0
        try:
            while True:
                now = time.monotonic()
                free = shutil.disk_usage(output).free
                guard["minimum_free_bytes"] = min(guard["minimum_free_bytes"], free)
                code = process.poll()
                reason = "deadline" if now >= deadline else "disk_floor" if free < guard["running_floor_bytes"] else None
                if now >= next_progress or code is not None or reason is not None:
                    progress = {"phase": phase, "pid": process.pid,
                                "elapsed_seconds": now - guard["started"],
                                "remaining_seconds": max(0, deadline - now),
                                "free_bytes": free, "minimum_free_bytes": guard["minimum_free_bytes"],
                                "exit": code, "stop_reason": reason}
                    temporary = output / "progress.json.tmp"
                    temporary.write_text(json.dumps(progress, indent=2) + "\n")
                    temporary.replace(output / "progress.json")
                    print("LEGACY_FILTER_PROGRESS " + json.dumps(progress), flush=True)
                    next_progress = now + 5
                if reason is not None:
                    if code is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    return {"exit": process.returncode, "timed_out": reason == "deadline",
                            "stop_reason": reason, "elapsed_seconds": time.monotonic() - started}
                if code is not None:
                    return {"exit": code, "timed_out": False, "stop_reason": None,
                            "elapsed_seconds": time.monotonic() - started}
                try:
                    process.wait(timeout=min(1, deadline - now))
                except subprocess.TimeoutExpired:
                    pass
        except BaseException:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--zig", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--global-cache-dir", type=Path,
                        help="Optional shared global cache; local cache is always isolated")
    parser.add_argument("--execute", action="store_true", help="Run once, not merely print the plan")
    cli = parser.parse_args()
    manifest = json.loads((HERE / "manifest.json").read_text())
    repo, zig, output = cli.repo.resolve(), cli.zig.resolve(), cli.output_dir.resolve()
    global_cache = (cli.global_cache_dir or output / "cache-global").resolve()
    assert output != repo and repo not in output.parents, "output must be outside repo"
    assert not output.exists(), "refuse to reuse an existing result directory"
    before = source_identity(repo)
    assert before["tree"] == manifest["expected_source_tree"] and before["status"] == "", "source not frozen expected tree"
    compile_argv, run_argv = derive(manifest, repo, zig, output, global_cache)
    plan = {
        "schema": 1, "classification": "derived_same_graph_not_original_live_tick_argv",
        "cwd": str(repo), "compile_argv": compile_argv, "run_argv": run_argv,
        "timeout_seconds_total": 600, "source_before": before,
        "initial_free_floor_bytes": manifest["initial_free_floor_bytes"],
        "running_free_floor_bytes": manifest["running_free_floor_bytes"],
        "runner_sha256": digest(__file__), "manifest_sha256": digest(HERE / "manifest.json"),
        "template_sha256": digest(HERE / "argv-template.rsp"),
        "options_sha256": digest(HERE / "options.zig"), "zig_sha256": digest(zig),
        "environment_policy": "remove SME_*; explicit cache paths; TMPDIR outside repo",
    }
    if not cli.execute:
        print(json.dumps(plan, indent=2))
        return 0
    output.mkdir(parents=True, exist_ok=False)
    (output / "tmp").mkdir()
    (output / "command.json").write_text(json.dumps(plan, indent=2) + "\n")
    env = {k: v for k, v in os.environ.items() if not k.startswith("SME_")}
    env.update(ZIG_GLOBAL_CACHE_DIR=str(global_cache), TMPDIR=str(output / "tmp"))
    result = {"schema": 1, "compile": None, "tests": None, "passed": False}
    started = time.monotonic()
    deadline = started + 600
    free = shutil.disk_usage(output).free
    guard = {"started": started, "minimum_free_bytes": free,
             "running_floor_bytes": manifest["running_free_floor_bytes"]}
    result["initial_free_bytes"] = free
    try:
        if free < manifest["initial_free_floor_bytes"]:
            result["stop_reason"] = "initial_disk_floor"
        else:
            result["compile"] = run_stage(compile_argv, repo, env, output / "compile.log", deadline, output, "compile", guard)
        if result["compile"] is not None and result["compile"]["exit"] == 0 and result["compile"]["stop_reason"] is None:
            result["elf_sha256"] = digest(run_argv[0])
            result["tests"] = run_stage(run_argv, repo, env, output / "tests.log", deadline, output, "tests", guard)
            if result["tests"]["exit"] == 0 and result["tests"]["stop_reason"] is None:
                raw = (output / "tests.log").read_text(errors="replace")
                result["both_named_tests_reported"] = all(name in raw for name in manifest["tests"])
                result["exact_two_tests_passed_marker"] = "All 2 tests passed." in raw
                result["passed"] = result["both_named_tests_reported"] and result["exact_two_tests_passed_marker"]
    except BaseException as exc:
        result["exception"] = type(exc).__name__ + ": " + str(exc)
    finally:
        result["elapsed_process_seconds"] = time.monotonic() - started
        result["minimum_free_bytes"] = guard["minimum_free_bytes"]
        try:
            result["source_after"] = source_identity(repo)
            result["source_guard_equal"] = before == result["source_after"]
        except Exception as exc:
            result["source_guard_equal"] = False
            result["source_guard_error"] = str(exc)
        result["passed"] = result["passed"] and result["source_guard_equal"]
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2), flush=True)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

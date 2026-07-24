#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repo = path.resolve(process.argv[2] ?? process.cwd());
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const orchestrator = path.join(scriptDir, "orchestrate.mjs");
const dashboard = path.join(scriptDir, "serve-dashboard.mjs");
const relativeDataRoot = `.agents/task-orchestrator/smoke-${process.pid}`;
const absoluteDataRoot = path.join(repo, relativeDataRoot);
const runId = "smoke";
const port = 42000 + (process.pid % 1000);

if (!fs.existsSync(path.join(repo, ".git"))) throw new Error(`Not a Git repository: ${repo}`);
if (fs.existsSync(absoluteDataRoot)) throw new Error(`Refusing to overwrite smoke path: ${absoluteDataRoot}`);

let server;
try {
  const dryRun = spawnSync(process.execPath, [
    orchestrator,
    "run",
    "--repo", repo,
    "--setup", "docs/tasksv2/setup.md",
    "--tasks", "docs/tasksv2/TASK-*.md",
    "--run-id", runId,
    "--data-root", relativeDataRoot,
    "--only", "TASK-001",
    "--dry-run",
  ], { cwd: repo, encoding: "utf8" });
  if (dryRun.status !== 0) throw new Error(`Dry run failed:\n${dryRun.stderr}\n${dryRun.stdout}`);
  const traversal = spawnSync(process.execPath, [
    orchestrator,
    "run",
    "--repo", repo,
    "--run-id", "../escape",
    "--data-root", relativeDataRoot,
    "--dry-run",
  ], { cwd: repo, encoding: "utf8" });
  if (traversal.status === 0 || !traversal.stderr.includes("--run-id must match")) {
    throw new Error("Traversal run ID was not rejected");
  }

  server = spawn(process.execPath, [
    dashboard,
    "--repo", repo,
    "--data-root", relativeDataRoot,
    "--port", String(port),
  ], { cwd: repo, stdio: "ignore", windowsHide: true });

  await new Promise((resolve) => setTimeout(resolve, 500));
  const health = await (await fetch(`http://127.0.0.1:${port}/api/health`)).json();
  const runs = await (await fetch(`http://127.0.0.1:${port}/api/runs`)).json();
  const run = await (await fetch(`http://127.0.0.1:${port}/api/runs/${runId}`)).json();
  const html = await (await fetch(`http://127.0.0.1:${port}/`)).text();
  const result = {
    health: health.ok,
    runCount: runs.length,
    runId: run.id,
    taskCount: run.tasks.length,
    acceptanceCount: run.tasks[0].acceptanceCriteria.length,
    commitTasks: run.commitTasks,
    hasTitle: html.includes("Codex Task Orchestrator"),
  };
  if (!result.health || result.runCount !== 1 || result.runId !== runId || result.taskCount !== 1 ||
      result.acceptanceCount < 1 || result.commitTasks !== true || !result.hasTitle) {
    throw new Error(`Unexpected smoke result: ${JSON.stringify(result)}`);
  }
  console.log(JSON.stringify(result, null, 2));
} finally {
  if (server && server.exitCode === null) server.kill();
  if (fs.existsSync(absoluteDataRoot)) fs.rmSync(absoluteDataRoot, { recursive: true, force: true });
}

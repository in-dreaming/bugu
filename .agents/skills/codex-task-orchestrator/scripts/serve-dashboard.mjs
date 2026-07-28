#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import http from "node:http";
import { fileURLToPath } from "node:url";

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) throw new Error(`Unexpected argument: ${token}`);
    const key = token.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    const value = argv[++i];
    if (!value || value.startsWith("--")) throw new Error(`Missing value for ${token}`);
    out[key] = value;
  }
  return out;
}

function sendJson(response, status, value) {
  const body = Buffer.from(JSON.stringify(value, null, 2));
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": body.length,
    "cache-control": "no-store",
  });
  response.end(body);
}

function sendFile(response, file) {
  const types = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".svg": "image/svg+xml",
    ".json": "application/json; charset=utf-8",
    ".jsonl": "application/x-ndjson; charset=utf-8",
    ".md": "text/markdown; charset=utf-8",
    ".txt": "text/plain; charset=utf-8",
    ".patch": "text/plain; charset=utf-8",
  };
  const body = fs.readFileSync(file);
  response.writeHead(200, {
    "content-type": types[path.extname(file)] ?? "application/octet-stream",
    "content-length": body.length,
    "cache-control": "no-cache",
  });
  response.end(body);
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
}

function listRuns(dataRoot) {
  if (!fs.existsSync(dataRoot)) return [];
  return fs.readdirSync(dataRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && fs.existsSync(path.join(dataRoot, entry.name, "run.json")))
    .map((entry) => readJson(path.join(dataRoot, entry.name, "run.json")))
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
    .map((run) => {
      const accepted = run.tasks.filter((task) => task.status === "accepted").length;
      return {
        id: run.id,
        status: run.status,
        currentTask: run.currentTask,
        createdAt: run.createdAt,
        updatedAt: run.updatedAt,
        accepted,
        total: run.tasks.length,
        models: run.models,
        lastError: run.lastError,
      };
    });
}

const options = parseArgs(process.argv.slice(2));
const repo = path.resolve(options.repo ?? process.cwd());
const dataRoot = path.resolve(repo, options.dataRoot ?? ".agents/task-orchestrator/runs");
const port = Number(options.port ?? 4173);
const host = options.host ?? "127.0.0.1";
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid --port");
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const staticRoot = path.resolve(scriptDir, "..", "assets", "dashboard");

const server = http.createServer((request, response) => {
  try {
    const url = new URL(request.url, `http://${request.headers.host ?? `${host}:${port}`}`);
    if (request.method !== "GET") return sendJson(response, 405, { error: "method_not_allowed" });
    if (url.pathname === "/api/health") {
      return sendJson(response, 200, { ok: true, repo, dataRoot, now: new Date().toISOString() });
    }
    if (url.pathname === "/api/runs") return sendJson(response, 200, listRuns(dataRoot));
    const artifactMatch = url.pathname.match(/^\/api\/runs\/([A-Za-z0-9][A-Za-z0-9._-]{0,127})\/artifacts\/(.+)$/);
    if (artifactMatch) {
      const runRoot = path.resolve(dataRoot, artifactMatch[1]);
      const relativeArtifact = decodeURIComponent(artifactMatch[2]);
      const file = path.resolve(runRoot, relativeArtifact);
      const inside = path.relative(runRoot, file);
      if (inside.startsWith("..") || path.isAbsolute(inside)) return sendJson(response, 403, { error: "forbidden" });
      if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return sendJson(response, 404, { error: "artifact_not_found" });
      return sendFile(response, file);
    }
    const runMatch = url.pathname.match(/^\/api\/runs\/([A-Za-z0-9._-]+)$/);
    if (runMatch) {
      const file = path.join(dataRoot, runMatch[1], "run.json");
      if (!fs.existsSync(file)) return sendJson(response, 404, { error: "run_not_found" });
      return sendJson(response, 200, readJson(file));
    }
    const relative = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
    const file = path.resolve(staticRoot, relative);
    if (!file.startsWith(`${staticRoot}${path.sep}`) && file !== path.join(staticRoot, "index.html")) {
      return sendJson(response, 403, { error: "forbidden" });
    }
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return sendJson(response, 404, { error: "not_found" });
    sendFile(response, file);
  } catch (error) {
    sendJson(response, 500, { error: "server_error", message: error.message });
  }
});

server.listen(port, host, () => {
  console.log(`Task dashboard: http://${host}:${port}`);
  console.log(`Run data: ${dataRoot}`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}

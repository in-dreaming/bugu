#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const skillDir = path.resolve(scriptDir, "..");
const errors = [];
const requiredFiles = [
  "SKILL.md",
  "agents/openai.yaml",
  "scripts/orchestrate.mjs",
  "scripts/serve-dashboard.mjs",
  "scripts/smoke-test.mjs",
  "references/config-and-state.md",
  "assets/dashboard/index.html",
  "assets/dashboard/app.js",
  "assets/dashboard/styles.css",
];

for (const relative of requiredFiles) {
  if (!fs.existsSync(path.join(skillDir, relative))) errors.push(`Missing ${relative}`);
}

const skill = fs.readFileSync(path.join(skillDir, "SKILL.md"), "utf8");
const frontmatter = skill.match(/^---\r?\n([\s\S]*?)\r?\n---/);
if (!frontmatter) {
  errors.push("SKILL.md has no YAML frontmatter");
} else {
  const lines = frontmatter[1].split(/\r?\n/).filter(Boolean);
  const keys = lines.map((line) => line.match(/^([a-z_]+):/)?.[1]).filter(Boolean);
  if (keys.length !== 2 || !keys.includes("name") || !keys.includes("description")) {
    errors.push("SKILL.md frontmatter must contain only name and description");
  }
  const name = frontmatter[1].match(/^name:\s*(.+)$/m)?.[1]?.trim();
  if (name !== path.basename(skillDir)) errors.push(`Skill name '${name}' must match folder '${path.basename(skillDir)}'`);
  if (!/^[a-z0-9-]{1,64}$/.test(name ?? "")) errors.push("Skill name must be lowercase hyphen-case and <=64 chars");
}

const openai = fs.readFileSync(path.join(skillDir, "agents/openai.yaml"), "utf8");
for (const key of ["display_name", "short_description", "default_prompt"]) {
  if (!new RegExp(`^\\s*${key}:\\s*\"[^\"]+\"\\s*$`, "m").test(openai)) errors.push(`openai.yaml missing quoted ${key}`);
}
if (!openai.includes("$codex-task-orchestrator")) errors.push("default_prompt must mention $codex-task-orchestrator");

if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}
console.log(`Skill validation passed: ${skillDir}`);

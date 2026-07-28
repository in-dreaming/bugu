const runSelect = document.querySelector("#run-select");
const refreshButton = document.querySelector("#refresh");
const updated = document.querySelector("#updated");
const summary = document.querySelector("#summary");
const tasks = document.querySelector("#tasks");
const progressText = document.querySelector("#progress-text");
const progressBar = document.querySelector("#progress-bar");

let selectedRun = localStorage.getItem("codex-task-run") ?? "";

const escapeHtml = (value) => String(value ?? "")
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;");

const artifactUrl = (runId, relative) =>
  `/api/runs/${encodeURIComponent(runId)}/artifacts/${relative.split("/").map(encodeURIComponent).join("/")}`;

function statusLabel(status) {
  return {
    pending: "等待",
    implementing: "Terra 实施",
    reviewing: "Sol Review",
    committing: "提交中",
    changes_required: "待修改",
    accepted: "已验收",
    blocked: "阻塞",
    cycle_limit: "超出轮次",
    running: "运行中",
    completed: "已完成",
    failed: "失败",
    planned: "已规划",
  }[status] ?? status;
}

async function json(url) {
  const response = await fetch(url, { cache: "no-store" });
  if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
  return response.json();
}

async function loadRuns() {
  const runs = await json("/api/runs");
  if (!runs.length) {
    runSelect.innerHTML = '<option value="">暂无运行记录</option>';
    renderEmpty();
    return;
  }
  if (!runs.some((run) => run.id === selectedRun)) selectedRun = runs[0].id;
  runSelect.innerHTML = runs.map((run) =>
    `<option value="${escapeHtml(run.id)}" ${run.id === selectedRun ? "selected" : ""}>${escapeHtml(run.id)} · ${escapeHtml(statusLabel(run.status))}</option>`
  ).join("");
  await loadRun(selectedRun);
}

async function loadRun(id) {
  if (!id) return;
  const run = await json(`/api/runs/${encodeURIComponent(id)}`);
  selectedRun = id;
  localStorage.setItem("codex-task-run", id);
  const accepted = run.tasks.filter((task) => task.status === "accepted").length;
  const percent = run.tasks.length ? Math.round((accepted / run.tasks.length) * 100) : 0;
  progressText.textContent = `${accepted}/${run.tasks.length} · ${percent}%`;
  progressBar.style.width = `${percent}%`;
  summary.innerHTML = `
    <article><span>状态</span><strong class="state ${escapeHtml(run.status)}">${escapeHtml(statusLabel(run.status))}</strong></article>
    <article><span>当前任务</span><strong>${escapeHtml(run.currentTask ?? "—")}</strong></article>
    <article><span>实施模型</span><strong>${escapeHtml(run.models?.terra)}</strong></article>
    <article><span>Review 模型</span><strong>${escapeHtml(run.models?.sol)}</strong></article>
  `;
  tasks.innerHTML = run.tasks.map((task) => {
    const findings = task.lastFindings ?? [];
    const checks = task.lastReview?.acceptance_checks ?? task.acceptanceCriteria?.map((criterion) => ({
      criterion_id: criterion.id,
      criterion: criterion.text,
      status: "not_verified",
      evidence: criterion.source,
    })) ?? [];
    const tests = task.lastImplementation?.tests ?? [];
    const timeline = task.timeline ?? [];
    const artifacts = task.artifacts?.[String(task.attempts)] ?? {};
    return `
      <article class="task ${escapeHtml(task.status)}">
        <div class="task-main">
          <div>
            <span class="task-id">${escapeHtml(task.id)}</span>
            <h3>${escapeHtml(task.title)}</h3>
          </div>
          <span class="badge">${escapeHtml(statusLabel(task.status))}</span>
        </div>
        <div class="meta">
          <span>轮次 ${escapeHtml(task.attempts)}</span>
          <span>Verdict ${escapeHtml(task.verdict ?? "—")}</span>
          <span>Stage ${escapeHtml(task.stage ?? "pending")}</span>
          <span>Commit ${escapeHtml(task.commit?.sha?.slice(0, 12) ?? "—")}</span>
          <span>${escapeHtml(task.file)}</span>
        </div>
        ${checks.length ? `
          <details>
            <summary>验收项 ${checks.filter((check) => check.status === "passed").length}/${checks.length}</summary>
            <ul>${checks.map((check) => `
              <li><b>${escapeHtml(check.criterion_id)}</b> [${escapeHtml(check.status)}] ${escapeHtml(check.criterion)}
                <p>${escapeHtml(check.evidence)}</p></li>
            `).join("")}</ul>
          </details>` : ""}
        ${tests.length ? `
          <details>
            <summary>测试 ${tests.length}</summary>
            <ul>${tests.map((test) => `
              <li><b>${escapeHtml(test.status)}</b> ${escapeHtml(test.command)}<p>${escapeHtml(test.details)}</p></li>
            `).join("")}</ul>
          </details>` : ""}
        ${findings.length ? `
          <details>
            <summary>${findings.length} 个待改进点</summary>
            <ul>${findings.map((finding) => `
              <li><b>${escapeHtml(finding.severity)}</b> ${escapeHtml(finding.title)}<p>${escapeHtml(finding.suggested_fix ?? finding.details)}</p></li>
            `).join("")}</ul>
          </details>` : ""}
        ${timeline.length ? `
          <details>
            <summary>阶段时间线 ${timeline.length}</summary>
            <ul>${timeline.map((item) => `
              <li><b>${escapeHtml(item.stage)}</b> cycle ${escapeHtml(item.cycle)}
                <p>${escapeHtml(new Date(item.at).toLocaleString())}</p></li>
            `).join("")}</ul>
          </details>` : ""}
        ${Object.keys(artifacts).length ? `
          <details>
            <summary>当前轮次产物</summary>
            <ul>${Object.entries(artifacts).filter(([, relative]) => !relative.endsWith("/git")).map(([label, relative]) => `
              <li><a href="${escapeHtml(artifactUrl(run.id, relative))}" target="_blank" rel="noreferrer">${escapeHtml(label)}</a></li>
            `).join("")}</ul>
          </details>` : ""}
      </article>`;
  }).join("");
  const error = run.lastError?.message ? ` · ${run.lastError.message}` : "";
  updated.textContent = `最后更新 ${new Date(run.updatedAt).toLocaleString()}${error}`;
}

function renderEmpty() {
  summary.innerHTML = "<article><strong>尚无 run.json</strong><span>先运行 orchestrate.mjs run</span></article>";
  tasks.innerHTML = "";
  progressText.textContent = "0/0";
  progressBar.style.width = "0";
}

async function refresh() {
  try {
    await loadRuns();
  } catch (error) {
    updated.textContent = `加载失败：${error.message}`;
  }
}

runSelect.addEventListener("change", () => loadRun(runSelect.value));
refreshButton.addEventListener("click", refresh);
await refresh();
setInterval(refresh, 2000);

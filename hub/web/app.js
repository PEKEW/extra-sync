/* extra-sync hub frontend: renders sync-report JSON and drives sync.sh actions. */

const $ = (sel) => document.querySelector(sel);

let report = null;      // latest sync-report JSON
let updates = [];       // parsed "update available" entries from --remote / --all
let lastConsole = "";   // raw output of the last executed action

// ---------- helpers ----------

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

function toast(msg, cls) {
  const t = $("#toast");
  t.textContent = msg;
  t.className = "toast " + (cls || "");
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.classList.add("hidden"), 4000);
}

function setBusy(busy) {
  document.querySelectorAll("header button").forEach((b) => (b.disabled = busy));
}

async function api(path, opts) {
  const res = await fetch(path, opts);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

// Colorize sync.sh log prefixes for the console panel.
function colorize(text) {
  return esc(text)
    .replace(/^\[OK\]/gm, '<span class="ok">[OK]</span>')
    .replace(/^\[WARN\]/gm, '<span class="warn">[WARN]</span>')
    .replace(/^\[ERR\]/gm, '<span class="err">[ERR]</span>');
}

function fmtTime(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  return isNaN(d) ? iso : d.toLocaleString("zh-CN", { hour12: false });
}

function updateFor(kind, name) {
  return updates.find((u) => u.kind === kind && u.name === name);
}

// ---------- rendering ----------

function render() {
  const content = $("#content");
  if (!report) {
    content.innerHTML = `
      <div class="empty-state">
        <div class="empty-icon">⇄</div>
        <h2>还没有清单报告</h2>
        <p>点击右上角「↻ 刷新报告」运行 <code>sync.sh --report</code> 生成第一份。</p>
      </div>`;
    return;
  }

  const h = report.health || {};
  const skillsOk = h.skills_valid === h.skills_total;
  const pluginsOk = h.plugins_enabled === h.plugins_total;

  $("#report-line").textContent =
    `报告时间 ${fmtTime(report.timestamp)} · agent: ${report.agent || "?"}`;

  const skillRows = (report.skills?.items || []).map((s) => {
    const upd = updateFor("skill", s.name);
    return `<tr class="row" data-key="${esc(s.name)} ${esc(s.description)}">
      <td class="name">${esc(s.name)}${s.has_skill_md ? "" : ' <span class="tag err">缺 SKILL.md</span>'}${
        upd ? ` <span class="tag update">可更新 ${esc(upd.local)} → ${esc(upd.remote)}</span>` : ""
      }</td>
      <td><span class="tag scope">${esc(s.scope)}</span></td>
      <td class="mono">${esc(s.version === "unknown" ? "—" : s.version)}</td>
      <td class="desc">${esc(s.description || "—")}</td>
    </tr>`;
  }).join("");

  const pluginRows = (report.plugins?.items || []).map((p) => {
    const upd = updateFor("plugin", p.name);
    const repo = p.source_repo
      ? `<a href="https://github.com/${esc(p.source_repo)}" target="_blank" rel="noopener">${esc(p.source_repo)}</a>`
      : "—";
    return `<tr class="row" data-key="${esc(p.name)} ${esc(p.source_repo || "")}">
      <td class="name">${esc(p.name)}${
        upd ? ` <span class="tag update">可更新 ${esc(upd.local)} → ${esc(upd.remote)}</span>` : ""
      }</td>
      <td class="mono">${esc(p.version || "—")}</td>
      <td>${repo}</td>
      <td class="mono">${esc((p.git_commit || "").slice(0, 7) || "—")}</td>
      <td>${p.enabled ? '<span class="tag ok">enabled</span>' : '<span class="tag warn">disabled</span>'}</td>
    </tr>`;
  }).join("");

  const updateSection = updates.length ? `
    <section>
      <h2>可用更新 <span class="badge warn">${updates.length}</span></h2>
      <div class="section-body">
        <div class="hint">更新操作请通过 github-to-skills / 插件市场执行，hub 只做检测。</div>
        <table>
          <tr><th>类型</th><th>名称</th><th>本地</th><th>远端</th></tr>
          ${updates.map((u) => `<tr>
            <td><span class="tag scope">${esc(u.kind)}</span></td>
            <td class="name">${esc(u.name)}</td>
            <td class="mono">${esc(u.local)}</td>
            <td class="mono">${esc(u.remote)}</td>
          </tr>`).join("")}
        </table>
      </div>
    </section>` : "";

  content.innerHTML = `
    <section>
      <h2>健康总览</h2>
      <div class="section-body kv">
        <div class="item"><div class="k">Skills</div>
          <div class="v ${skillsOk ? "ok" : "warn"}">${h.skills_valid ?? "?"} / ${h.skills_total ?? "?"} 有效</div></div>
        <div class="item"><div class="k">Plugins</div>
          <div class="v ${pluginsOk ? "ok" : "warn"}">${h.plugins_enabled ?? "?"} / ${h.plugins_total ?? "?"} 启用</div></div>
        <div class="item"><div class="k">可用更新</div>
          <div class="v ${updates.length ? "warn" : "ok"}">${updates.length ? updates.length + " 项" : "未检测 / 无"}</div></div>
      </div>
    </section>
    ${updateSection}
    <section>
      <h2>Skills <span class="badge">${report.skills?.count ?? 0}</span></h2>
      <div class="section-body">
        <table>
          <tr><th>名称</th><th>范围</th><th>版本</th><th>描述</th></tr>
          ${skillRows || '<tr><td colspan="4" class="empty">无</td></tr>'}
        </table>
      </div>
    </section>
    <section>
      <h2>Plugins <span class="badge">${report.plugins?.count ?? 0}</span></h2>
      <div class="section-body">
        <table>
          <tr><th>名称</th><th>版本</th><th>来源仓库</th><th>commit</th><th>状态</th></tr>
          ${pluginRows || '<tr><td colspan="5" class="empty">无</td></tr>'}
        </table>
      </div>
    </section>
    <section id="console-section" class="${lastConsole ? "" : "hidden"}">
      <h2>执行输出</h2>
      <div class="console">${colorize(lastConsole)}</div>
    </section>`;

  applyFilter();
}

function applyFilter() {
  const q = $("#filter").value.trim().toLowerCase();
  document.querySelectorAll("tr.row").forEach((tr) => {
    tr.style.display = !q || tr.dataset.key.toLowerCase().includes(q) ? "" : "none";
  });
}

// ---------- actions ----------

async function loadReport() {
  try {
    report = await api("/api/report");
  } catch (e) {
    report = null;
  }
  render();
}

async function runAction(label, path, body) {
  setBusy(true);
  toast(`${label}执行中…`);
  try {
    const res = await api(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined,
    });
    lastConsole = res.output || "";
    if (res.updates) updates = res.updates;
    toast(res.ok !== false ? `${label}完成` : `${label}结束（exit ${res.exit_code}，详见执行输出）`,
          res.ok !== false ? "ok" : "err");
    return res;
  } catch (e) {
    toast(`${label}失败: ${e.message}`, "err");
    return null;
  } finally {
    setBusy(false);
  }
}

$("#refresh").addEventListener("click", async () => {
  setBusy(true);
  toast("正在生成报告…");
  try {
    report = await api("/api/report", { method: "POST" });
    toast("报告已刷新", "ok");
  } catch (e) {
    toast("刷新失败: " + e.message, "err");
  } finally {
    setBusy(false);
    render();
  }
});

$("#doctor-btn").addEventListener("click", async () => {
  const res = await runAction("Doctor ", "/api/doctor");
  if (res) render();
});

$("#fix-btn").addEventListener("click", async () => {
  if (!confirm("Fix 会修改 ~/.claude 与 ~/.agents-config 下的文件（修改前自动备份到 reports/fix-backups/）。继续？")) return;
  const res = await runAction("Fix ", "/api/fix");
  if (res) {
    render();
    await loadReport();
  }
});

$("#remote-btn").addEventListener("click", async () => {
  const res = await runAction("更新检查", "/api/remote");
  if (res) render();
});

$("#sync-btn").addEventListener("click", async () => {
  const res = await runAction("完整同步", "/api/sync");
  if (res) {
    render();
    await loadReport();
  }
});

$("#filter").addEventListener("input", applyFilter);

loadReport();

# extra-sync hub

extra-sync 的本地 Web 仪表盘：可视化 `~/.agents-config`（SSOT）中管理的 skills / plugins，
并通过页面按钮触发 doctor / fix / 更新检查 / 完整同步。

设计参考了 [skills-hub](https://github.com/mcncarl/skills-hub) 的"中央库 + 分发"理念与
macsync 的"scan 落盘缓存 → serve 只读 → 按钮触发重扫"模式，但代码完全独立（Go 纯标准库，
前端原生 JS 内嵌进二进制，无外部依赖）。

## 核心原则

**hub 不实现任何同步逻辑。** 所有诊断与修改动作都是对
`../scripts/sync.sh` 的薄封装，shell 脚本仍是行为的唯一来源。
页面数据来自 `~/.agents-config/reports/sync-report-*.json`（取最新一份）。

## 快速上手

```bash
cd ~/.agents-config/special/claude/plugins/extra-sync/hub

# 编译（Go 1.26+，无外部依赖）
/opt/homebrew/bin/go build -o extra-sync-hub .

# 启动（默认 127.0.0.1:8788，仅本机可访问）
./extra-sync-hub serve            # 可选 --port N
```

停止：Ctrl+C 或 `pkill -f "extra-sync-hub serve"`。
重复启动会自动停止旧实例并接管端口；端口被其他进程占用时会列出 PID 和释放命令。

## 页面功能

| 按钮 | 执行 | 说明 |
|---|---|---|
| ↻ 刷新报告 | `sync.sh --report` | 重新生成清单 JSON 并刷新页面 |
| 🩺 Doctor | `sync.sh doctor` | 只读诊断，不修改任何文件 |
| 🔧 Fix | `sync.sh fix` | 修复 off-SSOT 安装与链接漂移（有确认弹窗，修改前自动备份） |
| ⬆ 检查更新 | `sync.sh --remote` | 逐个 `git ls-remote` 对比远端，标出可更新项 |
| ☁️ 完整同步 | `sync.sh --all` | pull + skills + plugins + remote + report |

页面区块：健康总览（skills/plugins 有效数、可用更新数）、可用更新列表、
Skills 表（名称/范围/版本/描述）、Plugins 表（名称/版本/来源仓库/commit/启用状态）、
执行输出控制台（最近一次命令的原始输出，按 [OK]/[WARN]/[ERR] 着色）。

hub 只**检测**更新，不执行更新——skill 更新走 github-to-skills，插件更新走插件市场。

## API

全部 JSON，仅监听 127.0.0.1。sync.sh 同一时刻只允许一个实例运行（并发请求返回 409）。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/health` | 健康检查 |
| GET | `/api/report` | 返回最新 sync-report（无报告时 404 + 引导文案） |
| POST | `/api/report` | 先运行 `--report` 再返回最新报告 |
| POST | `/api/doctor` | 运行 doctor，返回 `{ok, exit_code, output}`（exit 1 = 存在 ERR 级问题） |
| POST | `/api/fix` | 运行 fix；可选 body `{"scope":"claude"}` |
| POST | `/api/remote` | 运行 `--remote`，返回 output + 解析出的 `updates[]` |
| POST | `/api/sync` | 运行 `--all`，返回 output + `updates[]` |

`updates[]` 元素：`{kind: "plugin"|"skill", name, local, remote}`，
从输出中的 `update available (X -> Y)` 行解析（本地版本可能是 hash、semver 或 unknown）。

## 文件结构

```
hub/
├── main.go        CLI 入口 + HTTP 服务 + sync.sh 封装 + 更新解析 + 端口接管
├── web/           index.html / app.js / style.css（//go:embed 打进二进制）
├── go.mod
└── extra-sync-hub 编译产物（不入库）
```

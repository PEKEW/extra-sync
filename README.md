# extra-sync

跨 agent 配置同步工具：以 `~/.agents-config` 为唯一事实来源（SSOT），
把 skills / plugins / 配置通过软链接分发给消费端（当前是 Claude Code 的 `~/.claude/`），
并提供诊断、修复、远端更新检查与本地 Web 仪表盘。

## 约定

```
~/.agents-config/                     SSOT（git 仓库）
├── common/skills/<name>/             跨 agent 共享 skills
└── special/claude/
    ├── skills/<name>/                Claude 专属 skills
    └── plugins/plugins.json          插件清单（SSOT）

~/.claude/                            消费端（Claude Code）
├── skills/<name>  → 软链接到上面两处
└── managed-plugins.json → 软链接到 plugins.json
```

任何"实体目录装进 `~/.claude/skills/`"、"链接指向 SSOT 之外"、"settings.json 与
plugins.json 启用状态漂移"都视为问题，可被检测和自动修复。

## 组件

| 路径 | 说明 |
|---|---|
| `scripts/sync.sh` | 核心脚本：同步、诊断（doctor）、修复（fix）、远端更新检查、清单报告 |
| `hub/` | 本地 Web 仪表盘（Go 单二进制，封装 sync.sh），详见 [hub/README.md](hub/README.md) |
| `skills/extra-sync/` | Claude Code skill 定义，让 `/extra-sync` 驱动脚本 |
| `.claude-plugin/` | Claude Code 插件元数据 |

## 使用

```bash
SYNC=~/.agents-config/special/claude/plugins/extra-sync/scripts/sync.sh

bash $SYNC --all       # 完整同步：pull + skills + plugins + remote + report
bash $SYNC doctor      # 只读诊断（CI 可用：有 ERR 级问题时 exit 1）
bash $SYNC fix         # 修复问题（修改前备份到 reports/fix-backups/）
bash $SYNC --remote    # 只检查 GitHub 远端更新
bash $SYNC --report    # 只生成清单 JSON（reports/sync-report-*.json）
```

Web 仪表盘：

```bash
cd hub && go build -o extra-sync-hub . && ./extra-sync-hub serve   # http://127.0.0.1:8788
```

## 检测的问题类型

`SKILL_REAL_DIR`（实体目录装在消费端 → 搬进 SSOT + 软链）、`SKILL_DANGLING`（死链）、
`SKILL_WRONG_TARGET`（链接指向 SSOT 外）、`SKILL_FRONTMATTER`（缺 name/description，仅提示）、
`MANAGED_PLUGINS_BAD`（managed-plugins.json 非正确软链）、`PLUGIN_UNTRACKED`（settings.json
启用但 plugins.json 未登记）、`SETTINGS_DRIFT`（启用状态漂移）。

## 说明

本仓库由 `agents-config` 主仓库的 `special/claude/plugins/extra-sync/` 路径
经 `git subtree split` 发布，开发仍在主仓库进行。依赖：bash、jq、git；hub 需 Go 1.26+。
License: MIT。

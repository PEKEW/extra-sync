---
name: extra-sync
description: Sync skills, plugins, and remote updates across agents-config. Use when the user wants to check or sync their plugin/skill configurations.
argument-hint: "[--skills] [--plugins] [--remote] [--report]"
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
version: 0.1.0
---

# extra-sync

Synchronize skills, plugins, and configurations between `~/.agents-config` (source of truth) and `~/.claude/` (Claude Code consumer).

## How to use this skill

Run the sync script and present the results clearly.

### Step 1: Execute sync

Run the sync script. If the user provided arguments (e.g., `--skills`, `--plugins`, `--remote`, `--report`), pass them through. Otherwise, use `--all`.

```bash
bash "$HOME/.agents-config/special/claude/plugins/extra-sync/scripts/sync.sh" --all 2>&1
```

### Step 2: Present results

After the script completes, present a clean markdown summary:

**Skills Status**
- List each skill with its validation status (valid / missing frontmatter / missing SKILL.md)
- Show symlink health (common, local, special)

**Plugins Status**
- Show plugin sync state between agents-config and settings.json
- Report any auto-fixes applied (e.g., enabling a plugin in settings.json)

**Remote Updates**
- Flag any plugin or skill with a newer version available on GitHub
- Show old vs new commit hashes

**Health Summary**
- Skills: N/M valid
- Plugins: N/M enabled
- Symlinks: N tracked

### Step 3: Actionable follow-ups

If there are issues:
- Broken symlinks: explain how to fix
- Missing frontmatter: suggest adding name/description to SKILL.md
- Available updates: ask if the user wants to update

### Available flags

| Flag | Description |
|------|-------------|
| `--skills` | Only sync skills (symlinks + SKILL.md validation) |
| `--plugins` | Only sync plugins (managed-plugins.json + settings.json) |
| `--remote` | Only check for remote updates from GitHub |
| `--report` | Only generate inventory JSON report |
| `--all` | Run all modules (default) |

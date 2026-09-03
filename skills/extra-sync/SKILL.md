---
name: extra-sync
description: Sync skills, plugins, and remote updates across agents-config. Use when the user wants to check or sync their plugin/skill configurations.
argument-hint: "[doctor] [fix] [--skills] [--plugins] [--remote] [--report] [--scope common|claude]"
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

### Step 1: Execute

Run the script, passing the user's intent through as the argument:

- User says **doctor** / "check config" / "check links" → pass `doctor` (read-only diagnosis, never writes).
- User says **fix** / "fix links" / "put things back in order" → pass `fix` (mutates, backs up first). Append `--scope claude` if they want off-SSOT skills relocated to the Claude-only tree instead of the default shared `common`.
- User provides sync flags (`--skills`, `--plugins`, `--remote`, `--report`) → pass them through.
- Otherwise → use `--all`.

```bash
bash "$HOME/.agents-config/special/claude/plugins/extra-sync/scripts/sync.sh" doctor 2>&1
```

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

## Diagnose & repair

Two dedicated subcommands handle artifacts installed **outside** the extra-sync
convention (e.g. a skill dropped as a real directory in `~/.claude/skills/<name>`,
a symlink pointing off the source-of-truth, a dangling link, or a plugin enabled in
`settings.json` but missing from `plugins.json`).

1. **`doctor`** — read-only. Detects mis-organized installs and link/config drift,
   prints each issue with the repair it *would* apply, never writes. Exits non-zero
   if any broken (ERR) issue remains, so it is CI-usable.
2. **`fix`** — applies the repairs immediately, backing up anything it overwrites to
   `~/.agents-config/reports/fix-backups/<timestamp>/`.
3. Re-run **`doctor`** to confirm a clean state.

Issue types detected: `SKILL_REAL_DIR` (off-SSOT real dir → relocate + symlink),
`SKILL_DANGLING` (dead link → remove/repoint), `SKILL_WRONG_TARGET` (points off-SSOT
→ repoint/import), `SKILL_FRONTMATTER` (missing name/description — manual edit only),
`MANAGED_PLUGINS_BAD` (managed-plugins.json not a correct symlink),
`PLUGIN_UNTRACKED` (enabled in settings.json, absent from plugins.json → register),
`SETTINGS_DRIFT` (enabled-flag mismatch → align settings.json to SSOT).

### Available commands & flags

| Command / Flag | Description |
|------|-------------|
| `doctor` | Read-only diagnosis of install layout + link/config correctness (no writes) |
| `fix` | Repair off-SSOT installs and bad links; mutates with backups |
| `--scope common\|claude` | For `fix`: target tree when relocating off-SSOT skills (default `common`) |
| `--skills` | Only sync skills (symlinks + SKILL.md validation) |
| `--plugins` | Only sync plugins (managed-plugins.json + settings.json) |
| `--remote` | Only check for remote updates from GitHub |
| `--report` | Only generate inventory JSON report |
| `--all` | Run all sync modules (default) |

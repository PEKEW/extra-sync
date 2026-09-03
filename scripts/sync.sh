#!/usr/bin/env bash
# extra-sync: Sync skills, plugins, and configurations for Claude Code
# Usage: sync.sh [--skills] [--plugins] [--remote] [--report] [--all]

set -euo pipefail

AGENTS_CONFIG="$HOME/.agents-config"
CLAUDE_DIR="$HOME/.claude"
INVENTORY="$AGENTS_CONFIG/state/inventory.json"
REPORT_DIR="$AGENTS_CONFIG/reports"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR]${NC} $1"; }
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_head() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# ──────────────────────────────────────────────
# Remote Pull (sync from GitHub)
# ──────────────────────────────────────────────
pull_remote() {
  log_head "Remote Pull"

  if [ ! -d "$AGENTS_CONFIG/.git" ]; then
    log_err "agents-config is not a git repo, skipping remote pull"
    return 1
  fi

  cd "$AGENTS_CONFIG"

  # Check if remote exists
  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || echo "")
  if [ -z "$remote_url" ]; then
    log_err "No git remote 'origin' configured"
    return 1
  fi

  log_info "Remote: $remote_url"

  # Check for local uncommitted changes
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    log_warn "Local uncommitted changes detected"
    log_info "Stashing local changes..."
    git stash push -m "extra-sync auto-stash $(date +%Y%m%d-%H%M%S)" 2>/dev/null
    local stashed=true
  fi

  # Pull latest
  local pull_output
  pull_output=$(git pull --rebase origin main 2>&1) || {
    log_err "git pull failed: $pull_output"
    if [ "${stashed:-false}" = true ]; then
      git stash pop 2>/dev/null
    fi
    return 1
  }

  if echo "$pull_output" | grep -q "Already up to date"; then
    log_ok "Already up to date"
  else
    log_ok "Pulled latest changes"
    echo "$pull_output" | while IFS= read -r line; do
      log_info "  $line"
    done
  fi

  # Pop stash if we stashed
  if [ "${stashed:-false}" = true ]; then
    log_info "Restoring local changes..."
    git stash pop 2>/dev/null && log_ok "Local changes restored" || log_warn "Stash pop had conflicts"
  fi

  cd - >/dev/null
}

# ──────────────────────────────────────────────
# Skills Sync
# ──────────────────────────────────────────────
sync_skills() {
  log_head "Skills Sync"

  local common_src="$AGENTS_CONFIG/common/skills"
  local special_src="$AGENTS_CONFIG/special/claude/skills"
  local skills_dir="$CLAUDE_DIR/skills"

  mkdir -p "$skills_dir"

  # Claude Code only scans skills one level deep (~/.claude/skills/<name>/SKILL.md),
  # so each skill dir must be linked individually. Linking a parent dir (common/
  # local/special) buries skills two levels deep where CC never finds them.

  # Remove legacy parent-dir symlinks from older versions.
  for legacy in common local special; do
    local legacy_path="$skills_dir/$legacy"
    if [ -L "$legacy_path" ]; then
      rm "$legacy_path"
      log_warn "Removed legacy parent symlink skills/$legacy"
    fi
  done

  # Link each skill dir into ~/.claude/skills/<name>.
  for skill_dir in "$common_src"/*/ "$special_src"/*/; do
    [ -d "$skill_dir" ] || continue
    skill_dir="${skill_dir%/}"
    [ -f "$skill_dir/SKILL.md" ] || continue
    local name link_path
    name=$(basename "$skill_dir")
    link_path="$skills_dir/$name"

    if [ -L "$link_path" ]; then
      if [ "$(readlink "$link_path")" = "$skill_dir" ]; then
        log_ok "Symlink $name -> $skill_dir"
      else
        rm "$link_path"
        ln -s "$skill_dir" "$link_path"
        log_warn "Fixed symlink $name -> $skill_dir"
      fi
    elif [ -e "$link_path" ]; then
      log_err "skills/$name exists but is not a symlink, skipping"
    else
      ln -s "$skill_dir" "$link_path"
      log_ok "Created symlink $name -> $skill_dir"
    fi
  done

  # Validate SKILL.md files
  local skill_count=0
  local valid_count=0
  local invalid_skills=()

  for skill_dir in "$common_src"/*/  "$special_src"/*/; do
    [ -d "$skill_dir" ] || continue
    local skill_name
    skill_name=$(basename "$skill_dir")
    skill_count=$((skill_count + 1))

    local skill_md="$skill_dir/SKILL.md"
    if [ ! -f "$skill_md" ]; then
      log_err "Missing SKILL.md in $skill_name"
      invalid_skills+=("$skill_name:missing_skill_md")
      continue
    fi

    # Check frontmatter
    if head -1 "$skill_md" | grep -q '^---'; then
      local frontmatter
      frontmatter=$(awk 'NR==1 && /^---$/{f=1;next} f && /^---$/{exit} f' "$skill_md")
      local has_name has_desc
      has_name=$(echo "$frontmatter" | grep -c '^name:' || true)
      has_desc=$(echo "$frontmatter" | grep -c '^description:' || true)

      if [ "$has_name" -gt 0 ] && [ "$has_desc" -gt 0 ]; then
        log_ok "Skill '$skill_name' - valid SKILL.md"
        valid_count=$((valid_count + 1))
      else
        log_warn "Skill '$skill_name' - missing name or description in frontmatter"
        invalid_skills+=("$skill_name:incomplete_frontmatter")
      fi
    else
      log_warn "Skill '$skill_name' - no YAML frontmatter"
      invalid_skills+=("$skill_name:no_frontmatter")
    fi
  done

  log_info "Skills: $valid_count/$skill_count valid"
  if [ ${#invalid_skills[@]} -gt 0 ]; then
    log_warn "Issues: ${invalid_skills[*]}"
  fi

  echo "$skill_count:$valid_count:${invalid_skills[*]:-}"
}

# ──────────────────────────────────────────────
# Plugins Sync
# ──────────────────────────────────────────────
sync_plugins() {
  log_head "Plugins Sync"

  local managed_plugins="$CLAUDE_DIR/managed-plugins.json"
  local source_plugins="$AGENTS_CONFIG/special/claude/plugins/plugins.json"
  local settings="$CLAUDE_DIR/settings.json"

  # Ensure managed-plugins.json symlink
  if [ -L "$managed_plugins" ]; then
    local current_target
    current_target=$(readlink "$managed_plugins")
    if [ "$current_target" = "$source_plugins" ]; then
      log_ok "managed-plugins.json symlink correct"
    else
      rm "$managed_plugins"
      ln -s "$source_plugins" "$managed_plugins"
      log_warn "Fixed managed-plugins.json symlink"
    fi
  elif [ -f "$managed_plugins" ]; then
    log_warn "managed-plugins.json is a regular file, not a symlink"
    log_info "Backing up and creating symlink..."
    cp "$managed_plugins" "$managed_plugins.bak.$(date +%Y%m%d%H%M%S)"
    rm "$managed_plugins"
    ln -s "$source_plugins" "$managed_plugins"
    log_ok "Fixed: backed up and symlinked managed-plugins.json"
  else
    ln -s "$source_plugins" "$managed_plugins"
    log_ok "Created managed-plugins.json symlink"
  fi

  # Read plugins from source and check settings.json
  if [ -f "$source_plugins" ] && command -v jq &>/dev/null; then
    local plugin_count
    plugin_count=$(jq 'length' "$source_plugins")
    log_info "Managed plugins: $plugin_count"

    # Check each plugin is enabled in settings.json
    if [ -f "$settings" ]; then
      for key in $(jq -r '.[].key // empty' "$source_plugins"); do
        local enabled
        enabled=$(jq -r ".enabledPlugins[\"$key\"] // false" "$settings")
        local src_enabled
        src_enabled=$(jq -r ".[] | select(.key == \"$key\") | .enabled" "$source_plugins")

        if [ "$src_enabled" = "true" ] && [ "$enabled" != "true" ]; then
          log_warn "Plugin '$key' enabled in agents-config but not in settings.json"
          # Auto-fix: enable in settings.json
          local tmp
          tmp=$(mktemp)
          jq ".enabledPlugins[\"$key\"] = true" "$settings" > "$tmp" && mv "$tmp" "$settings"
          log_ok "Auto-enabled '$key' in settings.json"
        elif [ "$src_enabled" = "false" ] && [ "$enabled" = "true" ]; then
          log_warn "Plugin '$key' disabled in agents-config but enabled in settings.json"
        else
          log_ok "Plugin '$key' - sync OK (enabled=$enabled)"
        fi
      done
    fi

    # Check marketplace registrations
    for repo in $(jq -r '.[] | select(.source_type == "github") | .source_repo // empty' "$source_plugins"); do
      local mkt_name
      mkt_name=$(echo "$repo" | tr '/' '-' | sed 's/.*-//')
      local has_mkt
      has_mkt=$(jq -r ".extraKnownMarketplaces | keys[]" "$settings" 2>/dev/null | grep -c "$mkt_name" || true)
      if [ "$has_mkt" -gt 0 ]; then
        log_ok "Marketplace for '$repo' registered"
      else
        log_warn "Marketplace for '$repo' not found in settings.json"
      fi
    done
  else
    if ! command -v jq &>/dev/null; then
      log_err "jq not installed, cannot parse JSON configs"
    fi
  fi
}

# ──────────────────────────────────────────────
# Remote Update Check
# ──────────────────────────────────────────────
check_remote() {
  log_head "Remote Update Check"

  local source_plugins="$AGENTS_CONFIG/special/claude/plugins/plugins.json"

  if [ ! -f "$source_plugins" ] || ! command -v jq &>/dev/null; then
    log_err "Cannot check remote updates (missing plugins.json or jq)"
    return 1
  fi

  # Check plugin updates from GitHub (skip marketplace-managed plugins)
  local updates_available=0
  while IFS=$'\t' read -r name repo local_hash version managed_by; do
    [ -z "$repo" ] && continue
    if [ "$managed_by" = "marketplace" ]; then
      log_ok "$name: managed by marketplace, skipping"
      continue
    fi
    log_info "Checking $name ($repo@$version)..."

    local remote_hash
    remote_hash=$(git ls-remote "https://github.com/$repo.git" HEAD 2>/dev/null | cut -f1 || echo "")

    if [ -z "$remote_hash" ]; then
      log_warn "Could not reach https://github.com/$repo"
      continue
    fi

    local short_local="${local_hash:0:7}"
    local short_remote="${remote_hash:0:7}"

    if [ "$local_hash" = "$remote_hash" ]; then
      log_ok "$name: up to date ($short_local)"
    else
      log_warn "$name: update available ($short_local -> $short_remote)"
      updates_available=$((updates_available + 1))
    fi
  done < <(jq -r '.[] | select(.source_type == "github") | [.name, .source_repo, .git_commit, .version, (.managed_by // "self")] | @tsv' "$source_plugins")

  # Check skills with github_hash
  for skill_md in "$AGENTS_CONFIG"/common/skills/*/SKILL.md "$AGENTS_CONFIG"/special/claude/skills/*/SKILL.md; do
    [ -f "$skill_md" ] || continue
    local skill_name
    skill_name=$(basename "$(dirname "$skill_md")")

    local github_url github_hash
    local fm
    fm=$(awk 'NR==1 && /^---$/{f=1;next} f && /^---$/{exit} f' "$skill_md")
    github_url=$(echo "$fm" | awk '/^github_url:/{sub(/^github_url: */, ""); print; exit}')
    github_hash=$(echo "$fm" | awk '/^github_hash:/{sub(/^github_hash: */, ""); print; exit}')

    [ -z "$github_url" ] || [ -z "$github_hash" ] && continue

    # Extract owner/repo from URL
    local repo_path
    repo_path=$(echo "$github_url" | sed 's|https://github.com/||;s|\.git$||;s|/$||')
    [ -z "$repo_path" ] && continue

    log_info "Checking skill '$skill_name' ($repo_path)..."
    local remote_hash
    remote_hash=$(git ls-remote "https://github.com/$repo_path.git" HEAD 2>/dev/null | cut -f1 || echo "")

    if [ -z "$remote_hash" ]; then
      log_warn "Could not reach $github_url"
      continue
    fi

    if [ "$github_hash" = "$remote_hash" ]; then
      log_ok "Skill '$skill_name': up to date (${github_hash:0:7})"
    else
      log_warn "Skill '$skill_name': update available (${github_hash:0:7} -> ${remote_hash:0:7})"
      updates_available=$((updates_available + 1))
    fi
  done

  if [ "$updates_available" -eq 0 ]; then
    log_ok "All plugins and skills are up to date"
  else
    log_warn "$updates_available update(s) available"
  fi
}

# ──────────────────────────────────────────────
# Inventory Report
# ──────────────────────────────────────────────
generate_report() {
  log_head "Inventory Report"

  mkdir -p "$REPORT_DIR"

  local report_file="$REPORT_DIR/sync-report-$(date +%Y%m%d-%H%M%S).json"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if ! command -v jq &>/dev/null; then
    log_err "jq not installed, cannot generate JSON report"
    return 1
  fi

  # Collect skills info
  local skills_json="[]"
  for skills_dir in "$AGENTS_CONFIG/common/skills" "$AGENTS_CONFIG/special/claude/skills"; do
    local scope="common"
    [[ "$skills_dir" == *special* ]] && scope="claude-specific"

    for skill_dir in "$skills_dir"/*/; do
      [ -d "$skill_dir" ] || continue
      local skill_name
      skill_name=$(basename "$skill_dir")
      local skill_md="$skill_dir/SKILL.md"
      local has_skill_md="false"
      local skill_desc=""
      local skill_version=""

      if [ -f "$skill_md" ]; then
        has_skill_md="true"
        local sfm
        sfm=$(awk 'NR==1 && /^---$/{f=1;next} f && /^---$/{exit} f' "$skill_md")
        skill_desc=$(echo "$sfm" | awk -F': *' '/^description:/{$1=""; sub(/^ /,""); print; exit}' | sed 's/"/\\"/g')
        skill_version=$(echo "$sfm" | awk -F': *' '/^version:/{print $2; exit}')
      fi

      skills_json=$(echo "$skills_json" | jq \
        --arg name "$skill_name" \
        --arg scope "$scope" \
        --arg path "$skill_dir" \
        --argjson has_md "$has_skill_md" \
        --arg desc "$skill_desc" \
        --arg ver "${skill_version:-unknown}" \
        '. += [{"name":$name,"scope":$scope,"path":$path,"has_skill_md":$has_md,"description":$desc,"version":$ver}]')
    done
  done

  # Collect plugins info
  local plugins_json="[]"
  local source_plugins="$AGENTS_CONFIG/special/claude/plugins/plugins.json"
  if [ -f "$source_plugins" ]; then
    plugins_json=$(jq '[.[] | {name, key, version, source_repo, enabled, git_commit}]' "$source_plugins")
  fi

  # Collect symlinks status
  local symlinks_json="[]"
  if [ -f "$INVENTORY" ]; then
    symlinks_json=$(jq '[.summary.consumer_links[] | select(.target | startswith("/Users/peke/.claude")) | {source, target, kind}]' "$INVENTORY" 2>/dev/null || echo "[]")
  fi

  # Build report
  jq -n \
    --arg ts "$timestamp" \
    --argjson skills "$skills_json" \
    --argjson plugins "$plugins_json" \
    --argjson symlinks "$symlinks_json" \
    '{
      timestamp: $ts,
      agent: "claude",
      skills: {
        count: ($skills | length),
        items: $skills
      },
      plugins: {
        count: ($plugins | length),
        items: $plugins
      },
      symlinks: $symlinks,
      health: {
        skills_valid: ([$skills[] | select(.has_skill_md == true)] | length),
        skills_total: ($skills | length),
        plugins_enabled: ([$plugins[] | select(.enabled == true)] | length),
        plugins_total: ($plugins | length)
      }
    }' > "$report_file"

  log_ok "Report saved to: $report_file"

  # Print summary
  echo ""
  jq -r '
    "  Skills:  \(.health.skills_valid)/\(.health.skills_total) valid",
    "  Plugins: \(.health.plugins_enabled)/\(.health.plugins_total) enabled",
    "  Symlinks: \(.symlinks | length) tracked"
  ' "$report_file"

  cat "$report_file"
}

# ──────────────────────────────────────────────
# Diagnostics (shared by doctor + fix)
# ──────────────────────────────────────────────

# Resolve canonical SSOT skill dir for a name. Echoes path if found, else nothing.
ssot_skill_path() {
  local name="$1"
  if [ -d "$AGENTS_CONFIG/common/skills/$name" ]; then
    echo "$AGENTS_CONFIG/common/skills/$name"
  elif [ -d "$AGENTS_CONFIG/special/claude/skills/$name" ]; then
    echo "$AGENTS_CONFIG/special/claude/skills/$name"
  fi
}

# Detect skill-link issues in ~/.claude/skills.
# Emits TSV per issue: TYPE \t NAME \t DETAIL \t HINT
detect_skill_issues() {
  local skills_dir="$CLAUDE_DIR/skills"
  [ -d "$skills_dir" ] || return 0
  local entry name target
  for entry in "$skills_dir"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=$(basename "$entry")
    if [ -L "$entry" ]; then
      target=$(readlink "$entry")
      if [ ! -e "$entry" ]; then
        printf '%s\t%s\t%s\t%s\n' "SKILL_DANGLING" "$name" "$target" "remove or repoint to SSOT"
      elif [[ "$target" != "$AGENTS_CONFIG"/* ]]; then
        printf '%s\t%s\t%s\t%s\n' "SKILL_WRONG_TARGET" "$name" "$target" "repoint to SSOT / import source"
      fi
    elif [ -d "$entry" ] && [ -f "$entry/SKILL.md" ]; then
      # Real dir holding a skill — installed outside the extra-sync convention.
      printf '%s\t%s\t%s\t%s\n' "SKILL_REAL_DIR" "$name" "$entry" "relocate into SSOT + symlink"
    fi
  done
}

# Detect SKILL.md frontmatter problems in SSOT skills (manual-fix only).
detect_frontmatter_issues() {
  local skill_md fm has_name has_desc name
  for skill_md in "$AGENTS_CONFIG"/common/skills/*/SKILL.md "$AGENTS_CONFIG"/special/claude/skills/*/SKILL.md; do
    [ -f "$skill_md" ] || continue
    name=$(basename "$(dirname "$skill_md")")
    if ! head -1 "$skill_md" | grep -q '^---'; then
      printf '%s\t%s\t%s\t%s\n' "SKILL_FRONTMATTER" "$name" "no YAML frontmatter" "add name/description"
      continue
    fi
    fm=$(awk 'NR==1 && /^---$/{f=1;next} f && /^---$/{exit} f' "$skill_md")
    has_name=$(echo "$fm" | grep -c '^name:' || true)
    has_desc=$(echo "$fm" | grep -c '^description:' || true)
    if [ "$has_name" -eq 0 ] || [ "$has_desc" -eq 0 ]; then
      printf '%s\t%s\t%s\t%s\n' "SKILL_FRONTMATTER" "$name" "missing name or description" "edit frontmatter"
    fi
  done
}

# Detect plugin/config issues: managed-plugins.json symlink, untracked plugins,
# and enabled-flag drift between plugins.json (SSOT) and settings.json.
detect_plugin_issues() {
  local managed_plugins="$CLAUDE_DIR/managed-plugins.json"
  local source_plugins="$AGENTS_CONFIG/special/claude/plugins/plugins.json"
  local settings="$CLAUDE_DIR/settings.json"

  if [ -L "$managed_plugins" ]; then
    if [ "$(readlink "$managed_plugins")" != "$source_plugins" ]; then
      printf '%s\t%s\t%s\t%s\n' "MANAGED_PLUGINS_BAD" "managed-plugins.json" "symlink -> $(readlink "$managed_plugins")" "repoint to plugins.json"
    fi
  elif [ -f "$managed_plugins" ]; then
    printf '%s\t%s\t%s\t%s\n' "MANAGED_PLUGINS_BAD" "managed-plugins.json" "regular file, not symlink" "backup + symlink"
  else
    printf '%s\t%s\t%s\t%s\n' "MANAGED_PLUGINS_BAD" "managed-plugins.json" "missing" "create symlink"
  fi

  command -v jq &>/dev/null || return 0
  [ -f "$source_plugins" ] && [ -f "$settings" ] || return 0

  # Untracked: enabled in settings.json but absent from plugins.json
  local key tracked
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    tracked=$(jq -r --arg k "$key" 'map(select(.key == $k)) | length' "$source_plugins")
    if [ "$tracked" = "0" ]; then
      printf '%s\t%s\t%s\t%s\n' "PLUGIN_UNTRACKED" "$key" "in settings.json, not in plugins.json" "append to plugins.json"
    fi
  done < <(jq -r '.enabledPlugins // {} | keys[]' "$settings")

  # Drift: enabled flag mismatch between SSOT and settings.json
  local src_enabled set_enabled
  while IFS=$'\t' read -r key src_enabled; do
    [ -z "$key" ] && continue
    set_enabled=$(jq -r --arg k "$key" '.enabledPlugins[$k] // false' "$settings")
    if [ "$src_enabled" != "$set_enabled" ]; then
      printf '%s\t%s\t%s\t%s\n' "SETTINGS_DRIFT" "$key" "plugins.json=$src_enabled settings.json=$set_enabled" "align settings to SSOT"
    fi
  done < <(jq -r '.[] | [.key, (.enabled|tostring)] | @tsv' "$source_plugins")
}

# ──────────────────────────────────────────────
# Doctor (read-only diagnosis)
# ──────────────────────────────────────────────
run_doctor() {
  log_head "Doctor (read-only)"

  local all
  all=$(printf '%s\n%s\n%s\n' \
    "$(detect_skill_issues || true)" \
    "$(detect_frontmatter_issues || true)" \
    "$(detect_plugin_issues || true)")

  local type name detail hint
  local skill_n=0 plugin_n=0 err_n=0 total=0
  while IFS=$'\t' read -r type name detail hint; do
    [ -z "${type:-}" ] && continue
    total=$((total + 1))
    case "$type" in
      SKILL_*) skill_n=$((skill_n + 1)) ;;
      *)       plugin_n=$((plugin_n + 1)) ;;
    esac
    case "$type" in
      SKILL_DANGLING|MANAGED_PLUGINS_BAD)
        log_err  "$type  $name — $detail  → $hint"; err_n=$((err_n + 1)) ;;
      *)
        log_warn "$type  $name — $detail  → $hint" ;;
    esac
  done <<< "$all"

  echo ""
  if [ "$total" -eq 0 ]; then
    log_ok "No issues — everything organized per extra-sync convention"
  else
    log_info "Issues: $total total ($skill_n skills, $plugin_n plugins/config; $err_n broken)"
    log_info "Run 'fix' to repair (mutates, backs up first)"
  fi

  DOCTOR_ERR_COUNT=$err_n
  return 0
}

# ──────────────────────────────────────────────
# Fix (mutating repair, with backups)
# ──────────────────────────────────────────────
run_fix() {
  log_head "Fix (mutating)"

  local scope_dir
  if [ "${FIX_SCOPE:-common}" = "claude" ]; then
    scope_dir="$AGENTS_CONFIG/special/claude/skills"
  else
    scope_dir="$AGENTS_CONFIG/common/skills"
  fi
  log_info "Relocate scope for off-SSOT skills: ${FIX_SCOPE:-common} ($scope_dir)"

  local ts backups
  ts=$(date +%Y%m%d-%H%M%S)
  backups="$REPORT_DIR/fix-backups/$ts"

  local skills_dir="$CLAUDE_DIR/skills"
  local source_plugins="$AGENTS_CONFIG/special/claude/plugins/plugins.json"
  local settings="$CLAUDE_DIR/settings.json"
  local managed_plugins="$CLAUDE_DIR/managed-plugins.json"
  local fixed=0 settings_backed=0

  local all fm type name detail hint
  all=$(printf '%s\n%s\n' \
    "$(detect_skill_issues || true)" \
    "$(detect_plugin_issues || true)")
  fm=$(detect_frontmatter_issues || true)

  while IFS=$'\t' read -r type name detail hint; do
    [ -z "${type:-}" ] && continue
    case "$type" in
      SKILL_REAL_DIR)
        local src="$detail" target="$scope_dir/$name" ssot
        mkdir -p "$scope_dir"
        if [ -e "$target" ]; then
          mkdir -p "$backups"
          cp -R "$src" "$backups/$name"
          rm -rf "$src"
          log_warn "SSOT already has '$name'; backed up off-SSOT copy to $backups/$name, removed it"
        else
          mv "$src" "$target"
          log_ok "Relocated skill '$name' -> $target"
        fi
        ln -s "$target" "$skills_dir/$name"
        log_ok "Linked skills/$name -> $target"
        fixed=$((fixed + 1)) ;;
      SKILL_DANGLING)
        local ssot
        ssot=$(ssot_skill_path "$name")
        rm -f "$skills_dir/$name"
        if [ -n "$ssot" ]; then
          ln -s "$ssot" "$skills_dir/$name"
          log_ok "Repointed dangling skills/$name -> $ssot"
        else
          log_ok "Removed dangling link skills/$name"
        fi
        fixed=$((fixed + 1)) ;;
      SKILL_WRONG_TARGET)
        local ssot
        ssot=$(ssot_skill_path "$name")
        if [ -n "$ssot" ]; then
          rm -f "$skills_dir/$name"
          ln -s "$ssot" "$skills_dir/$name"
          log_ok "Repointed skills/$name -> $ssot (was $detail)"
        else
          mkdir -p "$scope_dir" "$backups"
          cp -R "$detail" "$backups/$name.orig" 2>/dev/null || true
          cp -R "$detail" "$scope_dir/$name"
          rm -f "$skills_dir/$name"
          ln -s "$scope_dir/$name" "$skills_dir/$name"
          log_ok "Imported off-SSOT skill '$name' to $scope_dir/$name and relinked"
        fi
        fixed=$((fixed + 1)) ;;
      MANAGED_PLUGINS_BAD)
        if [ -L "$managed_plugins" ]; then
          rm -f "$managed_plugins"
        elif [ -f "$managed_plugins" ]; then
          mkdir -p "$backups"
          cp "$managed_plugins" "$backups/managed-plugins.json"
          rm -f "$managed_plugins"
        fi
        ln -s "$source_plugins" "$managed_plugins"
        log_ok "Normalized managed-plugins.json -> $source_plugins"
        fixed=$((fixed + 1)) ;;
      PLUGIN_UNTRACKED)
        if ! command -v jq &>/dev/null; then
          log_err "jq required to register '$name', skipping"
        else
          mkdir -p "$backups"
          cp "$source_plugins" "$backups/plugins.json" 2>/dev/null || true
          local key="$name" mkt repo mgr stype tmp
          mkt="${key##*@}"
          repo=$(jq -r --arg m "$mkt" '.extraKnownMarketplaces[$m].source.repo // empty' "$settings" 2>/dev/null || true)
          if [ "$mkt" = "local" ]; then mgr="local"; stype="local"; else mgr="marketplace"; stype="github"; fi
          tmp=$(mktemp)
          jq --arg key "$key" --arg pname "${key%@*}" --arg repo "$repo" \
             --arg mgr "$mgr" --arg stype "$stype" \
             '. += [{
                "agent":"claude","enabled":true,"git_commit":"",
                "key":$key,"managed_by":$mgr,"name":$pname,"scope":"user",
                "source_repo":(if $repo=="" then null else $repo end),
                "source_type":$stype,"version":"unknown"
              }]' "$source_plugins" > "$tmp" && mv "$tmp" "$source_plugins"
          log_ok "Registered untracked plugin '$key' in plugins.json (repo=${repo:-none})"
          fixed=$((fixed + 1))
        fi ;;
      SETTINGS_DRIFT)
        if ! command -v jq &>/dev/null; then
          log_err "jq required to align '$name', skipping"
        else
          if [ "$settings_backed" -eq 0 ]; then
            mkdir -p "$backups"; cp "$settings" "$backups/settings.json"; settings_backed=1
          fi
          local key="$name" want tmp
          want=$(jq -r --arg k "$key" '.[] | select(.key==$k) | .enabled' "$source_plugins")
          tmp=$(mktemp)
          jq --arg k "$key" --argjson v "$want" '.enabledPlugins[$k] = $v' "$settings" > "$tmp" && mv "$tmp" "$settings"
          log_ok "Aligned settings.json enabledPlugins[$key] = $want"
          fixed=$((fixed + 1))
        fi ;;
    esac
  done <<< "$all"

  if [ -n "$fm" ]; then
    echo ""
    log_warn "Frontmatter issues need manual edit (not auto-fixed):"
    while IFS=$'\t' read -r type name detail hint; do
      [ -z "${type:-}" ] && continue
      log_warn "  $name: $detail"
    done <<< "$fm"
  fi

  echo ""
  log_ok "Fix applied $fixed change(s)."
  [ "$fixed" -gt 0 ] && log_info "Backups (if any): $backups"
  log_info "Re-run 'doctor' to confirm clean state"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
  echo -e "${CYAN}extra-sync v0.1.0${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  local do_pull=false
  local do_skills=false
  local do_plugins=false
  local do_remote=false
  local do_report=false
  local do_doctor=false
  local do_fix=false
  FIX_SCOPE=common

  # Pre-pass: capture --scope <value>
  local prev=""
  for arg in "$@"; do
    [ "$prev" = "--scope" ] && FIX_SCOPE="$arg"
    prev="$arg"
  done
  if [ "$FIX_SCOPE" != "common" ] && [ "$FIX_SCOPE" != "claude" ]; then
    echo "Invalid --scope: $FIX_SCOPE (use common|claude)"; exit 1
  fi

  if [ $# -eq 0 ] || [[ " $* " == *" --all "* ]]; then
    do_pull=true
    do_skills=true
    do_plugins=true
    do_remote=true
    do_report=true
  else
    prev=""
    for arg in "$@"; do
      # Consume the value token that follows --scope
      if [ "$prev" = "--scope" ]; then prev="$arg"; continue; fi
      case "$arg" in
        doctor)    do_doctor=true ;;
        fix)       do_fix=true ;;
        --scope)   : ;;
        --pull)    do_pull=true ;;
        --skills)  do_skills=true ;;
        --plugins) do_plugins=true ;;
        --remote)  do_remote=true ;;
        --report)  do_report=true ;;
        --all)     do_pull=true; do_skills=true; do_plugins=true; do_remote=true; do_report=true ;;
        *)         echo "Unknown option: $arg"; exit 1 ;;
      esac
      prev="$arg"
    done
  fi

  # Preflight checks
  if [ ! -d "$AGENTS_CONFIG" ]; then
    log_err "agents-config not found at $AGENTS_CONFIG"
    exit 1
  fi

  $do_pull    && pull_remote
  $do_skills  && sync_skills
  $do_plugins && sync_plugins
  $do_remote  && check_remote
  $do_report  && generate_report
  $do_doctor  && run_doctor
  $do_fix     && run_fix

  log_head "Done"
  log_ok "Completed at $(date '+%Y-%m-%d %H:%M:%S')"

  # doctor is CI-usable: non-zero exit when broken issues remain
  if $do_doctor && [ "${DOCTOR_ERR_COUNT:-0}" -gt 0 ]; then
    exit 1
  fi
}

main "$@"

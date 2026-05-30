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

  # Check and fix symlinks
  local links=(
    "common:$common_src"
    "local:$special_src"
    "special:$special_src"
  )

  for entry in "${links[@]}"; do
    local name="${entry%%:*}"
    local target="${entry#*:}"
    local link_path="$skills_dir/$name"

    if [ -L "$link_path" ]; then
      local current_target
      current_target=$(readlink "$link_path")
      if [ "$current_target" = "$target" ]; then
        log_ok "Symlink $name -> $target"
      else
        rm "$link_path"
        ln -s "$target" "$link_path"
        log_warn "Fixed symlink $name: $current_target -> $target"
      fi
    elif [ -e "$link_path" ]; then
      log_err "$link_path exists but is not a symlink, skipping"
    else
      mkdir -p "$target"
      ln -s "$target" "$link_path"
      log_ok "Created symlink $name -> $target"
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

  if [ $# -eq 0 ] || [[ " $* " == *" --all "* ]]; then
    do_pull=true
    do_skills=true
    do_plugins=true
    do_remote=true
    do_report=true
  else
    for arg in "$@"; do
      case "$arg" in
        --pull)    do_pull=true ;;
        --skills)  do_skills=true ;;
        --plugins) do_plugins=true ;;
        --remote)  do_remote=true ;;
        --report)  do_report=true ;;
        *)         echo "Unknown option: $arg"; exit 1 ;;
      esac
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

  log_head "Done"
  log_ok "Sync completed at $(date '+%Y-%m-%d %H:%M:%S')"
}

main "$@"

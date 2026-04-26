#!/usr/bin/env bash
set -euo pipefail

#########################################
# CONFIG
#########################################

DRUSH="ddev drush"
COMPOSER="ddev composer"

DRY_RUN=false
ALLOW_CORE=false
ALLOW_MAJOR=false

REPORT=()

#########################################
# HELPERS
#########################################

normalize_module_name() {
  [[ "$1" == drupal/* ]] && echo "$1" || echo "drupal/$1"
}

git_has_changes() {
  ! git diff --quiet || ! git diff --cached --quiet
}

run_cmd() {
  if $DRY_RUN; then
    echo "[DRY-RUN] $1"
  else
    eval "$1"
  fi
}

#########################################
# VERSION HELPERS
#########################################

get_installed_version() {
  $COMPOSER show "$1" --format=json \
    | jq -r '.versions[0]' 2>/dev/null || echo "unknown"
}

get_outdated_json() {
  local package="$1"
  shift || true
  $COMPOSER outdated "$package" --format=json "$@" 2>/dev/null || true
}

get_latest_same_major_version() {
  local json
  json=$(get_outdated_json "$1" --minor-only)
  if [[ -z "$json" ]]; then
    echo "unknown"
    return
  fi

  echo "$json" | jq -r '.latest // .versions[0] // "unknown"' 2>/dev/null || echo "unknown"
}

get_latest_available_version() {
  local json
  json=$(get_outdated_json "$1")
  if [[ -z "$json" ]]; then
    echo "unknown"
    return
  fi

  echo "$json" | jq -r '.latest // .versions[0] // "unknown"' 2>/dev/null || echo "unknown"
}

get_major() {
  echo "$1" | cut -d. -f1
}

#########################################
# FILTERS
#########################################

is_core_package() {
  case "$1" in
    drupal/core* ) return 0 ;;
    * ) return 1 ;;
  esac
}

#########################################
# OUTDATED MODULE LIST
#########################################

get_outdated_modules() {
  $COMPOSER outdated drupal/* --minor-only --format=json \
    | jq -r '.installed[] | select(.latest != .version) | .name'
}

#########################################
# UPDATE MODULE
#########################################

update_module() {

  RAW="$1"
  MODULE=$(normalize_module_name "$RAW")

  #########################################
  # Skip core
  #########################################

  if ! $ALLOW_CORE && is_core_package "$MODULE"; then
    echo "⏭ Skipping core package: $MODULE"
    return
  fi

  OLD_VERSION=$(get_installed_version "$MODULE")
  LATEST_SAME_MAJOR=$(get_latest_same_major_version "$MODULE")
  LATEST_AVAILABLE=$(get_latest_available_version "$MODULE")

  #########################################
  # Skip when only a major upgrade exists
  #########################################

  if ! $ALLOW_MAJOR && [[ "$LATEST_SAME_MAJOR" == "$OLD_VERSION" && "$LATEST_AVAILABLE" != "$OLD_VERSION" ]]; then
    echo "⏭ Skipping major upgrade: $MODULE ($OLD_VERSION -> $LATEST_AVAILABLE)"
    return
  fi

  #########################################
  # Nothing to do
  #########################################

  if [[ "$LATEST_SAME_MAJOR" == "$OLD_VERSION" || "$LATEST_SAME_MAJOR" == "unknown" ]]; then
    echo "ℹ️ No eligible update for $MODULE"
    return
  fi

  echo ""
  echo "========================================"
  echo "Updating $MODULE"
  echo "Target: $OLD_VERSION -> $LATEST_SAME_MAJOR"
  echo "========================================"

  #########################################
  # Composer update
  #########################################

  run_cmd "$COMPOSER update $MODULE"

  #########################################
  # Version after update
  #########################################

  if $DRY_RUN; then
    NEW_VERSION="?"
  else
    NEW_VERSION=$(get_installed_version "$MODULE")
  fi

  MESSAGE="Upgrading $MODULE ($OLD_VERSION => $NEW_VERSION)"

  #########################################
  # Drush
  #########################################

  run_cmd "$DRUSH updb -y"
  run_cmd "$DRUSH cex -y"

  #########################################
  # Commit
  #########################################

  if $DRY_RUN; then
    echo "[DRY-RUN] git add -A"
    echo "[DRY-RUN] git commit -m \"$MESSAGE\""
  else
    if git_has_changes; then
      git add -A
      git commit -m "$MESSAGE"
      REPORT+=("$MESSAGE")
      echo "✅ $MESSAGE"
    else
      echo "ℹ️ No changes"
    fi
  fi
}

#########################################
# ARG PARSER
#########################################

MODULE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --allow-core)
      ALLOW_CORE=true
      ;;
    --allow-major)
      ALLOW_MAJOR=true
      ;;
    *)
      MODULE_ARGS+=("$1")
      ;;
  esac
  shift
done

#########################################
# MAIN
#########################################

if [[ ${#MODULE_ARGS[@]} -gt 0 ]]; then
  MODULES=("${MODULE_ARGS[@]}")
else
  echo "🔍 Detecting outdated Drupal modules..."
  mapfile -t MODULES < <(get_outdated_modules)
fi

for MODULE in "${MODULES[@]}"; do
  update_module "$MODULE"
done

#########################################
# FINAL REPORT
#########################################

echo ""
echo "========================================"
echo "Upgrade Report"
echo "========================================"

if [[ ${#REPORT[@]} -eq 0 ]]; then
  echo "No upgrades performed."
else
  for LINE in "${REPORT[@]}"; do
    echo "$LINE"
  done
fi

echo ""
echo "🎉 Completed"

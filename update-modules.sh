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

  echo "$json" | jq -r '(.installed[0].latest // .latest // .versions[0] // "unknown")' 2>/dev/null || echo "unknown"
}

get_latest_available_version() {
  local json
  json=$(get_outdated_json "$1")
  if [[ -z "$json" ]]; then
    echo "unknown"
    return
  fi

  echo "$json" | jq -r '(.installed[0].latest // .latest // .versions[0] // "unknown")' 2>/dev/null || echo "unknown"
}

get_major() {
  echo "$1" | cut -d. -f1
}

get_minor() {
  echo "$1" | cut -d. -f2
}

normalize_version() {
  echo "${1#v}"
}

get_latest_patch_for_minor() {
  local package="$1"
  local major="$2"
  local minor="$3"

  $COMPOSER show "$package" --all --format=json \
    | jq -r --arg major "$major" --arg minor "$minor" '
        .versions[]
        | ltrimstr("v")
        | select(test("^" + $major + "\\." + $minor + "\\.[0-9]+$"))
      ' 2>/dev/null \
    | sort -V \
    | tail -n 1
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

order_modules_core_last() {
  local module
  local non_core_modules=()
  local has_core=false

  for module in "$@"; do
    if is_core_package "$(normalize_module_name "$module")"; then
      has_core=true
    else
      non_core_modules+=("$module")
    fi
  done

  MODULES=("${non_core_modules[@]}")

  if $has_core; then
    MODULES+=("drupal/core")
  fi
}

get_composer_update_dependency_option() {
  if is_core_package "$1"; then
    echo "--with-all-dependencies"
  else
    echo "--with-dependencies"
  fi
}

#########################################
# OUTDATED MODULE LIST
#########################################

get_outdated_modules() {
  if $ALLOW_MAJOR; then
    $COMPOSER outdated drupal/* --format=json \
      | jq -r '.installed[] | select(.latest != .version) | .name'
  else
    $COMPOSER outdated drupal/* --minor-only --format=json \
      | jq -r '.installed[] | select(.latest != .version) | .name'
  fi
}

#########################################
# DRUPAL/COMPOSER SAFETY HELPERS
#########################################

get_installed_drupal_module_packages() {
  $DRUSH cget core.extension module --format=json \
    | jq -r '."core.extension:module" | keys[] | "drupal/" + .'
}

get_locked_drupal_packages() {
  jq -r '.packages[] | select(.name | startswith("drupal/")) | [.name, .version] | @tsv' composer.lock
}

get_locked_package_version() {
  local package="$1"

  jq -r --arg package "$package" '
    ((.packages // []) + (."packages-dev" // []))
    | .[]
    | select(.name == $package)
    | .version
  ' composer.lock | head -n 1
}

get_locked_drupal_package_names() {
  jq -r '
    ((.packages // []) + (."packages-dev" // []))
    | .[]
    | select(.name | startswith("drupal/"))
    | .name
  ' composer.lock | sort -u
}

get_core_constraint_args() {
  local major="$1"
  local minor="$2"
  local package

  for package in drupal/core drupal/core-recommended drupal/core-composer-scaffold drupal/core-project-message; do
    if [[ -n "$(get_locked_package_version "$package")" ]]; then
      printf '%s ' "--with $package:~$major.$minor.0"
    fi
  done
}

version_to_constraint() {
  local version="${1#v}"
  local major minor

  if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\. ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"

    if [[ "$major" == "0" ]]; then
      echo "^0.$minor"
    else
      echo "^$major.$minor"
    fi
  else
    echo "$version"
  fi
}

composer_update_module_safely() {
  local module="$1"
  local target_version="${2:-}"
  local before_lock after_lock before_composer_json before_composer_lock installed_modules removed_packages protected_packages package version constraint old_locked_version new_locked_version dependency_option

  dependency_option=$(get_composer_update_dependency_option "$module")

  if $DRY_RUN; then
    if [[ -n "$target_version" && "$(get_major "$target_version")" != "$(get_major "$(get_installed_version "$module")")" ]]; then
      run_cmd "$COMPOSER require $module:$(version_to_constraint "$target_version") --no-update"
    fi
    run_cmd "$COMPOSER update $module $dependency_option --dry-run"
    return
  fi

  before_lock=$(mktemp)
  after_lock=$(mktemp)
  before_composer_json=$(mktemp)
  before_composer_lock=$(mktemp)
  installed_modules=$(mktemp)
  removed_packages=$(mktemp)

  cp composer.json "$before_composer_json"
  cp composer.lock "$before_composer_lock"
  old_locked_version=$(get_locked_package_version "$module")

  if [[ -n "$target_version" && "$(get_major "$target_version")" != "$(get_major "$old_locked_version")" ]]; then
    constraint=$(version_to_constraint "$target_version")
    echo "Allowing major upgrade for $module with root constraint $constraint"
    run_cmd "$COMPOSER require $module:$constraint --no-update"
  fi

  get_locked_drupal_packages | sort > "$before_lock"
  get_installed_drupal_module_packages | sort > "$installed_modules"

  if ! eval "$COMPOSER update $module $dependency_option --no-install"; then
    cp "$before_composer_json" composer.json
    cp "$before_composer_lock" composer.lock
    rm -f "$before_lock" "$after_lock" "$before_composer_json" "$before_composer_lock" "$installed_modules" "$removed_packages"
    echo "❌ Composer could not resolve $module. Skipping."
    return 1
  fi

  new_locked_version=$(get_locked_package_version "$module")

  if [[ "$new_locked_version" == "$old_locked_version" ]]; then
    cp "$before_composer_json" composer.json
    cp "$before_composer_lock" composer.lock
    rm -f "$before_lock" "$after_lock" "$before_composer_json" "$before_composer_lock" "$installed_modules" "$removed_packages"
    echo "ℹ️ Composer did not change $module in composer.lock; skipping Drush and commit."
    return 1
  fi

  get_locked_drupal_packages | sort > "$after_lock"

  comm -23 \
    <(cut -f1 "$before_lock" | sort) \
    <(cut -f1 "$after_lock" | sort) \
    | while read -r package; do
        if grep -qx "$package" "$installed_modules"; then
          grep -F -m 1 "$package"$'\t' "$before_lock"
        fi
      done > "$removed_packages"

  if [[ -s "$removed_packages" ]]; then
    echo "⚠️ Composer would remove installed Drupal module code. Keeping these packages:"

    protected_packages=()
    while IFS=$'\t' read -r package version; do
      constraint=$(version_to_constraint "$version")
      echo "  - $package ($version, adding root constraint $constraint)"
      run_cmd "$COMPOSER require $package:$constraint --no-update"
      protected_packages+=("$package")
    done < "$removed_packages"

    run_cmd "$COMPOSER update $module ${protected_packages[*]} $dependency_option"
  else
    run_cmd "$COMPOSER install"
  fi

  rm -f "$before_lock" "$after_lock" "$before_composer_json" "$before_composer_lock" "$installed_modules" "$removed_packages"
}

composer_update_core_to_minor_safely() {
  local target_version="$1"
  local major minor before_composer_json before_composer_lock old_locked_version new_locked_version package_args constraint_args

  major=$(get_major "$target_version")
  minor=$(get_minor "$target_version")
  package_args=$(get_locked_drupal_package_names | tr '\n' ' ')
  constraint_args=$(get_core_constraint_args "$major" "$minor")

  if $DRY_RUN; then
    run_cmd "$COMPOSER update $package_args$constraint_args--with-all-dependencies --dry-run"
    return
  fi

  before_composer_json=$(mktemp)
  before_composer_lock=$(mktemp)

  cp composer.json "$before_composer_json"
  cp composer.lock "$before_composer_lock"
  old_locked_version=$(get_locked_package_version "drupal/core")

  if ! $COMPOSER update $package_args$constraint_args--with-all-dependencies --no-install; then
    cp "$before_composer_json" composer.json
    cp "$before_composer_lock" composer.lock
    rm -f "$before_composer_json" "$before_composer_lock"
    echo "❌ Composer could not resolve Drupal core $major.$minor.x. Stopping core updates."
    return 1
  fi

  new_locked_version=$(get_locked_package_version "drupal/core")

  if [[ "$new_locked_version" == "$old_locked_version" ]]; then
    cp "$before_composer_json" composer.json
    cp "$before_composer_lock" composer.lock
    rm -f "$before_composer_json" "$before_composer_lock"
    echo "ℹ️ Composer did not change drupal/core in composer.lock. Stopping core updates."
    return 1
  fi

  if [[ "$new_locked_version" != "$(normalize_version "$target_version")" ]]; then
    cp "$before_composer_json" composer.json
    cp "$before_composer_lock" composer.lock
    rm -f "$before_composer_json" "$before_composer_lock"
    echo "❌ Composer resolved drupal/core $new_locked_version instead of $target_version. Stopping core updates."
    return 1
  fi

  if ! $COMPOSER install; then
    cp "$before_composer_json" composer.json
    cp "$before_composer_lock" composer.lock
    rm -f "$before_composer_json" "$before_composer_lock"
    echo "❌ Composer install failed after resolving Drupal core $target_version. Stopping core updates."
    return 1
  fi

  rm -f "$before_composer_json" "$before_composer_lock"
}

get_core_update_targets() {
  local current_version="$1"
  local final_version="$2"
  local major current_minor final_minor minor target

  major=$(get_major "$current_version")
  current_minor=$(get_minor "$current_version")
  final_minor=$(get_minor "$final_version")

  for ((minor = current_minor; minor <= final_minor; minor++)); do
    target=$(get_latest_patch_for_minor "drupal/core-recommended" "$major" "$minor")

    if [[ -z "$target" ]]; then
      echo "unknown"
      return
    fi

    if [[ "$target" != "$current_version" ]]; then
      echo "$target"
      current_version="$target"
    fi
  done
}

commit_update() {
  local module="$1"
  local old_version="$2"
  local new_version="$3"
  local message

  message="Upgrading $module ($old_version => $new_version)"

  if $DRY_RUN; then
    echo "[DRY-RUN] git add -A"
    echo "[DRY-RUN] git commit -m \"$message\""
  else
    if git_has_changes; then
      git add -A
      git commit -m "$message"
      REPORT+=("$message")
      echo "✅ $message"
    else
      echo "ℹ️ No changes"
    fi
  fi
}

run_site_health_check() {
  if $DRY_RUN; then
    run_cmd "$DRUSH status"
  else
    $DRUSH status
  fi
}

update_core() {
  local old_version latest_same_major latest_available target current_version new_version
  local -a targets

  if ! $ALLOW_CORE; then
    echo "⏭ Skipping core package: drupal/core"
    return
  fi

  old_version=$(get_installed_version "drupal/core")
  latest_same_major=$(get_latest_same_major_version "drupal/core")
  latest_available=$(get_latest_available_version "drupal/core")

  if ! $ALLOW_MAJOR && [[ "$latest_same_major" == "$old_version" && "$latest_available" != "$old_version" ]]; then
    echo "⏭ Skipping major upgrade: drupal/core ($old_version -> $latest_available)"
    return
  fi

  if $ALLOW_MAJOR; then
    latest_same_major="$latest_available"
  fi

  if [[ "$latest_same_major" == "$old_version" || "$latest_same_major" == "unknown" ]]; then
    echo "ℹ️ No eligible update for drupal/core"
    return
  fi

  mapfile -t targets < <(get_core_update_targets "$old_version" "$latest_same_major")

  if [[ ${#targets[@]} -eq 0 || "${targets[0]}" == "unknown" ]]; then
    echo "❌ Could not build Drupal core minor update steps. Stopping core updates."
    return 1
  fi

  current_version="$old_version"

  for target in "${targets[@]}"; do
    echo ""
    echo "========================================"
    echo "Updating drupal/core"
    echo "Target: $current_version -> $target"
    echo "========================================"

    if ! composer_update_core_to_minor_safely "$target"; then
      return 1
    fi

    if $DRY_RUN; then
      new_version="$target"
    else
      new_version=$(get_installed_version "drupal/core")
    fi

    run_cmd "$DRUSH updb -y"
    run_cmd "$DRUSH cex -y"

    echo "Checking site status..."
    if ! run_site_health_check; then
      echo "❌ Drush status failed after core update to $new_version. Stopping core updates."
      return 1
    fi

    commit_update "drupal/core" "$current_version" "$new_version"
    current_version="$new_version"
  done
}

#########################################
# UPDATE MODULE
#########################################

update_module() {

  RAW="$1"
  MODULE=$(normalize_module_name "$RAW")
  TARGET_VERSION=""

  if is_core_package "$MODULE"; then
    update_core
    return
  fi

  OLD_VERSION=$(get_installed_version "$MODULE")
  LATEST_SAME_MAJOR=$(get_latest_same_major_version "$MODULE")
  LATEST_AVAILABLE=$(get_latest_available_version "$MODULE")
  TARGET_VERSION="$LATEST_SAME_MAJOR"

  if $ALLOW_MAJOR; then
    TARGET_VERSION="$LATEST_AVAILABLE"
  fi

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

  if [[ "$TARGET_VERSION" == "$OLD_VERSION" || "$TARGET_VERSION" == "unknown" ]]; then
    echo "ℹ️ No eligible update for $MODULE"
    return
  fi

  echo ""
  echo "========================================"
  echo "Updating $MODULE"
  echo "Target: $OLD_VERSION -> $TARGET_VERSION"
  echo "========================================"

  #########################################
  # Composer update
  #########################################

  if ! composer_update_module_safely "$MODULE" "$TARGET_VERSION"; then
    return
  fi

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

order_modules_core_last "${MODULES[@]}"

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

#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Variables.conf
source "$PROJECT_ROOT/Variables.conf"

STABLE_PATH="stable_source"
BETA_PATH="beta_source"
PIXEL_PATH="pixel"
KERNEL_PATH="$PROJECT_ROOT/$PIXEL_PATH"
AOSP_PATH="$KERNEL_PATH/common/ack"

log() {
  printf '\n[+] %s\n' "$1"
}

debug() {
  printf '    %s\n' "$1"
}

die() {
  printf '\n[!] %s\n' "$1" >&2
  exit 1
}

gitmodules_get() {
  git -C "$PROJECT_ROOT" config -f .gitmodules --get "$1" 2>/dev/null || true
}

require_git() {
  command -v git >/dev/null 2>&1 || die "git не найден"
}

require_repo() {
  git -C "$PROJECT_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || die "нужен git clone этого репозитория"
}

reexec_if_repo_updated() {
  local old_head="$1"
  local new_head

  new_head="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  [[ "$old_head" != "$new_head" ]] || return 0
  [[ "${UPDATE_REPO_REEXEC:-0}" == "1" ]] && return 0

  log "self-update"
  debug "repo updated: $old_head -> $new_head"
  debug "restart update_repo.sh once to apply new script logic"
  exec env UPDATE_REPO_REEXEC=1 "$PROJECT_ROOT/update_repo.sh" "$@"
}

load_config() {
  unset STABLE_BRANCH BETA_BRANCH PIXEL_TAG PIXEL_COMMIT
  # shellcheck source=Variables.conf
  source "$PROJECT_ROOT/Variables.conf"
  STABLE_BRANCH="${STABLE_BRANCH:-$(gitmodules_get "submodule.$STABLE_PATH.branch")}"
  BETA_BRANCH="${BETA_BRANCH:-$(gitmodules_get "submodule.$BETA_PATH.branch")}"
  STABLE_URL="$(gitmodules_get "submodule.$STABLE_PATH.url")"
  BETA_URL="$(gitmodules_get "submodule.$BETA_PATH.url")"
  PIXEL_URL="$(gitmodules_get "submodule.$PIXEL_PATH.url")"
  [[ -n "$STABLE_BRANCH" ]] || die "не задан STABLE_BRANCH"
  [[ -n "$BETA_BRANCH" ]] || die "не задан BETA_BRANCH"
  [[ -n "$STABLE_URL" ]] || die "не найден submodule.$STABLE_PATH.url в .gitmodules"
  [[ -n "$BETA_URL" ]] || die "не найден submodule.$BETA_PATH.url в .gitmodules"
  [[ -n "$PIXEL_TAG" ]] || die "не задан PIXEL_TAG"
  [[ -n "$PIXEL_COMMIT" ]] || die "не задан PIXEL_COMMIT"
  [[ -n "$PIXEL_URL" ]] || die "не найден submodule.$PIXEL_PATH.url в .gitmodules"
  log "config"
  debug "stable: $STABLE_PATH <- $STABLE_BRANCH"
  debug "beta:   $BETA_PATH <- $BETA_BRANCH"
  debug "pixel:  $PIXEL_PATH <- $PIXEL_COMMIT (tag fallback: $PIXEL_TAG)"
}

path_root() {
  cd "$PROJECT_ROOT/$1" 2>/dev/null && pwd -P
}

repo_root() {
  git -C "$PROJECT_ROOT/$1" rev-parse --show-toplevel 2>/dev/null || true
}

is_repo_at_path() {
  local path="$1"
  local expected
  local actual
  expected="$(path_root "$path")" || return 1
  actual="$(repo_root "$path")"
  [[ -n "$actual" && "$actual" == "$expected" ]]
}

dir_is_empty() {
  [[ -d "$1" ]] && [[ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

ensure_repo_target() {
  local path="$1"
  local abs_path="$PROJECT_ROOT/$path"
  [[ ! -e "$abs_path" ]] && return
  is_repo_at_path "$path" && return
  dir_is_empty "$abs_path" && return
  die "'$path' уже существует, но это не отдельный git-репозиторий"
}

set_origin() {
  local path="$1"
  local url="$2"
  if git -C "$PROJECT_ROOT/$path" remote get-url origin >/dev/null 2>&1; then
    git -C "$PROJECT_ROOT/$path" remote set-url origin "$url"
  else
    git -C "$PROJECT_ROOT/$path" remote add origin "$url"
  fi
}

verify_commit() {
  local path="$1"
  local expected="$2"
  local current
  current="$(git -C "$PROJECT_ROOT/$path" rev-parse HEAD)"
  [[ "$current" == "$expected" ]] || die "'$path': ожидался $expected, получен $current"
}

current_head() {
  git -C "$PROJECT_ROOT/$1" rev-parse HEAD 2>/dev/null || true
}

is_shallow_repo() {
  [[ "$(git -C "$PROJECT_ROOT/$1" rev-parse --is-shallow-repository 2>/dev/null || printf false)" == "true" ]]
}

ensure_pixel_commit_available() {
  git -C "$PROJECT_ROOT/$PIXEL_PATH" cat-file -e "$PIXEL_COMMIT^{commit}" 2>/dev/null && return
  debug "fetch missing tag $PIXEL_TAG"
  git -C "$PROJECT_ROOT/$PIXEL_PATH" fetch --force origin "refs/tags/$PIXEL_TAG:refs/tags/$PIXEL_TAG"
  git -C "$PROJECT_ROOT/$PIXEL_PATH" cat-file -e "$PIXEL_COMMIT^{commit}" 2>/dev/null || \
    die "'$PIXEL_PATH': commit $PIXEL_COMMIT не найден после fetch"
}

sync_pixel_repo() {
  set_origin "$PIXEL_PATH" "$PIXEL_URL"

  if is_shallow_repo "$PIXEL_PATH"; then
    debug "convert shallow pixel repo to full history"
    git -C "$PROJECT_ROOT/$PIXEL_PATH" fetch --unshallow --tags origin
  else
    debug "fetch full pixel repo updates"
    git -C "$PROJECT_ROOT/$PIXEL_PATH" fetch --prune --tags origin
  fi

  ensure_pixel_commit_available
  debug "checkout pinned pixel commit"
  git -C "$PROJECT_ROOT/$PIXEL_PATH" checkout --detach "$PIXEL_COMMIT"
}

clean_repo() {
  local path="$1"
  is_repo_at_path "${path#"$PROJECT_ROOT/"}" || return
  debug "reset + clean: $path"
  git -C "$path" reset --hard HEAD
  git -C "$path" clean -fdx
}

clean_workspace() {
  log "clean"
  debug "umount bind if mounted: $AOSP_PATH"
  sudo umount "$AOSP_PATH" 2>/dev/null || true
  debug "remove temp dirs: susfs4ksu KPatch-Next output AnyKernel3"
  rm -rf "$PROJECT_ROOT/susfs4ksu" "$PROJECT_ROOT/KPatch-Next" "$PROJECT_ROOT/output" "$PROJECT_ROOT/AnyKernel3" 2>/dev/null || true

  for path in "$STABLE_PATH" "$BETA_PATH"; do
    clean_repo "$PROJECT_ROOT/$path"
    debug "remove overlay dirs from $path"
    rm -rf "$PROJECT_ROOT/$path/Baseband-guard" "$PROJECT_ROOT/$path/KernelSU-Next" 2>/dev/null || true
  done

  clean_repo "$KERNEL_PATH"
}

update_main_repo() {
  local old_head
  old_head="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"

  log "repo"
  debug "reset + clean root repo"
  git -C "$PROJECT_ROOT" reset --hard HEAD
  git -C "$PROJECT_ROOT" clean -fdx
  debug "fetch origin"
  git -C "$PROJECT_ROOT" fetch --prune origin
  debug "pull --ff-only without submodule recursion"
  git -C "$PROJECT_ROOT" pull --ff-only --recurse-submodules=no
  reexec_if_repo_updated "$old_head" "$@"
}

update_branch_submodule() {
  local path="$1"
  local branch="$2"
  local url="$3"
  ensure_repo_target "$path"
  log "$path <- $branch"

  if is_repo_at_path "$path"; then
    debug "reuse existing repo"
    set_origin "$path" "$url"
    debug "fetch branch head with --depth 1"
    git -C "$PROJECT_ROOT/$path" fetch --depth 1 --no-tags origin "refs/heads/$branch"
    debug "checkout fetched branch head"
    git -C "$PROJECT_ROOT/$path" checkout -B "$branch" FETCH_HEAD
  else
    debug "clone branch with --depth 1 --single-branch"
    git -C "$PROJECT_ROOT" clone \
      --depth 1 \
      --single-branch \
      --branch "$branch" \
      --no-recurse-submodules \
      "$url" \
      "$path"
  fi

  debug "HEAD: $(git -C "$PROJECT_ROOT/$path" rev-parse --short HEAD)"
}

recreate_pixel() {
  ensure_repo_target "$PIXEL_PATH"

  if is_repo_at_path "$PIXEL_PATH"; then
    local current
    current="$(current_head "$PIXEL_PATH")"
    if [[ "$current" == "$PIXEL_COMMIT" ]] && ! is_shallow_repo "$PIXEL_PATH"; then
      debug "$PIXEL_PATH already at expected commit"
      debug "HEAD: $(git -C "$PROJECT_ROOT/$PIXEL_PATH" rev-parse --short HEAD)"
      return
    fi

    log "$PIXEL_PATH <- $PIXEL_COMMIT"
    if [[ -n "$current" ]]; then
      debug "current pixel HEAD: ${current:0:9}"
    else
      debug "pixel repo is broken or half-initialized, recreate it"
    fi
    sync_pixel_repo
    verify_commit "$PIXEL_PATH" "$PIXEL_COMMIT"
    debug "HEAD: $(git -C "$PROJECT_ROOT/$PIXEL_PATH" rev-parse --short HEAD)"
    return
  else
    log "$PIXEL_PATH <- $PIXEL_COMMIT"
  fi

  debug "clone full pixel repo"
  git -C "$PROJECT_ROOT" clone --no-recurse-submodules "$PIXEL_URL" "$PIXEL_PATH"
  ensure_pixel_commit_available
  debug "checkout pinned pixel commit"
  git -C "$PROJECT_ROOT/$PIXEL_PATH" checkout --detach "$PIXEL_COMMIT"
  verify_commit "$PIXEL_PATH" "$PIXEL_COMMIT"
  debug "HEAD: $(git -C "$PROJECT_ROOT/$PIXEL_PATH" rev-parse --short HEAD)"
}

main() {
  require_git
  require_repo
  load_config
  clean_workspace
  update_main_repo "$@"
  debug "reload config after root repo update"
  load_config
  update_branch_submodule "$STABLE_PATH" "$STABLE_BRANCH" "$STABLE_URL"
  update_branch_submodule "$BETA_PATH" "$BETA_BRANCH" "$BETA_URL"
  recreate_pixel
  log "готово"
}

main "$@"

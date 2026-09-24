#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
ux_stage="initialization"
report_failure() {
  status="$?"
  trap - ERR
  if test "${GITHUB_ACTIONS:-}" = true; then
    printf '::error title=UX integration tests failed::%s (exit %s)\n' \
      "$ux_stage" "$status"
  fi
  exit "$status"
}
trap report_failure ERR

# The repository root is resolved dynamically.
# shellcheck disable=SC1091
source "$repo_root/tests/ux-pins.env"

# Candidates, in order: an explicit *_ROOT override, a sibling checkout named
# after the upstream repository, the zemrip canonical clone under $HOME (the
# common case for an agent worktree, which lives two directories deeper), and
# the legacy operator paths. Read-only: only the pinned commit's ancestry is
# checked, so a canonical coordination clone is safe to use.
resolve_checkout() {
  local configured="$1"
  shift
  if [[ -n "$configured" ]]; then
    test -d "$configured"
    printf '%s\n' "$configured"
    return
  fi
  local candidate
  for candidate in "$@"; do
    if [[ -d "$candidate/.git" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  return 1
}

ux_stage="pinned UX checkout discovery"
foundation_root="$(resolve_checkout "${UX_FOUNDATION_ROOT:-}" \
  "$repo_root/UX-foundation.nvim" \
  "$(dirname "$repo_root")/UX-foundation.nvim" \
  "${HOME:-/home/ai}/nvim-foundation" \
  "/home/ai/ux-foundation")" || {
    echo "UX Foundation checkout not found; set UX_FOUNDATION_ROOT" >&2
    exit 1
  }
styling_root="$(resolve_checkout "${UX_STYLING_ROOT:-}" \
  "$repo_root/UX-styling.nvim" \
  "$(dirname "$repo_root")/UX-styling.nvim" \
  "${HOME:-/home/ai}/nvim-styler" \
  "/home/ai/ux-styling")" || {
    echo "UX Styling checkout not found; set UX_STYLING_ROOT" >&2
    exit 1
  }
chrome_root="$(resolve_checkout "${UX_CHROME_ROOT:-}" \
  "$repo_root/UX-chrome.nvim" \
  "$(dirname "$repo_root")/UX-chrome.nvim" \
  "${HOME:-/home/ai}/nvim-chrome" \
  "/home/ai/ux-chrome")" || {
    echo "UX Chrome checkout not found; set UX_CHROME_ROOT" >&2
    exit 1
  }

require_pin() {
  local checkout="$1"
  local pin="$2"
  local label="$3"
  if ! git -C "$checkout" cat-file -e "$pin^{commit}" 2>/dev/null \
    || ! git -C "$checkout" merge-base --is-ancestor "$pin" HEAD; then
    echo "$label checkout does not contain required promoted pin $pin" >&2
    exit 1
  fi
}

require_pin "$foundation_root" "$UX_FOUNDATION_PIN" "UX Foundation"
require_pin "$styling_root" "$UX_STYLING_PIN" "UX Styling"
require_pin "$chrome_root" "$UX_CHROME_PIN" "UX Chrome"

ux_stage="Foundation manifest validation"
nvim --headless --clean \
  -l "$foundation_root/scripts/validate-manifest.lua" \
  "$repo_root/lua/agent_manager/presentation.lua"

common_env=(
  "AGENT_MANAGER_TEST_ROOT=$repo_root"
  "UX_FOUNDATION_ROOT=$foundation_root"
  "UX_STYLING_ROOT=$styling_root"
  "UX_CHROME_ROOT=$chrome_root"
)

ux_stage="Foundation integration"
env "${common_env[@]}" nvim --headless -u NONE -i NONE \
  -l "$repo_root/tests/lua/m3_foundation.lua"
ux_stage="Styling integration"
env "${common_env[@]}" nvim --headless -u NONE -i NONE \
  -l "$repo_root/tests/lua/m3_styling.lua"
ux_stage="Chrome integration"
env "${common_env[@]}" nvim --headless -u NONE -i NONE \
  -l "$repo_root/tests/lua/m3_chrome.lua"

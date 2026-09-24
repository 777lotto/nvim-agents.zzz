#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
phase="$repo_root/ops/m5-release-install"
artifact_dir="${RELEASE_TEST_ARTIFACT_DIR:?RELEASE_TEST_ARTIFACT_DIR is required}"
read -r release_version release_target < <(
  "$repo_root/python/.venv/bin/python" -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    compatibility = json.load(handle)
print(compatibility["release_version"], compatibility["target"])
' "$repo_root/release/compatibility-v1.json"
)
archive="$artifact_dir/agent-manager-v${release_version}-${release_target}.tar.gz"
checksums="$artifact_dir/SHA256SUMS"
test -f "$archive"
test -f "$checksums"

test_root="$(mktemp -d)"
cleanup() {
  if test -d "$test_root"; then
    find "$test_root" -depth -delete
  fi
}
trap cleanup EXIT

install_root="$test_root/share/agent-manager"
releases_dir="$install_root/releases"
release_dir="$releases_dir/v${release_version}-${release_target}"
broker_link="$test_root/bin/agent-manager-broker"
venv_link="$install_root/venv"
state_root="$test_root/state"
state_dir="$state_root/v${release_version}-${release_target}"
status_file="$state_dir/status.json"
env_file="$test_root/m5-test.env"

mkdir -p "$releases_dir/v0.0.0/bin" "$releases_dir/v0.0.0/python" \
  "$(dirname -- "$broker_link")"
printf 'old broker\n' >"$releases_dir/v0.0.0/bin/agent-manager-broker"
ln -s "$releases_dir/v0.0.0/bin/agent-manager-broker" "$broker_link"
ln -s "$releases_dir/v0.0.0/python" "$venv_link"

{
  printf 'SERVICE_USER=%s\n' "$(id -un)"
  printf 'SERVICE_GROUP=%s\n' "$(id -gn)"
  printf 'SERVICE_UNIT=agent-manager-m5-test.service\n'
  printf 'SERVICE_STATE_CHECK=test-none\n'
  printf 'REQUIRE_CLEAN_SOURCE=0\n'
  printf 'RELEASE_VERSION=%s\n' "$release_version"
  printf 'RELEASE_TARGET=%s\n' "$release_target"
  printf 'RELEASE_ARCHIVE=%s\n' "$archive"
  printf 'RELEASE_CHECKSUMS=%s\n' "$checksums"
  printf 'RELEASE_SOURCE_REVISION=%s\n' "$(git -C "$repo_root" rev-parse HEAD)"
  printf 'PYTHON_BIN=%s\n' "$repo_root/python/.venv/bin/python"
  printf 'INSTALL_ROOT=%s\n' "$install_root"
  printf 'RELEASES_DIR=%s\n' "$releases_dir"
  printf 'RELEASE_DIR=%s\n' "$release_dir"
  printf 'BROKER_LINK=%s\n' "$broker_link"
  printf 'VENV_LINK=%s\n' "$venv_link"
  printf 'STATE_ROOT=%s\n' "$state_root"
  printf 'STATE_DIR=%s\n' "$state_dir"
  printf 'STATUS_FILE=%s\n' "$status_file"
} >"$env_file"

export M5_ENV_FILE="$env_file"
"$phase/00-preflight.sh"
"$phase/10-install-release.sh"
"$phase/10-install-release.sh"
"$phase/20-activate-release.sh"
"$phase/20-activate-release.sh"
"$phase/90-verify.sh"

test "$(readlink -- "$broker_link")" = "$release_dir/bin/agent-manager-broker"
test "$(readlink -- "$venv_link")" = "$release_dir/python"
test -s "$status_file"
grep '"last_error": null' "$status_file" >/dev/null
grep '"workflow_runtime_verified": true' "$status_file" >/dev/null
"$venv_link/bin/python" -B -I -m agent_manager_workflows --help >/dev/null
# The queue entrypoint must leave the immutable payload verifiable.
"$phase/90-verify.sh"

"$phase/undo-20.sh"
"$phase/undo-20.sh"
test "$(readlink -- "$broker_link")" = "$releases_dir/v0.0.0/bin/agent-manager-broker"
test "$(readlink -- "$venv_link")" = "$releases_dir/v0.0.0/python"
"$phase/undo-10.sh"
"$phase/undo-10.sh"
test ! -e "$release_dir"

unset M5_ENV_FILE
portable="$test_root/portable"
portable_data="$portable/data"
portable_state="$portable/state"
portable_bin="$portable/bin"
portable_env=(
  XDG_DATA_HOME="$portable_data"
  XDG_STATE_HOME="$portable_state"
  XDG_BIN_HOME="$portable_bin"
  AGENT_MANAGER_RELEASE_ASSET_DIR="$artifact_dir"
  AGENT_MANAGER_TEST_ALLOW_DIRTY_RELEASE=1
  AGENT_MANAGER_VERIFY_PYTHON="$repo_root/python/.venv/bin/python"
)
env "${portable_env[@]}" "$phase/install-current.sh"
env "${portable_env[@]}" "$phase/install-current.sh"
test -x "$portable_bin/agent-manager-broker"
test -x "$portable_data/agent-manager/venv/bin/python"
env "${portable_env[@]}" "$phase/undo-current.sh"
test ! -e "$portable_bin/agent-manager-broker"
test ! -L "$portable_bin/agent-manager-broker"
test ! -e "$portable_data/agent-manager/venv"
test ! -L "$portable_data/agent-manager/venv"

printf 'PASS release install apply, verify, idempotence, and paired undo\n'

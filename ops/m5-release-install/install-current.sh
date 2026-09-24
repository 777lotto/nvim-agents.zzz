#!/usr/bin/env bash
# Lazy/package-manager adapter for the independently resumable M5 phases.
# It prepares a machine-specific absolute environment, obtains the immutable
# release assets when needed, then runs the same numbered apply/verify steps an
# operator can rerun individually.
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$phase_dir/../.." && pwd)"
cd -- "$repo_root"

log() {
  printf 'agent-manager install: %s\n' "$1"
}

fail() {
  printf 'agent-manager install: FAIL %s\n' "$1" >&2
  exit 1
}

for required_command in realpath install flock; do
  command -v "$required_command" >/dev/null \
    || fail "$required_command is required for runtime installation"
done

verify_python="${AGENT_MANAGER_VERIFY_PYTHON:-}"
if test -z "$verify_python"; then
  verify_python="$(command -v python3 || true)"
fi
test -n "$verify_python" && test -x "$verify_python" \
  || fail "Python 3.11 or newer is required to verify the release archive"
"$verify_python" -c 'import sys; raise SystemExit(sys.version_info < (3, 11))' \
  || fail "Python 3.11 or newer is required to verify the release archive"
verify_python="$(realpath -m -s -- "$verify_python")"

read -r release_version release_target < <(
  "$verify_python" -c '
import json
from pathlib import Path

compatibility = json.loads(Path("release/compatibility-v1.json").read_text(encoding="utf-8"))
print(compatibility["release_version"], compatibility["target"])
' </dev/null
)
test -n "$release_version" && test -n "$release_target" \
  || fail "release compatibility metadata is incomplete"
test "$(uname -s)" = Linux && test "$(uname -m)" = x86_64 \
  || fail "release $release_version supports Linux x86_64 only"

release_revision="${AGENT_MANAGER_RELEASE_SOURCE_REVISION:-}"
if test -z "$release_revision"; then
  command -v git >/dev/null || fail "Git is required to identify the plugin revision"
  release_revision="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
fi
[[ "$release_revision" =~ ^[0-9a-f]{40}$ ]] \
  || fail "the release source revision could not be determined"

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
bin_home="${XDG_BIN_HOME:-$HOME/.local/bin}"
install_root="$(realpath -m -s -- "$data_home/agent-manager")"
releases_dir="$install_root/releases"
release_dir="$releases_dir/v${release_version}-${release_target}"
download_dir="$install_root/downloads/v${release_version}"
archive_name="agent-manager-v${release_version}-${release_target}.tar.gz"
archive="$download_dir/$archive_name"
checksums="$download_dir/SHA256SUMS"
broker_link="$(realpath -m -s -- "$bin_home/agent-manager-broker")"
venv_link="$install_root/venv"
state_root="$(realpath -m -s -- "$state_home/agent-manager/release-install")"
state_dir="$state_root/v${release_version}-${release_target}"
status_file="$state_dir/status.json"
env_file="$state_dir/install.env"
asset_dir="${AGENT_MANAGER_RELEASE_ASSET_DIR:-}"
require_clean_source=1
case "${AGENT_MANAGER_REQUIRE_ATTESTATION:-0}" in
  0) ;;
  1) ;;
  *) fail "AGENT_MANAGER_REQUIRE_ATTESTATION must be 0 or 1" ;;
esac
case "${AGENT_MANAGER_TEST_ALLOW_DIRTY_RELEASE:-0}" in
  0) ;;
  1)
    test -n "$asset_dir" \
      || fail "dirty release fixtures are allowed only with AGENT_MANAGER_RELEASE_ASSET_DIR"
    require_clean_source=0
    ;;
  *) fail "AGENT_MANAGER_TEST_ALLOW_DIRTY_RELEASE must be 0 or 1" ;;
esac

for absolute in \
  "$install_root" "$releases_dir" "$release_dir" "$download_dir" \
  "$broker_link" "$venv_link" "$state_root" "$state_dir" "$status_file"; do
  test "${absolute:0:1}" = / && test "$absolute" = "$(realpath -m -s -- "$absolute")" \
    || fail "derived path is not absolute and canonical: $absolute"
done

install -d -m 0700 "$state_dir"
install -d -m 0755 "$download_dir" "$(dirname -- "$broker_link")"
exec 9>"$state_dir/install.lock"
flock 9

service_state_check=test-none
if command -v systemctl >/dev/null \
  && systemctl --user show --property=ActiveState --value agent-manager-broker.service \
    >/dev/null 2>&1; then
  service_state_check=systemd
fi

write_env() {
  local output="$1"
  umask 077
  {
    printf 'SERVICE_USER=%q\n' "$(id -un)"
    printf 'SERVICE_GROUP=%q\n' "$(id -gn)"
    printf 'SERVICE_UNIT=%q\n' agent-manager-broker.service
    printf 'SERVICE_STATE_CHECK=%q\n' "$service_state_check"
    printf 'REQUIRE_CLEAN_SOURCE=%q\n' "$require_clean_source"
    printf 'RELEASE_VERSION=%q\n' "$release_version"
    printf 'RELEASE_TARGET=%q\n' "$release_target"
    printf 'RELEASE_ARCHIVE=%q\n' "$archive"
    printf 'RELEASE_CHECKSUMS=%q\n' "$checksums"
    printf 'RELEASE_SOURCE_REVISION=%q\n' "$release_revision"
    printf 'PYTHON_BIN=%q\n' "$verify_python"
    printf 'INSTALL_ROOT=%q\n' "$install_root"
    printf 'RELEASES_DIR=%q\n' "$releases_dir"
    printf 'RELEASE_DIR=%q\n' "$release_dir"
    printf 'BROKER_LINK=%q\n' "$broker_link"
    printf 'VENV_LINK=%q\n' "$venv_link"
    printf 'STATE_ROOT=%q\n' "$state_root"
    printf 'STATE_DIR=%q\n' "$state_dir"
    printf 'STATUS_FILE=%q\n' "$status_file"
  } >"$output"
}

temporary_env="$env_file.tmp.$$"
test ! -e "$temporary_env" && test ! -L "$temporary_env" \
  || fail "preserve unexpected environment staging path: $temporary_env"
write_env "$temporary_env"
mv -T -- "$temporary_env" "$env_file"

if test -L "$broker_link" && test "$(readlink -- "$broker_link")" = "$release_dir/bin/agent-manager-broker" \
  && test -L "$venv_link" && test "$(readlink -- "$venv_link")" = "$release_dir/python" \
  && test "${AGENT_MANAGER_REQUIRE_ATTESTATION:-0}" = 0; then
  if M5_ENV_FILE="$env_file" "$phase_dir/90-verify.sh"; then
    log "release v$release_version is already active; no download or activation needed"
    exit 0
  fi
  fail "the active v$release_version runtime failed verification"
fi

if test -n "$asset_dir"; then
  asset_dir="$(realpath -m -s -- "$asset_dir")"
  test -d "$asset_dir" || fail "release asset directory is unavailable: $asset_dir"
  archive="$asset_dir/$archive_name"
  checksums="$asset_dir/SHA256SUMS"
else
  metadata="$repo_root/scripts/release_metadata.py"
  if ! "$verify_python" "$metadata" verify-archive \
    --archive "$archive" \
    --checksum-file "$checksums" \
    --expected-root "agent-manager-v${release_version}-${release_target}" \
    --version "$release_version" \
    --target "$release_target" \
    --source-revision "$release_revision" \
    --require-clean-source >/dev/null 2>&1; then
    command -v curl >/dev/null || fail "curl is required to download release assets"
    temporary_download="$(mktemp -d "$download_dir/.download.XXXXXX")"
    cleanup_download() {
      if test -d "$temporary_download"; then
        find "$temporary_download" -depth -delete
      fi
    }
    trap cleanup_download EXIT
    release_url="https://github.com/777lotto/nvim-agents.zzz/releases/download/v${release_version}"
    log "downloading signed v$release_version release assets"
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
      "$release_url/$archive_name" --output "$temporary_download/$archive_name"
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
      "$release_url/SHA256SUMS" --output "$temporary_download/SHA256SUMS"
    "$verify_python" "$metadata" verify-archive \
      --archive "$temporary_download/$archive_name" \
      --checksum-file "$temporary_download/SHA256SUMS" \
      --expected-root "agent-manager-v${release_version}-${release_target}" \
      --version "$release_version" \
      --target "$release_target" \
      --source-revision "$release_revision" \
      --require-clean-source >/dev/null
    mv -T -- "$temporary_download/$archive_name" "$archive"
    mv -T -- "$temporary_download/SHA256SUMS" "$checksums"
    rmdir -- "$temporary_download"
    trap - EXIT
  else
    log "using the verified cached v$release_version release assets"
  fi
fi

if test "${AGENT_MANAGER_REQUIRE_ATTESTATION:-0}" = 1; then
  command -v gh >/dev/null || fail "gh is required by AGENT_MANAGER_REQUIRE_ATTESTATION=1"
  gh attestation verify "$archive" --repo 777lotto/nvim-agents.zzz >/dev/null
fi

# Refresh the selected asset paths after an offline/test override.
temporary_env="$env_file.tmp.$$"
write_env "$temporary_env"
mv -T -- "$temporary_env" "$env_file"

for phase in 00-preflight.sh 10-install-release.sh 20-activate-release.sh 90-verify.sh; do
  log "running $phase"
  M5_ENV_FILE="$env_file" "$phase_dir/$phase"
done

log "release v$release_version is installed and active"
log "paired undo: M5_ENV_FILE=$env_file $phase_dir/undo-current.sh"

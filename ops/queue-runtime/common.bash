phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
: "${M5_ENV_FILE:?select the local runtime environment file}"
# shellcheck source=../m5-release-install/common.bash
source "$phase_dir/../m5-release-install/common.bash"
phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
: "${QUEUE_UNIT:?set QUEUE_UNIT in the environment file}"
: "${QUEUE_DROPIN:?set QUEUE_DROPIN in the environment file}"
require_service_user
require_absolute "$QUEUE_DROPIN" QUEUE_DROPIN
test "$QUEUE_DROPIN" = "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$QUEUE_UNIT.d/40-local-workflow-runtime.conf" \
  || fail "unexpected queue override path"
test "$INSTALL_ROOT" != "$HOME/.local/share/agent-manager" \
  || fail "local override must use its own install root"
test "$SERVICE_UNIT" = "$QUEUE_UNIT" || fail "M5 must check queue inactivity"
test "$SERVICE_STATE_CHECK" = systemd || fail "local activation requires systemd checks"

require_idle_queue() {
  require_service_inactive
  local units
  units="$(systemctl --user list-units 'zemrip-agent-*-????????????.service' --state=active,activating,deactivating --no-legend --plain)"
  test -z "$units" || fail "wait for active task units before selecting a runtime"
}

desired_dropin() {
  printf '# managed by agent-manager ops/queue-runtime\n[Service]\n'
  printf 'Environment="AGENT_WORKFLOW_PYTHON=%s/bin/python"\n' "$VENV_LINK"
}

require_owned_dropin() {
  if ! test -f "$QUEUE_DROPIN" || test -L "$QUEUE_DROPIN"; then
    fail "preserve unexpected queue override"
  fi
  cmp -s "$QUEUE_DROPIN" <(desired_dropin) \
    || fail "preserve changed or unknown queue override"
}

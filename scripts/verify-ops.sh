#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
m4_dir="$repo_root/ops/m4-durable-service"
m5_dir="$repo_root/ops/m5-release-install"
queue_dir="$repo_root/ops/queue-runtime"

bash -n "$m4_dir"/*.sh "$m5_dir"/*.sh "$m5_dir/common.bash"
shellcheck -x -P "$m4_dir" "$m4_dir"/*.sh
shellcheck -x -P "$m5_dir" "$m5_dir"/*.sh "$m5_dir/common.bash"
bash -n "$queue_dir"/*.sh "$queue_dir/common.bash"
shellcheck -x -P "$queue_dir" "$queue_dir"/*.sh "$queue_dir/common.bash"
for phase_script in \
  "$m4_dir"/*.sh \
  "$m4_dir/verify_runtime.py" \
  "$m5_dir"/*.sh \
  "$m5_dir/verify_install.py"; do
  test -x "$phase_script"
done
(
  cd "$repo_root/python"
  uv run ruff format --check \
    ../ops/m4-durable-service/verify_runtime.py \
    ../ops/m5-release-install/verify_install.py
  uv run ruff check \
    ../ops/m4-durable-service/verify_runtime.py \
    ../ops/m5-release-install/verify_install.py
  uv run pyright ../ops/m5-release-install/verify_install.py
)

unit_check="$(mktemp --suffix=.service)"
user_runtime_check="$(mktemp -d)"
chmod 0700 "$user_runtime_check"
cleanup() {
  rm -- "$unit_check"
  find "$user_runtime_check" -depth -delete
}
trap cleanup EXIT
sed 's#^ExecStart=.*#ExecStart=/bin/true#' \
  "$m4_dir/agent-manager-broker.service" >"$unit_check"
(
  unset DBUS_SESSION_BUS_ADDRESS
  XDG_RUNTIME_DIR="$user_runtime_check" systemd-analyze --user verify "$unit_check"
)

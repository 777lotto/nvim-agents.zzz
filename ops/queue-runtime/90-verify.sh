#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.bash
source "$phase_dir/common.bash"
require_owned_dropin
"$phase_dir/../m5-release-install/90-verify.sh"
"$VENV_LINK/bin/python" -B -I - "$QUEUE_UNIT" "$VENV_LINK/bin/python" <<'PY'
import shlex
import subprocess
import sys

environment = subprocess.check_output(
    ['systemctl', '--user', 'show', sys.argv[1], '--property=Environment', '--value'],
    text=True,
)
values = [item for item in shlex.split(environment) if item.startswith('AGENT_WORKFLOW_PYTHON=')]
if values != ['AGENT_WORKFLOW_PYTHON=' + sys.argv[2]]:
    raise SystemExit('FAIL queue does not select the expected workflow interpreter')
print('PASS effective queue workflow interpreter')
PY

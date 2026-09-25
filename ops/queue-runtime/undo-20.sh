#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.bash
source "$phase_dir/common.bash"
require_idle_queue
if test -e "$QUEUE_DROPIN" || test -L "$QUEUE_DROPIN"; then
  require_owned_dropin
  rm -- "$QUEUE_DROPIN"
fi
systemctl --user daemon-reload
printf 'PASS queue runtime override removed; task evidence and local payload retained\n'

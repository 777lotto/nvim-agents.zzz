#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.bash
source "$phase_dir/common.bash"
require_idle_queue
"$phase_dir/../m5-release-install/90-verify.sh"

install -d -m 0700 "$(dirname -- "$QUEUE_DROPIN")"
if test -e "$QUEUE_DROPIN" || test -L "$QUEUE_DROPIN"; then
  require_owned_dropin
else
  dropin_tmp="$(mktemp "${QUEUE_DROPIN}.XXXXXX")"
  trap 'rm -f -- "$dropin_tmp"' EXIT
  desired_dropin >"$dropin_tmp"
  chmod 0600 "$dropin_tmp"
  mv -T -- "$dropin_tmp" "$QUEUE_DROPIN"
  trap - EXIT
fi
systemctl --user daemon-reload
printf 'PASS queue selects the local workflow runtime; admission remains stopped\n'

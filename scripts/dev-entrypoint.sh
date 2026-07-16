#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/dev-init.sh
source /usr/local/lib/codex-dev/dev-init.sh

codex_acquire_lifecycle_lock
codex_initialize_dev

cd /workspace

exec gosu "${DEV_USER}" "$@"

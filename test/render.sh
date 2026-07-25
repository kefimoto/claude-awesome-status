#!/usr/bin/env bash
# Render one fixture through statusline.sh under fully stubbed system state,
# so output depends only on the script and the fixture — not on this machine's
# load, memory, clock, or checkout. Usage: render.sh <fixture> [config]
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(dirname "$here")

fixture="$1"
config="${2:-}"

export PATH="$here/stubbin:$PATH"
# Fixed tick => the animated border lands on the same frame every run.
export CAS_TICK_FILE="${CAS_TICK_FILE:-$(mktemp)}"
printf '7\n' > "$CAS_TICK_FILE"
# Legacy path used by pre-refactor revisions that don't read CAS_TICK_FILE.
printf '7\n' > /tmp/.claude-statusline-tick 2>/dev/null || true

if [ -n "$config" ]; then
  export CAS_CONFIG="$config"
else
  # Neutralize any real user config so tests exercise built-in defaults.
  export CAS_CONFIG=/dev/null
fi

# Isolate the PR-count cache so a stale entry can't leak between runs.
export CAS_CACHE_DIR="${CAS_CACHE_DIR:-$(mktemp -d)}"

# /proc/loadavg is read directly, not via a command, so no PATH stub can cover it.
export CAS_LOADAVG_FILE="$here/fixtures/loadavg"

exec bash "$repo/statusline.sh" < "$fixture"

#!/usr/bin/env bash
# Wires claude-awesome-status into Claude Code: makes statusline.sh
# executable and points ~/.claude/settings.json's statusLine at it, without
# touching anything else already in that file (hooks, permissions,
# plugins, etc).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
statusline="$script_dir/statusline.sh"

if ! command -v jq &>/dev/null; then
  echo "error: jq is required (both by this installer and by statusline.sh itself)." >&2
  echo "       Install it (e.g. 'brew install jq' or 'apt install jq') and re-run." >&2
  exit 1
fi

chmod +x "$statusline"

# statusline.sh needs bash 4.3+ (associative arrays, declare -n, mapfile).
# macOS ships bash 3.2 by default, so a bare "bash" in settings.json can
# silently resolve to the wrong one depending on PATH order at the time
# Claude Code invokes it. Pin an absolute path to a verified-good bash
# instead of trusting PATH resolution at runtime — this matters on every
# platform, not just macOS, since it removes PATH ambiguity entirely.
bash_is_new_enough() {
  local bin="$1" ver maj min
  [ -x "$bin" ] || return 1
  # shellcheck disable=SC2016 # intentional: expanded by $bin, not this shell
  ver=$("$bin" -c 'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"' 2>/dev/null) || return 1
  read -r maj min <<< "$ver"
  [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] || return 1
  (( maj > 4 || (maj == 4 && min >= 3) ))
}

find_good_bash() {
  local candidates=() seen="" c
  [ -n "${BASH:-}" ] && candidates+=("$BASH")
  candidates+=("$(command -v bash 2>/dev/null)" /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash)
  if command -v brew &>/dev/null; then
    candidates+=("$(brew --prefix bash 2>/dev/null)/bin/bash")
  fi
  for c in "${candidates[@]}"; do
    [ -z "$c" ] && continue
    [[ ":$seen:" == *":$c:"* ]] && continue
    seen="$seen:$c"
    if bash_is_new_enough "$c"; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

good_bash="$(find_good_bash)" || {
  echo "error: couldn't find a bash 4.3+ on this machine." >&2
  echo "       claude-awesome-status needs bash 4.3 or newer to run." >&2
  case "$OSTYPE" in
    darwin*)
      echo "       macOS ships bash 3.2 by default. Install a newer one with:" >&2
      echo "         brew install bash" >&2
      echo "       then re-run this script." >&2
      ;;
    *)
      echo "       Install a newer bash via your package manager and re-run." >&2
      ;;
  esac
  exit 1
}

settings_dir="$HOME/.claude"
settings_file="$settings_dir/settings.json"
mkdir -p "$settings_dir"

new_statusline=$(jq -n --arg cmd "$good_bash $statusline" '{type: "command", command: $cmd}')

if [ -s "$settings_file" ]; then
  if ! jq -e . "$settings_file" >/dev/null 2>&1; then
    echo "error: $settings_file exists but isn't valid JSON — not touching it." >&2
    echo "       Fix or remove it, then re-run this script." >&2
    exit 1
  fi

  previous=$(jq -r '.statusLine.command // "(none)"' "$settings_file")

  if [ "$previous" = "$good_bash $statusline" ]; then
    echo "$settings_file already points at $statusline (via $good_bash) — nothing to do."
  else
    backup="$settings_file.bak.$(date +%s)"
    cp "$settings_file" "$backup"

    tmp="$settings_file.tmp.$$"
    jq --argjson sl "$new_statusline" '.statusLine = $sl' "$settings_file" > "$tmp"
    mv "$tmp" "$settings_file"

    echo "Updated $settings_file (backup: $backup)"
    echo "  statusLine.command: $previous -> $good_bash $statusline"
  fi
else
  jq -n --argjson sl "$new_statusline" '{statusLine: $sl}' > "$settings_file"
  echo "Created $settings_file"
  echo "  statusLine.command: $good_bash $statusline"
fi

echo
echo "Done. Start (or restart) a Claude Code session to see it."
echo "Optional: copy examples/config.json or examples/config.yaml to"
echo "$HOME/.config/claude-awesome-status/config.json to customize it."

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

settings_dir="$HOME/.claude"
settings_file="$settings_dir/settings.json"
mkdir -p "$settings_dir"

new_statusline=$(jq -n --arg cmd "bash $statusline" '{type: "command", command: $cmd}')

if [ -s "$settings_file" ]; then
  if ! jq -e . "$settings_file" >/dev/null 2>&1; then
    echo "error: $settings_file exists but isn't valid JSON — not touching it." >&2
    echo "       Fix or remove it, then re-run this script." >&2
    exit 1
  fi

  previous=$(jq -r '.statusLine.command // "(none)"' "$settings_file")

  if [ "$previous" = "bash $statusline" ]; then
    echo "$settings_file already points at $statusline — nothing to do."
  else
    backup="$settings_file.bak.$(date +%s)"
    cp "$settings_file" "$backup"

    tmp="$settings_file.tmp.$$"
    jq --argjson sl "$new_statusline" '.statusLine = $sl' "$settings_file" > "$tmp"
    mv "$tmp" "$settings_file"

    echo "Updated $settings_file (backup: $backup)"
    echo "  statusLine.command: $previous -> bash $statusline"
  fi
else
  jq -n --argjson sl "$new_statusline" '{statusLine: $sl}' > "$settings_file"
  echo "Created $settings_file"
  echo "  statusLine.command: bash $statusline"
fi

echo
echo "Done. Start (or restart) a Claude Code session to see it."
echo "Optional: copy examples/config.json or examples/config.yaml to"
echo "~/.config/claude-awesome-status/config.json to customize it."

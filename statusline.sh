#!/usr/bin/env bash
# claude-awesome-status: a boxed statusline for Claude Code.
# 5h/7d usage | model | context | cpu/ram | directory | git branch | PR status

# Requires associative arrays, declare -n namerefs, and mapfile — all bash
# 4.0+/4.3+. macOS ships bash 3.2 by default (frozen there since ~2007 for
# GPLv3-licensing reasons), which understands none of them and fails with a
# cryptic "declare: -A: invalid option" rather than this message unless we
# check first. install.sh pins an absolute path to a verified-good bash for
# exactly this reason; this check is the fallback for anyone who wired
# settings.json up by hand.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  echo "claude-awesome-status requires bash 4.3 or newer (found bash $BASH_VERSION)." >&2
  echo "On macOS the system bash is 3.2 by default — install a newer one with:" >&2
  echo "  brew install bash" >&2
  echo "then re-run install.sh, or point statusLine.command at that bash's" >&2
  echo "absolute path directly (usually /opt/homebrew/bin/bash or /usr/local/bin/bash)." >&2
  exit 1
fi

input=$(cat)

# Needed for the *([0-9;]) pattern content_width() uses below to strip ANSI
# escapes via parameter expansion instead of a sed fork.
shopt -s extglob

badge() {
  local pct="$1" yellow="$2" red="$3" label="$4" trailing="$5"
  if (( $(echo "$pct >= $red" | bc -l) )); then
    printf "\033[41;1;37m ⚠️ %s \033[0m %s" "$label" "$trailing"
  elif (( $(echo "$pct >= $yellow" | bc -l) )); then
    printf "\033[43;1;30m %s \033[0m %s" "$label" "$trailing"
  else
    printf "\033[42;1;30m %s \033[0m %s" "$label" "$trailing"
  fi
}

# --- Config -----------------------------------------------------------------
# An optional JSON or YAML file overriding style, thresholds, segment order
# and grouping. Resolution order: $CAS_CONFIG verbatim (no fallback search —
# this is also how tests force the no-config default path with
# CAS_CONFIG=/dev/null), then the first readable file among a fixed set of
# XDG-ish locations, then no config at all.
resolve_config_path() {
  if [ -n "${CAS_CONFIG:-}" ]; then
    printf '%s' "$CAS_CONFIG"
    return
  fi
  local base="${XDG_CONFIG_HOME:-$HOME/.config}/claude-awesome-status"
  local c
  for c in "$base/config.json" "$base/config.yaml" "$base/config.yml" \
           "$HOME/.claude/claude-awesome-status.json" \
           "$HOME/.claude/claude-awesome-status.yaml" \
           "$HOME/.claude/claude-awesome-status.yml"; do
    if [ -r "$c" ] && [ ! -d "$c" ]; then
      printf '%s' "$c"
      return
    fi
  done
}

cfg_path="$(resolve_config_path)"
# /dev/null is the documented way to disable config (tests rely on this to
# exercise built-in defaults); an unreadable path or a directory is the same
# as no config at all rather than an error.
if [ -z "$cfg_path" ] || [ "$cfg_path" = "/dev/null" ] || [ ! -r "$cfg_path" ] || [ -d "$cfg_path" ]; then
  cfg_path=""
fi

# cfg_json is a path to a JSON file jq can read directly — either cfg_path
# itself, or a cached JSON conversion of it if it was YAML. Left empty when
# there's no config, which is what keeps cfg_get below at zero forks for the
# overwhelming common case of a user who never wrote a config file.
cfg_json=""
if [ -n "$cfg_path" ]; then
  case "$cfg_path" in
    *.yaml | *.yml)
      cache_dir="${CAS_CACHE_DIR:-/tmp}"
      cache_file="$cache_dir/.claude-awesome-status-cfg-$(printf '%s' "$cfg_path" | tr '/' '_').json"
      if [ -s "$cache_file" ] && [ ! "$cfg_path" -nt "$cache_file" ]; then
        cfg_json="$cache_file"
      else
        converted=""
        if command -v yq &>/dev/null; then
          # Two incompatible programs share this name; try both forms rather
          # than fork a version probe.
          converted=$(yq -o=json -I0 '.' "$cfg_path" 2>/dev/null)
          [ -z "$converted" ] && converted=$(yq -c '.' "$cfg_path" 2>/dev/null)
        fi
        if [ -z "$converted" ] && command -v python3 &>/dev/null; then
          converted=$(python3 -c '
import sys, json
try:
    import yaml
except ImportError:
    sys.exit(3)
try:
    json.dump(yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}, sys.stdout)
except Exception:
    sys.exit(4)
' "$cfg_path" 2>/dev/null)
        fi
        # Neither converter available, or the YAML itself is invalid: degrade
        # to no config rather than fail the whole statusline. A prior good
        # cached conversion (e.g. from before a typo) is kept and reused.
        if [ -n "$converted" ]; then
          printf '%s' "$converted" > "$cache_file.$$" && mv -f "$cache_file.$$" "$cache_file"
          cfg_json="$cache_file"
        elif [ -s "$cache_file" ]; then
          cfg_json="$cache_file"
        fi
      fi
      ;;
    *)
      cfg_json="$cfg_path"
      ;;
  esac
fi

# $1: jq filter, $2: default. Malformed JSON, the wrong top-level shape, or a
# missing field all fall back to the default rather than erroring — jq's own
# failure (empty stdout) is indistinguishable from "field absent" here, which
# is exactly the fail-closed behavior a config file should have.
cfg_get() {
  local out
  if [ -z "$cfg_json" ]; then
    printf '%s' "$2"
    return
  fi
  out=$(jq -r "$1" "$cfg_json" 2>/dev/null)
  if [ -z "$out" ] || [ "$out" = "null" ]; then
    printf '%s' "$2"
  else
    printf '%s' "$out"
  fi
}

# Same, but rejects a non-numeric result instead of passing it through — a
# threshold ends up in badge()'s bc/arithmetic, where a hostile string would
# otherwise be a shell-injection-shaped bug, not just a cosmetic one.
cfg_get_num() {
  local v
  v="$(cfg_get "$1" "$2")"
  if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s' "$v"
  else
    printf '%s' "$2"
  fi
}

thr_five_hour_yellow="$(cfg_get_num '.thresholds.five_hour.yellow // empty' 50)"
thr_five_hour_red="$(cfg_get_num '.thresholds.five_hour.red // empty' 80)"
thr_seven_day_yellow="$(cfg_get_num '.thresholds.seven_day.yellow // empty' 50)"
thr_seven_day_red="$(cfg_get_num '.thresholds.seven_day.red // empty' 80)"
thr_cpu_yellow="$(cfg_get_num '.thresholds.cpu.yellow // empty' 70)"
thr_cpu_red="$(cfg_get_num '.thresholds.cpu.red // empty' 100)"
thr_ram_yellow="$(cfg_get_num '.thresholds.ram.yellow // empty' 50)"
thr_ram_red="$(cfg_get_num '.thresholds.ram.red // empty' 80)"
thr_context_yellow="$(cfg_get_num '.thresholds.context.yellow // empty' 50)"
thr_context_red="$(cfg_get_num '.thresholds.context.red // empty' 75)"

model=$(echo "$input" | jq -r '.model.display_name // empty')
model_emoji=""
if [[ "$model" =~ Haiku ]]; then
  model_emoji="🍃"
  model=$(printf "\033[32m%s\033[0m" "$model")
elif [[ "$model" =~ Sonnet ]]; then
  model_emoji="🪶"
  model=$(printf "\033[33m%s\033[0m" "$model")
elif [[ "$model" =~ Opus ]]; then
  model_emoji="🎼"
  model=$(printf "\033[31m%s\033[0m" "$model")
elif [[ "$model" =~ Fable ]]; then
  model_emoji="🦊"
  model=$(printf "\033[91m%s\033[0m" "$model")
fi
model="$model_emoji $model"

fast_mode=$(echo "$input" | jq -r '.fast_mode // false')
[ "$fast_mode" = "true" ] && model="$model 🚀"

thinking_enabled=$(echo "$input" | jq -r '.thinking.enabled // false')
[ "$thinking_enabled" = "true" ] && model="$model 🧠"

context_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
context_size_str=""
if [ -n "$context_size" ]; then
  if [ "$context_size" -ge 1000000 ]; then
    size_display=$(awk "BEGIN { printf \"%.0fm\", $context_size / 1000000 }")
    size_emoji="🐘"
  elif [ "$context_size" -ge 1000 ]; then
    size_display=$(awk "BEGIN { printf \"%.0fk\", $context_size / 1000 }")
    size_emoji="🐁"
  else
    size_display="$context_size"
    size_emoji="🐁"
  fi
  context_size_str="$size_emoji $size_display context"
fi

fmt_kb() {
  local kb="$1"
  if [ "$kb" -ge 1048576 ]; then
    awk "BEGIN { printf \"%.1fgb\", $kb / 1048576 }"
  else
    awk "BEGIN { printf \"%.0fmb\", $kb / 1024 }"
  fi
}

claude_ram_str=""
claude_pid=""
walk_pid="$PPID"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -z "$walk_pid" ] && break
  walk_comm=$(ps -o comm= -p "$walk_pid" 2>/dev/null)
  if [[ "$walk_comm" == claude* ]]; then
    claude_pid="$walk_pid"
    break
  fi
  walk_pid=$(ps -o ppid= -p "$walk_pid" 2>/dev/null | tr -d ' ')
done

# Match the box to the real terminal, not a guess: ask the tty behind the
# nearest ancestor claude process directly, since this script's own
# stdin/stdout aren't the tty. Resolved here (early) because display_dir's
# truncation, below, needs to know how much room a full line actually has.
box_width=80
if [ -n "$claude_pid" ]; then
  tty_name=$(ps -o tty= -p "$claude_pid" 2>/dev/null | tr -d ' ')
  if [ -n "$tty_name" ] && [ "$tty_name" != "?" ]; then
    term_cols=$(stty -F "/dev/$tty_name" size 2>/dev/null | awk '{print $2}')
    if [[ "$term_cols" =~ ^[0-9]+$ ]] && [ "$term_cols" -ge 44 ]; then
      box_width=$((term_cols - 4))
      [ "$box_width" -gt 220 ] && box_width=220
    fi
  fi
fi
n_dashes=$((box_width - 2))

# Decodes UTF-8 from raw byte values (via od) rather than trusting bash's
# own ${var:i:1} character indexing, which is locale-dependent: under a
# non-UTF-8 locale it silently switches to byte-wise, breaking every width
# calculation that touches an emoji or box-drawing character. Observed on
# GitHub's macOS runners, which don't default to a UTF-8 locale — grep -P
# with \x{1F000}-style PCRE codepoint ranges (the previous approach here)
# isn't available there anyway (BSD grep has no -P at all), and has no
# POSIX ERE equivalent, so there was no portable regex-based fallback
# either. od is locale-blind by design, which is exactly what's needed:
# this must give the same answer everywhere, not just under UTF-8.
content_width() {
  local content="$1" stripped
  printf -v stripped '%b' "$content"
  stripped="${stripped//$'\e'\[*([0-9;])m/}"
  # U+FE0F (emoji variation selector, e.g. the second codepoint in "⚠️") is a
  # zero-width modifier but bash counts it as a normal 1-column character —
  # strip it so it doesn't inflate the count.
  stripped="${stripped//$'\xef\xb8\x8f'/}"

  local -a bytes
  # od wraps at a line width that isn't standardized across
  # implementations (-w to control it is a GNU/BSD extension, not POSIX,
  # and not trusted to behave identically everywhere) — flatten to one
  # line with tr before read -a, or read -a silently sees only the first
  # wrapped line and drops the rest.
  read -r -a bytes <<< "$(printf '%s' "$stripped" | od -An -v -tu1 | tr '\n' ' ')"

  local total=${#bytes[@]} i=0 byte nbytes cp j cont n=0 wide_count=0
  while ((i < total)); do
    byte=${bytes[i]}
    if   ((byte < 0x80)); then nbytes=1
    elif ((byte >= 0xC0 && byte < 0xE0)); then nbytes=2
    elif ((byte >= 0xE0 && byte < 0xF0)); then nbytes=3
    elif ((byte >= 0xF0 && byte < 0xF8)); then nbytes=4
    else nbytes=1
    fi
    if   ((nbytes == 1)); then cp=$byte
    elif ((nbytes == 2)); then cp=$((byte & 0x1F))
    elif ((nbytes == 3)); then cp=$((byte & 0x0F))
    else cp=$((byte & 0x07))
    fi
    for ((j = 1; j < nbytes && i + j < total; j++)); do
      cont=${bytes[i + j]}
      cp=$(((cp << 6) | (cont & 0x3F)))
    done
    # Wide (emoji/CJK) codepoints render as 2 terminal columns but count as 1
    # bash character, so each one found needs an extra column added.
    if   ((cp >= 0x1F000 && cp <= 0x1FFFF)); then ((wide_count++))
    elif ((cp >= 0x2600  && cp <= 0x27BF));  then ((wide_count++))
    elif ((cp >= 0x2B00  && cp <= 0x2BFF));  then ((wide_count++))
    fi
    ((n++))
    ((i += nbytes))
  done
  echo $((n + wide_count))
}

if [ -n "$claude_pid" ]; then
  self_rss_kb=$(ps -o rss= -p "$claude_pid" 2>/dev/null | tr -d ' ')
  children_rss_kb=$(ps -eo pid,ppid,rss --no-headers 2>/dev/null | awk -v root="$claude_pid" '
    { ppid[$1]=$2; rss[$1]=$3 }
    END {
      total=0
      queue[1]=root; qn=1; qi=1
      while (qi <= qn) {
        cur = queue[qi]; qi++
        for (p in ppid) {
          if (ppid[p] == cur) {
            total += rss[p]
            qn++
            queue[qn] = p
          }
        }
      }
      print total
    }
  ')
  if [ -n "$self_rss_kb" ] && [ -n "$children_rss_kb" ]; then
    claude_ram_str="🐏 $(fmt_kb "$self_rss_kb") 🐣 $(fmt_kb "$children_rss_kb")"
  fi
fi

dir=$(echo "$input" | jq -r '.workspace.current_dir // empty')
display_dir="${dir/#$HOME/\~}"
# Only truncate if the full path genuinely can't fit on one line by itself
# (a row it has the box to itself on) — and trim the fewest segments needed
# to make it fit, rather than an arbitrary fixed cutoff.
if [ "$(content_width "📁 $display_dir")" -gt "$n_dashes" ]; then
  trimmed="$display_dir"
  while [[ "$trimmed" == */* ]] && [ "$(content_width "📁 .../$trimmed")" -gt "$n_dashes" ]; do
    trimmed="${trimmed#*/}"
  done
  display_dir=".../$trimmed"
fi

# -C targets the reported cwd (this script's own cwd is not reliable),
# --no-optional-locks avoids contending with concurrent git operations.
branch=$(git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null)

repo_slug=""
repo_str=""
if [ -n "$branch" ]; then
  repo_slug=$(git -C "$dir" --no-optional-locks remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##')
  [ -n "$repo_slug" ] && repo_str="🐙 $repo_slug"
fi

pr_num=$(echo "$input" | jq -r '.pr.number // empty')

pr_str=""
[ -n "$pr_num" ] && pr_str="PR#$pr_num"

open_pr_str=""
if command -v gh &>/dev/null && [ -n "$repo_slug" ]; then
  cache_file="${CAS_CACHE_DIR:-/tmp}/.claude-statusline-pr-cache-$(echo "$repo_slug" | tr '/' '_')"
  now_epoch=$(date +%s)
  cache_age=999999
  if [ -f "$cache_file" ]; then
    cache_epoch=$(head -1 "$cache_file")
    [ -n "$cache_epoch" ] && cache_age=$((now_epoch - cache_epoch))
  fi
  if [ "$cache_age" -lt 60 ]; then
    open_pr_count=$(tail -1 "$cache_file")
  else
    open_pr_count=$(timeout 2 gh -R "$repo_slug" pr list --state open --json number -q 'length' 2>/dev/null)
    if [ -n "$open_pr_count" ]; then
      printf "%s\n%s\n" "$now_epoch" "$open_pr_count" > "$cache_file"
    fi
  fi
  [ -n "$open_pr_count" ] && open_pr_str="🔀 ${open_pr_count} open"
fi

account_str=""
if command -v claude &>/dev/null; then
  auth_json=$(timeout 2 claude auth status </dev/null 2>/dev/null)
  account_email=$(printf '%s' "$auth_json" | jq -r 'select(.loggedIn == true) | .email // empty' 2>/dev/null)
  [ -n "$account_email" ] && account_str="👤 $account_email"
fi

load_str=""
loadavg_file="${CAS_LOADAVG_FILE:-/proc/loadavg}"
if [ -f "$loadavg_file" ]; then
  read -r load1 _ _ < "$loadavg_file"
  cpus=$(nproc 2>/dev/null || echo 1)
  load_pct=$(awk "BEGIN { printf \"%.0f\", ($load1 / $cpus) * 100 }")
  load_str=$(badge "$load_pct" "$thr_cpu_yellow" "$thr_cpu_red" "cpu" "$(printf '%d%%' "$load_pct")")
fi

used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')

context_str=""
if [ -n "$used_pct" ] && [ -n "$context_size" ]; then
  context_str=$(badge "$used_pct" "$thr_context_yellow" "$thr_context_red" "ctx" "$(printf '%.0f%%' "$used_pct")")
fi

five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_hour_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_day_resets=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
usage_str=""
if [ -n "$five_hour_pct" ]; then
  remaining_str=""
  if [ -n "$five_hour_resets" ]; then
    now=$(date +%s)
    remaining_secs=$((five_hour_resets - now))
    if [ "$remaining_secs" -gt 0 ]; then
      remaining_h=$((remaining_secs / 3600))
      remaining_m=$(((remaining_secs % 3600) / 60))
      remaining_str=$(printf " %dh%dm" "$remaining_h" "$remaining_m")
    fi
  fi
  usage_str=$(badge "$five_hour_pct" "$thr_five_hour_yellow" "$thr_five_hour_red" "5h" "$(printf '%.0f%%%s' "$five_hour_pct" "$remaining_str")")
fi
if [ -n "$seven_day_pct" ]; then
  seven_day_remaining_str=""
  if [ -n "$seven_day_resets" ]; then
    now=$(date +%s)
    seven_day_remaining_secs=$((seven_day_resets - now))
    if [ "$seven_day_remaining_secs" -gt 0 ]; then
      seven_day_remaining_d=$((seven_day_remaining_secs / 86400))
      seven_day_remaining_h=$(((seven_day_remaining_secs % 86400) / 3600))
      seven_day_remaining_str=$(printf " %dd%dh" "$seven_day_remaining_d" "$seven_day_remaining_h")
    fi
  fi
  seven_day_str=$(badge "$seven_day_pct" "$thr_seven_day_yellow" "$thr_seven_day_red" "7d" "$(printf '%.0f%%%s' "$seven_day_pct" "$seven_day_remaining_str")")
fi

# Every segment's rendered text, keyed by a stable name. A name with an empty
# or unset value is simply skipped when rows are built below — that's also
# what lets a config later hide a segment, or replace/add one, by just
# setting or clearing an entry in this same map.
declare -A SEG_TEXT

ram_str=""
if command -v free &>/dev/null; then
  read -r used total < <(free -h | awk '/^Mem:/ { match($3, /^[0-9.]+/); used=substr($3, RSTART, RLENGTH); match($2, /^[0-9.]+/); total=substr($2, RSTART, RLENGTH); print used, total }')
  if [ -n "$used" ] && [ -n "$total" ]; then
    ram_pct=$(awk "BEGIN { printf \"%.0f\", ($used / $total) * 100 }")
    ram_str=$(badge "$ram_pct" "$thr_ram_yellow" "$thr_ram_red" "ram" "${ram_pct}%")
  fi
fi

SEG_TEXT[five_hour]="$usage_str"
SEG_TEXT[seven_day]="$seven_day_str"
SEG_TEXT[cpu]="$load_str"
SEG_TEXT[ram]="$ram_str"
SEG_TEXT[context]="$context_str"
SEG_TEXT[model]="$model"
SEG_TEXT[context_size]="$context_size_str"
SEG_TEXT[claude_ram]="$claude_ram_str"
SEG_TEXT[dir]="📁 $display_dir"
SEG_TEXT[repo]="$repo_str"
[ -n "$branch" ] && SEG_TEXT[branch]="🌿 $branch"
SEG_TEXT[pr]="$pr_str"
SEG_TEXT[open_pr]="$open_pr_str"
SEG_TEXT[account]="$account_str"

# Unit separator used to join a row's segments before layout_row splits them
# back apart — defined here (rather than down by wrap_segments, its only
# other reader) so custom-segment sanitization below can strip it from
# output that might otherwise smuggle in a phantom segment.
SEG_SEP=$'\x1f'

# A config's "segments" map defines custom segments: run a command (or an
# inline shell snippet — same execution path, it's just stored in the config
# file instead of an external script) and use its output as the segment
# text. A name matching a built-in replaces it, since this only ever
# overwrites SEG_TEXT[name] after the built-ins have already set it.
#
# This is the one place config content is executed, so every guard below is
# load-bearing, not cosmetic:
#   - name is restricted to a safe identifier before it ever reaches SEG_TEXT
#     or a jq --arg;
#   - timeout bounds a hung or slow command — the statusline redraws on
#     every turn, so one bad segment must not freeze it, exactly like the
#     existing timeout on gh and claude auth status above;
#   - output is coerced to a single line: layout_row's SEG_SEP-delimited
#     format assumes exactly that, and a stray newline would print outside
#     the box entirely;
#   - a literal SEG_SEP byte in the output is stripped so it can't be
#     mistaken for a segment boundary and corrupt every wall position after
#     it;
#   - backslashes are doubled so the final printf '%b' (which interprets
#     backslash escapes for the whole rendered line) can't be tricked into
#     expanding attacker-controlled text into new ANSI codes.
#
# A config file is inherently as trusted as this script itself — Claude
# Code already invokes statusline.sh as an arbitrary shell command from
# settings.json, so a config's inline snippets grant no authority beyond
# what the user already has.
if [ -n "$cfg_json" ]; then
  mapfile -t cfg_seg_names < <(jq -r '(.segments // {}) | keys[]?' "$cfg_json" 2>/dev/null)
  for seg_name in "${cfg_seg_names[@]}"; do
    [[ "$seg_name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || continue

    seg_timeout="$(jq -r --arg n "$seg_name" '.segments[$n].timeout // 1' "$cfg_json" 2>/dev/null)"
    [[ "$seg_timeout" =~ ^[0-9]+(\.[0-9]+)?$ ]] || seg_timeout=1

    seg_cmd_is_array="$(jq -r --arg n "$seg_name" '(.segments[$n].command | type) == "array"' "$cfg_json" 2>/dev/null)"
    seg_out=""
    if [ "$seg_cmd_is_array" = "true" ]; then
      # No shell involved: exec'd directly, so there are no quoting bugs to
      # sanitize against in the first place.
      mapfile -t seg_argv < <(jq -r --arg n "$seg_name" '.segments[$n].command[]' "$cfg_json" 2>/dev/null)
      [ "${#seg_argv[@]}" -gt 0 ] && seg_out=$(timeout "${seg_timeout}s" "${seg_argv[@]}" </dev/null 2>/dev/null)
    else
      seg_code="$(jq -r --arg n "$seg_name" '.segments[$n].command // .segments[$n].inline // empty' "$cfg_json" 2>/dev/null)"
      [ -n "$seg_code" ] && seg_out=$(timeout "${seg_timeout}s" bash -c "$seg_code" </dev/null 2>/dev/null)
    fi

    seg_out="${seg_out%%$'\n'*}"      # first line only
    seg_out="${seg_out//$'\r'/}"      # no carriage returns
    seg_out="${seg_out//$SEG_SEP/}"   # can't smuggle in a fake segment boundary
    seg_out="${seg_out//\\/\\\\}"     # printf '%b' can't reinterpret these as escapes
    [ -n "$seg_out" ] && SEG_TEXT[$seg_name]="$seg_out"
  done
fi

# A config can hide any segment by name — built-in or custom; unknown names
# are harmless since SEG_TEXT simply never had that key.
if [ -n "$cfg_json" ]; then
  mapfile -t cfg_hide < <(jq -r '(.hide // empty) | if type == "array" then .[] | select(type == "string") else empty end' "$cfg_json" 2>/dev/null)
  for hidden in "${cfg_hide[@]:-}"; do
    [ -n "$hidden" ] && unset "SEG_TEXT[$hidden]"
  done
fi

# Greedily pack each line's segments into as many rows as needed so no row's
# content overruns the box — instead of overflowing, it wraps. Rows are kept
# as raw segments (joined with a unit separator, not "│") so layout_row can
# later distribute padding per-segment instead of per-row.
wrap_segments() {
  local -n _segs=$1
  local -n _rows=$2
  # sep_w mirrors the minimum a joined " │ " gap would need; using it here
  # (rather than the true 1-column wall) keeps some slack in reserve so
  # layout_row always has non-negative padding to distribute.
  local max_w=$((box_width - 4))
  local sep_w=3
  local current="" current_w=0 seg seg_w
  for seg in "${_segs[@]}"; do
    seg_w=$(content_width "$seg")
    if [ -z "$current" ]; then
      current="$seg"
      current_w=$seg_w
    elif ((current_w + sep_w + seg_w <= max_w)); then
      current="$current$SEG_SEP$seg"
      current_w=$((current_w + sep_w + seg_w))
    else
      _rows+=("$current")
      current="$seg"
      current_w=$seg_w
    fi
  done
  [ -n "$current" ] && _rows+=("$current")
}

# Segment order and row grouping: each element is a space-separated list of
# SEG_TEXT names, and each element wraps into its own row(s) independently —
# this is what keeps the badge row and the identity row visually separate
# even as either wraps onto multiple lines. Segment names are simple
# identifiers (never containing spaces), so unquoted word-splitting below is
# safe. This is the built-in default; a config replaces SEG_GROUPS wholesale.
# (Named SEG_GROUPS, not GROUPS: the latter is a bash built-in — the
# invoking user's group-ID list — and silently refuses reassignment.)
SEG_GROUPS=(
  "five_hour seven_day cpu ram context"
  "model context_size claude_ram dir repo branch pr open_pr account"
)

# A config's "groups" (array of arrays of segment names) replaces the
# default wholesale. A malformed entry (wrong shape) is dropped rather than
# aborting the whole override, so one bad group doesn't blank every group.
if [ -n "$cfg_json" ]; then
  mapfile -t cfg_groups < <(jq -r '(.groups // empty) | if type == "array" then .[] | if type == "array" then ([.[] | select(type == "string")] | join(" ")) else empty end else empty end' "$cfg_json" 2>/dev/null)
  [ "${#cfg_groups[@]}" -gt 0 ] && SEG_GROUPS=("${cfg_groups[@]}")
fi

# Per-segment priority (1-100, higher survives longer) and an optional
# max_rows target the renderer tries to respect by dropping the
# lowest-priority segments first. Priority 100 means pinned — never
# dropped — which is why the candidate filter below excludes it outright
# rather than treating it as an very-large-but-ordinary value: a pinned
# segment must never be dropped, whereas a merely-high-priority one still
# could be if nothing else is left to drop.
declare -A SEG_PRIO
for _pinned in five_hour seven_day model dir; do SEG_PRIO[$_pinned]=100; done
SEG_PRIO[cpu]=60
SEG_PRIO[ram]=60
SEG_PRIO[context]=70
SEG_PRIO[context_size]=40
SEG_PRIO[claude_ram]=30
SEG_PRIO[repo]=45
SEG_PRIO[branch]=65
SEG_PRIO[pr]=25
SEG_PRIO[open_pr]=20
SEG_PRIO[account]=10
# These built-in priorities are only ever consulted when max_rows is set
# (see below), so they're output-neutral for every existing golden — a
# config that sets max_rows without customizing priority still gets a
# sensible default drop order instead of an arbitrary one.

if [ -n "$cfg_json" ]; then
  mapfile -t cfg_prio_names < <(jq -r '(.priority // {}) | keys[]?' "$cfg_json" 2>/dev/null)
  for prio_name in "${cfg_prio_names[@]}"; do
    [[ "$prio_name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || continue
    prio_val="$(jq -r --arg n "$prio_name" '.priority[$n] // empty' "$cfg_json" 2>/dev/null)"
    if [[ "$prio_val" =~ ^[0-9]+$ ]] && [ "$prio_val" -ge 1 ] && [ "$prio_val" -le 100 ]; then
      SEG_PRIO[$prio_name]="$prio_val"
    fi
  done
fi

max_rows="$(cfg_get_num '.max_rows // empty' 0)"

# A pure function of the current SEG_DROPPED set (declared just below): wipes
# and rebuilds `rows`/`row_count` from SEG_GROUPS/SEG_TEXT, skipping any
# dropped name. Called once up front, then once per drop/restore step.
declare -A SEG_DROPPED
build_rows() {
  rows=()
  local group name val
  for group in "${SEG_GROUPS[@]}"; do
    seg_values=()
    for name in $group; do
      [ "${SEG_DROPPED[$name]:-0}" = "1" ] && continue
      val="${SEG_TEXT[$name]:-}"
      [ -n "$val" ] && seg_values+=("$val")
    done
    wrap_segments seg_values rows
  done
  row_count=${#rows[@]}
}

build_rows

# Unset/zero/negative/non-numeric all mean "unlimited" — a typo here must
# never silently blank the panel — and this whole block is skipped in that
# case, which is what keeps the no-config, no-max_rows default path
# identical to the code before this feature existed.
if [[ "$max_rows" =~ ^[0-9]+$ ]] && [ "$max_rows" -ge 1 ] && [ "$row_count" -gt "$max_rows" ]; then
  candidates=()
  for group in "${SEG_GROUPS[@]}"; do
    for name in $group; do
      [ -n "${SEG_TEXT[$name]:-}" ] || continue
      prio="${SEG_PRIO[$name]:-50}"
      [ "$prio" -ge 100 ] && continue
      candidates+=("$prio|$name")
    done
  done

  if [ "${#candidates[@]}" -gt 0 ]; then
    # Ascending priority, so the lowest-priority segment is tried first;
    # `sort -s` is stable, so ties keep declaration order rather than an
    # arbitrary one.
    mapfile -t sorted_candidates < <(printf '%s\n' "${candidates[@]}" | sort -t'|' -k1,1n -s)

    # Phase 1: drop one segment per iteration and rewrap, until the target
    # is met or every candidate is gone. A drop that buys no row is normal
    # (packing is coarse-grained) and must not stop the loop early.
    dropped_order=()
    for entry in "${sorted_candidates[@]}"; do
      [ "$row_count" -le "$max_rows" ] && break
      dropped_name="${entry#*|}"
      SEG_DROPPED[$dropped_name]=1
      dropped_order+=("$dropped_name")
      build_rows
    done

    # Phase 2: 1-opt restore. Phase 1 dropped a whole prefix of the priority
    # order and can spend a segment for nothing, so walk the casualties from
    # most to least valuable (the reverse of drop order) and put back
    # whichever ones the target can still afford.
    for ((_i = ${#dropped_order[@]} - 1; _i >= 0; _i--)); do
      restore_name="${dropped_order[$_i]}"
      unset "SEG_DROPPED[$restore_name]"
      build_rows
      if [ "$row_count" -gt "$max_rows" ]; then
        SEG_DROPPED[$restore_name]=1
        build_rows
      fi
    done
  fi
fi
row_count=${#rows[@]}

# --- Border palette --------------------------------------------------------
# One color escape per column, PAL[0..n_dashes-1]. A style just fills this
# array differently — border assembly and wall placement below only ever
# index into it, so adding a style never touches the rendering code.
# rainbow (the default) is a single awk call computing an unrounded per-column
# hue; solid/none are built directly in bash with zero forks.
style="${CAS_STYLE:-$(cfg_get '.style // empty' 'rainbow')}"
style_color="${CAS_STYLE_COLOR:-$(cfg_get '.style_options.color // empty' '#00afff')}"
[[ "$style_color" =~ ^\#?[0-9a-fA-F]{6}$ ]] || style_color="#00afff"

PAL=()
case "$style" in
  solid)
    hex="${style_color#\#}"
    r=$((16#${hex:0:2})); g=$((16#${hex:2:2})); b=$((16#${hex:4:2}))
    esc=$(printf '\033[38;2;%d;%d;%dm' "$r" "$g" "$b")
    for ((i = 0; i < n_dashes; i++)); do PAL+=("$esc"); done
    ;;
  none)
    for ((i = 0; i < n_dashes; i++)); do PAL+=(""); done
    ;;
  *)
    # rainbow, and the fallback for any unrecognized style. Advances one
    # tick per statusline execution, so the gradient visibly shifts each
    # time this script runs.
    tick_file="${CAS_TICK_FILE:-/tmp/.claude-statusline-tick}"
    tick_steps=40
    tick=0
    [ -f "$tick_file" ] && tick=$(cat "$tick_file")
    echo $(( (tick + 1) % tick_steps )) > "$tick_file"
    mapfile -t PAL < <(awk -v n="$n_dashes" -v tick="$tick" -v steps="$tick_steps" '
      function wheel(h,  r,g,b) {
        h = h - int(h/6)*6
        if (h < 1)      { r=255; g=int(255*(h-int(h))); b=0 }
        else if (h < 2) { r=int(255*(2-h)); g=255; b=0 }
        else if (h < 3) { r=0; g=255; b=int(255*(h-2)) }
        else if (h < 4) { r=0; g=int(255*(4-h)); b=255 }
        else if (h < 5) { r=int(255*(h-4)); g=0; b=255 }
        else            { r=255; g=0; b=int(255*(6-h)) }
        return sprintf("\033[38;2;%d;%d;%dm", r, g, b)
      }
      BEGIN {
        off = sprintf("%.4f", (tick / steps) * 6.0) + 0
        for (i = 0; i < n; i++) print wheel((i / n) * 6.0 + off)
      }')
    ;;
esac
# A style producing the wrong number of lines (a bad awk formula, in the
# future custom-style case) must never leave the palette short — fail closed
# to uncolored rather than corrupt every index after the gap.
if [ "${#PAL[@]}" -ne "$n_dashes" ]; then
  PAL=()
  for ((i = 0; i < n_dashes; i++)); do PAL+=(""); done
fi

# Lay out a row's segments so the slack (n_dashes minus what the segments
# and their walls actually need) is split evenly across every segment, not
# just at the row's outer edges — each segment's own slice is then centered
# within its share, and the row fills the interior width exactly.
# A wall's color depends only on its column, so walls are colored by
# indexing the same palette the border uses — they end up continuous with
# it. Wall columns are recorded into wall_at[k,i] as they're placed, for
# build_border_glyphs to read later.
declare -A wall_at
layout_row() {
  local k="$1" raw="$2"
  local -a segs
  IFS="$SEG_SEP" read -r -a segs <<< "$raw"
  local n=${#segs[@]}
  local walls=$((n - 1))
  local sum_w=0 i seg_w
  for seg in "${segs[@]}"; do
    seg_w=$(content_width "$seg")
    sum_w=$((sum_w + seg_w))
  done
  local slack=$((n_dashes - walls - sum_w))
  [ "$slack" -lt 0 ] && slack=0
  local base=$((slack / n))
  local extra=$((slack % n))

  local built="" pos=0 left_pad right_pad pad_i
  for ((i = 0; i < n; i++)); do
    pad_i=$base
    [ "$i" -lt "$extra" ] && pad_i=$((pad_i + 1))
    left_pad=$((pad_i / 2))
    right_pad=$((pad_i - left_pad))
    printf -v spaces_l '%*s' "$left_pad" ""
    printf -v spaces_r '%*s' "$right_pad" ""
    built+="${spaces_l}${segs[$i]}${spaces_r}"
    pos=$((pos + pad_i + $(content_width "${segs[$i]}")))
    if [ "$i" -lt "$((n - 1))" ]; then
      wall_at["$k,$pos"]=1
      built+="${PAL[$pos]}│\033[0m"
      pos=$((pos + 1))
    fi
  done
  # Set (not command-substitute) the result: layout_row must run in the
  # current shell, not a subshell, or its writes to wall_at above would be
  # discarded when the subshell exits.
  LAYOUT_RESULT="$built"
}

for ((k = 0; k < row_count; k++)); do
  layout_row "$k" "${rows[$k]}"
  rows[k]="$LAYOUT_RESULT"
done

right_col=$((n_dashes - 1))

# Border b sits above row b (its walls become ┬) and below row b-1 (┴); where
# both apply, ┼. build_border_glyphs fills a caller-provided array (one glyph
# per column) rather than a string, so a multibyte glyph is never sliced by
# byte offset under a non-UTF-8 locale.
build_border_glyphs() {
  local above="$1" below="$2"
  local -n _out="$3"
  _out=()
  local i has_above has_below
  for ((i = 0; i < n_dashes; i++)); do
    has_above=0
    has_below=0
    [ "$above" -ge 0 ] && [ -n "${wall_at[$above,$i]:-}" ] && has_above=1
    [ "$below" -ge 0 ] && [ -n "${wall_at[$below,$i]:-}" ] && has_below=1
    if [ "$has_above" = 1 ] && [ "$has_below" = 1 ]; then
      _out+=("┼")
    elif [ "$has_above" = 1 ]; then
      _out+=("┴")
    elif [ "$has_below" = 1 ]; then
      _out+=("┬")
    else
      _out+=("─")
    fi
  done
}

render_border_line() {
  local lc="$1" rc="$2"
  local -n _glyphs="$3"
  local i out="${PAL[0]}${lc}\033[0m"
  for ((i = 0; i < n_dashes; i++)); do
    out+="${PAL[$i]}${_glyphs[$i]}"
  done
  out+="${PAL[$right_col]}${rc}\033[0m"
  printf '%s' "$out"
}

left_bar="${PAL[0]}│\033[0m"
right_bar="${PAL[$right_col]}│\033[0m"

pad_row() {
  # layout_row already sizes content to exactly n_dashes columns; this only
  # covers rounding slop (e.g. slack not evenly divisible) as a safety net.
  local content="$1"
  local w
  w=$(content_width "$content")
  local pad=$((n_dashes - w))
  [ "$pad" -lt 0 ] && pad=0
  printf "%b%b%*s%b" "$left_bar" "$content" "$pad" "" "$right_bar"
}

output_lines=()
for ((b = 0; b <= row_count; b++)); do
  above=$((b - 1))
  below=$b
  [ "$below" -ge "$row_count" ] && below=-1
  if [ "$b" -eq 0 ]; then
    lc="┌"; rc="┐"
  elif [ "$b" -eq "$row_count" ]; then
    lc="└"; rc="┘"
  else
    lc="├"; rc="┤"
  fi
  build_border_glyphs "$above" "$below" border_glyphs
  output_lines+=("$(render_border_line "$lc" "$rc" border_glyphs)")
  [ "$b" -lt "$row_count" ] && output_lines+=("$(pad_row "${rows[$b]}")")
done

first=1
for line in "${output_lines[@]}"; do
  if [ "$first" = 1 ]; then
    printf '%b' "$line"
    first=0
  else
    printf '\n%b' "$line"
  fi
done

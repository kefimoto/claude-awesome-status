#!/usr/bin/env bash
# claude-awesome-status: a boxed statusline for Claude Code.
# 5h/7d usage | model | context | cpu/ram | directory | git branch | PR status

input=$(cat)

# Emoji/CJK codepoints that render as 2 terminal columns but count as 1 bash
# character — content_width() adds an extra column for each one it finds.
WIDE_CHAR_CLASS='[\x{1F000}-\x{1FFFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}]'

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

content_width() {
  local content="$1"
  local stripped=$(printf '%b' "$content" | sed -E 's/\x1b\[[0-9;]*m//g')
  # U+FE0F (emoji variation selector, e.g. the second codepoint in "⚠️") is a
  # zero-width modifier but bash counts it as a normal 1-column character —
  # strip it so it doesn't inflate the count.
  stripped="${stripped//$'\xef\xb8\x8f'/}"
  local visible_len=${#stripped}
  # Wide (emoji/CJK) codepoints render as 2 terminal columns but count as 1
  # bash character, so each one found needs an extra column added.
  local wide_count=$(printf '%s' "$stripped" | grep -oP "$WIDE_CHAR_CLASS" | wc -l)
  echo $((visible_len + wide_count))
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
pr_state=$(echo "$input" | jq -r '.pr.review_state // "open"')

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
  read load1 load5 load15 < "$loadavg_file"
  cpus=$(nproc 2>/dev/null || echo 1)
  load_pct=$(awk "BEGIN { printf \"%.0f\", ($load1 / $cpus) * 100 }")
  load_str=$(badge "$load_pct" 70 100 "cpu" "$(printf '%d%%' "$load_pct")")
fi

used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')

context_str=""
if [ -n "$used_pct" ] && [ -n "$context_size" ]; then
  used_tokens=$(awk "BEGIN { printf \"%.0f\", $used_pct * $context_size / 100 }")
  if [ "$used_tokens" -ge 1000000 ]; then
    used_display=$(awk "BEGIN { printf \"%.1fm\", $used_tokens / 1000000 }")
  elif [ "$used_tokens" -ge 1000 ]; then
    used_display=$(awk "BEGIN { printf \"%.1fk\", $used_tokens / 1000 }")
  else
    used_display="$used_tokens"
  fi
  if [ "$context_size" -ge 1000000 ]; then
    size_display=$(awk "BEGIN { printf \"%.1fm\", $context_size / 1000000 }")
  elif [ "$context_size" -ge 1000 ]; then
    size_display=$(awk "BEGIN { printf \"%.0fk\", $context_size / 1000 }")
  else
    size_display="$context_size"
  fi

  context_str=$(badge "$used_pct" 50 75 "ctx" "$(printf '%.0f%%' "$used_pct")")
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
  usage_str=$(badge "$five_hour_pct" 50 80 "5h" "$(printf '%.0f%%%s' "$five_hour_pct" "$remaining_str")")
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
  seven_day_str=$(badge "$seven_day_pct" 50 80 "7d" "$(printf '%.0f%%%s' "$seven_day_pct" "$seven_day_remaining_str")")
fi

# Every segment's rendered text, keyed by a stable name. A name with an empty
# or unset value is simply skipped when rows are built below — that's also
# what lets a config later hide a segment, or replace/add one, by just
# setting or clearing an entry in this same map.
declare -A SEG_TEXT

ram_str=""
if command -v free &>/dev/null; then
  read used total used_bytes total_bytes < <(free -h | awk '/^Mem:/ { match($3, /^[0-9.]+/); used=substr($3, RSTART, RLENGTH); match($2, /^[0-9.]+/); total=substr($2, RSTART, RLENGTH); print used, total, $3, $2 }')
  if [ -n "$used" ] && [ -n "$total" ]; then
    used_num=$(echo "$used" | sed 's/G//')
    total_num=$(echo "$total" | sed 's/G//')
    ram_pct=$(awk "BEGIN { printf \"%.0f\", ($used_num / $total_num) * 100 }")
    ram_str=$(badge "$ram_pct" 50 80 "ram" "${ram_pct}%")
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

# Greedily pack each line's segments into as many rows as needed so no row's
# content overruns the box — instead of overflowing, it wraps. Rows are kept
# as raw segments (joined with a unit separator, not "│") so layout_row can
# later distribute padding per-segment instead of per-row.
SEG_SEP=$'\x1f'
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

rows=()
for group in "${SEG_GROUPS[@]}"; do
  seg_values=()
  for name in $group; do
    val="${SEG_TEXT[$name]:-}"
    [ -n "$val" ] && seg_values+=("$val")
  done
  wrap_segments seg_values rows
done
row_count=${#rows[@]}

# --- Border palette --------------------------------------------------------
# One color escape per column, PAL[0..n_dashes-1]. A style just fills this
# array differently — border assembly and wall placement below only ever
# index into it, so adding a style never touches the rendering code.
# rainbow (the default) is a single awk call computing an unrounded per-column
# hue; solid/none are built directly in bash with zero forks.
style="${CAS_STYLE:-rainbow}"
style_color="${CAS_STYLE_COLOR:-#00afff}"

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
  rows[$k]="$LAYOUT_RESULT"
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

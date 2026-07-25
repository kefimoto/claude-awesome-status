#!/usr/bin/env bash
# Compare rendered output for every case against its golden file.
# Run with --update to rewrite the goldens after an intentional change.
#
#   default-<fixture>        every fixtures/*.json rendered with built-in defaults
#   cfg-<config>-<fixture>   every configs/*.{json,yaml} paired with the fixture named
#                            in its sibling .fixture file (defaults to full.json)
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
update=0
[ "${1:-}" = "--update" ] && update=1

cases=()   # name|fixture|config

for f in "$here"/fixtures/*.json; do
  [ -e "$f" ] || continue
  cases+=("default-$(basename "${f%.json}")|$f|")
done

# Config cases are discovered only if a configs/ dir exists, so this suite still
# runs against revisions that predate the config layer.
for cfg in "$here"/configs/*.json "$here"/configs/*.yaml "$here"/configs/*.yml; do
  [ -e "$cfg" ] || continue
  base=$(basename "$cfg")
  stem="${base%.*}"
  ext="${base##*.}"
  fixture="$here/fixtures/full.json"
  [ -f "$here/configs/$stem.fixture" ] && fixture="$here/fixtures/$(cat "$here/configs/$stem.fixture")"
  cases+=("cfg-$stem-$ext|$fixture|$cfg")
done

pass=0; fail=0
for c in "${cases[@]}"; do
  IFS='|' read -r name fixture config <<< "$c"
  golden="$here/golden/$name.ans"
  actual=$(bash "$here/render.sh" "$fixture" "$config" 2>/dev/null)

  if [ "$update" = 1 ]; then
    printf '%s' "$actual" > "$golden"
    echo "updated  $name"
    continue
  fi

  if [ ! -f "$golden" ]; then
    echo "MISSING  $name (no golden; run with --update)"
    fail=$((fail + 1))
    continue
  fi

  if [ "$actual" = "$(cat "$golden")" ]; then
    echo "ok       $name"
    pass=$((pass + 1))
  else
    echo "FAIL     $name"
    diff <(printf '%s' "$actual" | cat -v) <(cat -v "$golden") | head -20
    fail=$((fail + 1))
  fi
done

[ "$update" = 1 ] && exit 0
echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -gt 0 ] && exit 1
exit 0

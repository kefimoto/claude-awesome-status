# claude-awesome-status

A statusline for [Claude Code](https://claude.com/claude-code) that packs 5-hour/7-day usage, model, context, system load, git, and PR info into a boxed panel — with a border that visibly cycles color on every render.

![demo](docs/demo.gif)

*(All values above are illustrative — usage percentages, PR counts, and the account email are demo placeholders, not real data.)*

## What it shows

- **Usage badges** — 5-hour and 7-day rate-limit usage, each turning yellow then red as you approach the cap, with time-until-reset alongside.
- **System load** — CPU load average and RAM usage as the same green/yellow/red badges.
- **Context window** — used-percentage badge, plus the raw context size (`🐘 1m context`, `🐁 200k context`).
- **Model** — display name, tinted and tagged with an emoji per model family (🍃 Haiku, 🪶 Sonnet, 🎼 Opus, 🦊 Fable), plus 🚀 for fast mode and 🧠 when extended thinking is on.
- **Claude process memory** — RSS of the running `claude` process and its child processes, walked up from this script's own process ancestry.
- **Directory & git** — current working directory (home collapsed to `~`), GitHub repo slug, and current branch.
- **PR status** — the active PR number (if Claude Code reports one) and the repo's total open PR count via `gh`.
- **Account** — the logged-in Claude account email.
- **A living border** — the default style is a hue gradient that advances one tick every redraw, so it visibly animates as you work.

Rows wrap automatically to fit your terminal width, and every segment is padding-centered so the box always looks intentional, not improvised.

## Requirements

- `bash`, `jq`, `bc`, `awk`, `ps` — all standard on Linux and macOS
- [`gh`](https://cli.github.com/) (optional) — for the open-PR-count segment; the segment is simply omitted if it's not installed
- A terminal font with color emoji support (e.g. [Noto Color Emoji](https://fonts.google.com/noto/specimen/Noto+Color+Emoji)) for the emoji glyphs to render properly

## Install

```bash
git clone https://github.com/kefimoto/claude-awesome-status.git
chmod +x claude-awesome-status/statusline.sh
```

Then point Claude Code at it in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash /path/to/claude-awesome-status/statusline.sh"
  }
}
```

Start (or restart) a Claude Code session and the boxed statusline replaces the default one-liner.

## Customizing

Everything lives in one file, `statusline.sh`. A few starting points:

- **Badge thresholds** — each badge is drawn by `badge <pct> <yellow> <red> <label> <trailing>`; adjust the threshold arguments where each badge is called (e.g. the 5h/7d calls near the bottom of the script) to change when it turns yellow or red.
- **Which segments appear** — segments are added via `append "1" "$value"` / `append "2" "$value"` calls; comment one out (or reorder them) to change the layout.
- **Border speed** — `tick_steps` controls how many redraws it takes to complete one full hue cycle.

## Roadmap

- Multiple border/color styles to choose from — the animated hue gradient is just today's default, not the only option.
- A Claude Code skill to configure the statusline interactively (pick a style, toggle segments, tune thresholds, preview the result) instead of hand-editing the script.

Contributions and ideas welcome — open an issue or a PR.

## License

[MIT](LICENSE)

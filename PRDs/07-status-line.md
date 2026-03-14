# PRD-07: Status Line

## Overview

`aide-statusline` is a Python script that renders a single ANSI-colored status line for Claude Code's terminal UI. Claude Code calls it before each prompt and passes session state as JSON on stdin. The script outputs one line showing model, project folder, git branch and status, context window usage, cost, duration, and lines changed. Git info is cached for 5 seconds to avoid repeated subprocess calls.

## Requirements

- **FR-07-01** The script MUST read JSON from stdin and output a single line to stdout.
- **FR-07-02** The output MUST include: model name (with emoji by family), project folder, git branch + status indicators, context percentage (color-coded progress bar), cost in USD, and session duration.
- **FR-07-03** Git info MUST be cached per working directory with a 5-second TTL.
- **FR-07-04** The script MUST handle missing or malformed input gracefully (no crash).
- **FR-07-05** The project folder display MUST prefer `AIDE_PROJECT_NAME` env var over the actual `cwd` basename.
- **FR-07-06** The context progress bar MUST use green/yellow/red color thresholds (0–69% green, 70–89% yellow, 90–100% red).
- **FR-07-07** If an agent is active, its name MUST be shown in the status line.

## Design

### Architecture

The statusline is integrated into Claude Code via the `statusLine` setting:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/usr/local/bin/aide-statusline"
  }
}
```

This is injected by `entrypoint.sh` during the settings merge (see PRD-03). Claude Code passes the current session state as a JSON object to the command's stdin on each render.

### Input JSON Schema

Claude Code passes a JSON object with the following structure (fields may be absent):

```json
{
  "model": {
    "display_name": "claude-sonnet-4-5-20251001"
  },
  "workspace": {
    "current_dir": "/workspace/myproject"   // primary source for cwd
  },
  "cwd": "/workspace/myproject",             // fallback if workspace.current_dir absent
  "cost": {
    "total_cost_usd": 0.012,
    "total_duration_ms": 45000,
    "total_lines_added": 42,
    "total_lines_removed": 8
  },
  "context_window": {
    "used_percentage": 23
  },
  "agent": {
    "name": "backend"
  }
}
```

### Output Format

Single line, fields separated by `│` (dim ANSI):

```
  ✨ claude-sonnet-4-5  │  📁 myproject  │  🌿 main ✚2 ~1  │  ████████░░░░░░░ 52%  │  💰 $0.012  │  ⏱️  45s
```

### Model Emoji by Family

| Family | Emoji | Color |
|--------|-------|-------|
| opus | 🔮 | magenta bold |
| sonnet | ✨ | cyan bold |
| haiku | 🍃 | green bold |
| other | 🤖 | bold |

```python
def model_short(name: str) -> str:
    n = name.lower()
    if 'opus'   in n: return f"🔮 {MAG}{B}{name}{R}"
    if 'sonnet' in n: return f"✨ {CYA}{B}{name}{R}"
    if 'haiku'  in n: return f"🍃 {GRN}{B}{name}{R}"
    return f"🤖 {B}{name}{R}"
```

### Context Progress Bar

```python
def progress_bar(pct: int, width: int = 16) -> str:
    filled = round(pct * width / 100)
    empty  = width - filled
    clr = RED if pct >= 90 else YLW if pct >= 70 else GRN
    return f"{clr}{'█' * filled}{'░' * empty}{R}"
```

### Git Info Cache

Cache stored at `/tmp/aide-statusline-cache.json`. Structure:

```json
{
  "/workspace/myproject": {
    "ts": 1700000000.0,
    "data": {
      "branch": "main",
      "staged": 2,
      "modified": 1,
      "untracked": 0,
      "lines_added": 42,
      "lines_removed": 8
    }
  }
}
```

Cache is keyed by working directory. Entries older than 5 seconds are refreshed. Cache read/write failures are silently ignored.

```python
CACHE_FILE    = '/tmp/aide-statusline-cache.json'
CACHE_MAX_AGE = 5  # seconds

def get_git_info(cwd: str) -> dict | None:
    cache = _read_cache()
    entry = cache.get(cwd, {})
    if time.time() - entry.get('ts', 0) < CACHE_MAX_AGE:
        return entry.get('data')
    # ... run git commands, update cache ...
```

### Git Status Indicators

From `git status --porcelain`:

| Indicator | Symbol | Color |
|-----------|--------|-------|
| Staged changes | `✚N` | green |
| Unstaged modifications | `~N` | yellow |
| Untracked files | `?N` | dim |

Lines added/removed are from `git diff --numstat HEAD`.

### AIDE_PROJECT_NAME

`bin/aide` passes `AIDE_PROJECT_NAME=$(basename "$PWD")` to the container. The statusline prefers this over `os.path.basename(cwd)` because `cwd` inside the container is `/workspace`, not the original host path:

```python
folder = os.environ.get('AIDE_PROJECT_NAME') \
         or os.path.basename(cwd.rstrip('/')) or cwd
```

### Duration Formatting

Durations are displayed as `Xs`, `Xm XXs`, or `Xh Xm` depending on magnitude.

### Implementation Hints

The script is installed at `/usr/local/bin/aide-statusline` (executable). It is referenced by its full path in the statusline setting so it works regardless of the user's `$PATH`.

The `entrypoint.sh` settings merge always injects the statusline setting, even if the user already has a `statusLine` defined (the policy merge overwrites it). This ensures the statusline is always active.

### Dependencies

**Depends on:** Python 3 (in image), `git` (in image), `AIDE_PROJECT_NAME` env var (from `bin/aide`)

**Required by:** Claude Code terminal UI (reads the setting from `~/.claude/settings.json`)

## Acceptance Criteria

- The status line renders below each Claude prompt
- Model emoji changes when switching between Opus/Sonnet/Haiku
- Git branch and dirty indicators update within 5 seconds of a commit or file change
- Context bar turns yellow above 70% and red above 90%
- Cost and duration increment during long sessions
- `AIDE_PROJECT_NAME` is displayed, not `/workspace`
- Script exits cleanly if stdin is empty or malformed JSON

## Open Questions / Future Work

- Token count display (absolute, not just percentage)
- Configurable color thresholds
- Cache invalidation on `git checkout` (branch change)

#!/usr/bin/env python3
"""aide-statusline — ANSI status line for Claude Code."""

import json
import os
import subprocess
import sys
import time

# ANSI escape codes
R = "\033[0m"
B = "\033[1m"
DIM = "\033[2m"
RED = "\033[31m"
GRN = "\033[32m"
YLW = "\033[33m"
CYA = "\033[36m"
MAG = "\033[35m"

CACHE_FILE = "/tmp/aide-statusline-cache.json"
CACHE_MAX_AGE = 5  # seconds
SEP = f" {DIM}│{R} "


def model_short(name: str) -> str:
    n = name.lower()
    if "opus" in n:
        return f"🔮 {MAG}{B}{name}{R}"
    if "sonnet" in n:
        return f"✨ {CYA}{B}{name}{R}"
    if "haiku" in n:
        return f"🍃 {GRN}{B}{name}{R}"
    return f"🤖 {B}{name}{R}"


def progress_bar(pct: int, width: int = 16) -> str:
    filled = round(pct * width / 100)
    empty = width - filled
    clr = RED if pct >= 90 else YLW if pct >= 70 else GRN
    return f"{clr}{'█' * filled}{'░' * empty}{R} {pct}%"


def fmt_duration(ms: float) -> str:
    secs = int(ms / 1000)
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m {secs % 60:02d}s"
    return f"{secs // 3600}h {(secs % 3600) // 60}m"


def _read_cache() -> dict:
    try:
        with open(CACHE_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {}


def _write_cache(cache: dict) -> None:
    try:
        with open(CACHE_FILE, "w") as f:
            json.dump(cache, f)
    except Exception:
        pass


def _run(cmd: list[str], cwd: str) -> str:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=3, cwd=cwd)
        return r.stdout.strip()
    except Exception:
        return ""


def get_git_info(cwd: str) -> dict | None:
    cache = _read_cache()
    entry = cache.get(cwd, {})
    if time.time() - entry.get("ts", 0) < CACHE_MAX_AGE:
        return entry.get("data")

    branch = _run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd)
    if not branch:
        return None

    porcelain = _run(["git", "status", "--porcelain"], cwd)
    staged = 0
    modified = 0
    untracked = 0
    for line in porcelain.splitlines():
        if len(line) < 2:
            continue
        x, y = line[0], line[1]
        if x in "MADRC":
            staged += 1
        if y in "MD":
            modified += 1
        if x == "?" and y == "?":
            untracked += 1

    data = {
        "branch": branch,
        "staged": staged,
        "modified": modified,
        "untracked": untracked,
    }

    cache[cwd] = {"ts": time.time(), "data": data}
    _write_cache(cache)
    return data


def main() -> None:
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        data = {}

    parts: list[str] = []

    # Model
    model_info = data.get("model", {})
    model_name = model_info.get("display_name", "")
    if model_name:
        parts.append(model_short(model_name))

    # Project folder
    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd", "")
    folder = os.environ.get("AIDE_PROJECT_NAME") or os.path.basename(cwd.rstrip("/")) or cwd
    if folder:
        parts.append(f"📁 {B}{folder}{R}")

    # Agent
    agent = (data.get("agent") or {}).get("name", "")
    if agent:
        parts.append(f"🤖 {DIM}{agent}{R}")

    # Git
    if cwd:
        git = get_git_info(cwd)
        if git:
            indicators = []
            if git["staged"]:
                indicators.append(f"{GRN}✚{git['staged']}{R}")
            if git["modified"]:
                indicators.append(f"{YLW}~{git['modified']}{R}")
            if git["untracked"]:
                indicators.append(f"{DIM}?{git['untracked']}{R}")
            branch_str = f"🌿 {git['branch']}"
            if indicators:
                branch_str += " " + " ".join(indicators)
            parts.append(branch_str)

    # Context window
    ctx = data.get("context_window", {})
    pct = ctx.get("used_percentage")
    if pct is not None:
        parts.append(progress_bar(int(pct)))

    # Cost
    cost_info = data.get("cost", {})
    cost = cost_info.get("total_cost_usd")
    if cost is not None:
        parts.append(f"💰 ${cost:.3f}")

    # Duration
    duration_ms = cost_info.get("total_duration_ms")
    if duration_ms is not None:
        parts.append(f"⏱️  {fmt_duration(duration_ms)}")

    print(SEP.join(parts) if parts else "")


if __name__ == "__main__":
    main()

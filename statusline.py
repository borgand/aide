#!/usr/bin/env python3
"""aide statusline — single-line, cached git info."""
import json
import os
import subprocess
import sys
import time

# ── ANSI palette ──────────────────────────────────────────────────────────────
R   = '\033[0m'
B   = '\033[1m'
DIM = '\033[2m'
CYA = '\033[36m'
GRN = '\033[32m'
YLW = '\033[33m'
RED = '\033[31m'
MAG = '\033[35m'
BLU = '\033[34m'

SEP = f" {DIM}│{R} "

CACHE_FILE    = '/tmp/aide-statusline-cache.json'
CACHE_MAX_AGE = 5


# ── Cache helpers ─────────────────────────────────────────────────────────────

def _read_cache() -> dict:
    try:
        with open(CACHE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def _write_cache(cache: dict) -> None:
    try:
        with open(CACHE_FILE, 'w') as f:
            json.dump(cache, f)
    except Exception:
        pass


# ── Git info (cached) ────────────────────────────────────────────────────────

def get_git_info(cwd: str) -> dict | None:
    cache = _read_cache()
    entry = cache.get(cwd, {})
    if time.time() - entry.get('ts', 0) < CACHE_MAX_AGE:
        return entry.get('data')

    try:
        subprocess.check_output(
            ['git', 'rev-parse', '--git-dir'],
            stderr=subprocess.DEVNULL, cwd=cwd
        )
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        cache[cwd] = {'ts': time.time(), 'data': None}
        _write_cache(cache)
        return None

    try:
        branch = subprocess.check_output(
            ['git', 'branch', '--show-current'],
            text=True, stderr=subprocess.DEVNULL, cwd=cwd
        ).strip() or 'HEAD'

        porcelain = subprocess.check_output(
            ['git', 'status', '--porcelain'],
            text=True, stderr=subprocess.DEVNULL, cwd=cwd
        ).strip()

        staged = modified = untracked = 0
        for line in (porcelain.splitlines() if porcelain else []):
            if len(line) < 2:
                continue
            x, y = line[0], line[1]
            if x == '?' and y == '?':
                untracked += 1
            else:
                if x not in (' ', '?'):
                    staged += 1
                if y in ('M', 'D', 'A'):
                    modified += 1

        # Lines added/removed across all tracked changes
        try:
            diff_stat = subprocess.check_output(
                ['git', 'diff', '--numstat', 'HEAD'],
                text=True, stderr=subprocess.DEVNULL, cwd=cwd
            ).strip()
            git_add = git_del = 0
            for dline in (diff_stat.splitlines() if diff_stat else []):
                parts = dline.split('\t')
                if len(parts) >= 2:
                    try:
                        git_add += int(parts[0])
                        git_del += int(parts[1])
                    except ValueError:
                        pass
        except Exception:
            git_add = git_del = 0

        data = {'branch': branch, 'staged': staged,
                'modified': modified, 'untracked': untracked,
                'lines_added': git_add, 'lines_removed': git_del}
    except Exception:
        data = None

    cache[cwd] = {'ts': time.time(), 'data': data}
    _write_cache(cache)
    return data


# ── Rendering helpers ────────────────────────────────────────────────────────

def progress_bar(pct: int, width: int = 16) -> str:
    filled = round(pct * width / 100)
    empty  = width - filled
    clr = RED if pct >= 90 else YLW if pct >= 70 else GRN
    return f"{clr}{'█' * filled}{'░' * empty}{R}"


def fmt_duration(ms: int) -> str:
    s = ms // 1000
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    if h:
        return f"{h}h {m}m"
    if m:
        return f"{m}m {sec:02d}s"
    return f"{sec}s"


def model_short(name: str) -> str:
    n = name.lower()
    if 'opus'   in n: return f"🔮 {MAG}{B}{name}{R}"
    if 'sonnet' in n: return f"✨ {CYA}{B}{name}{R}"
    if 'haiku'  in n: return f"🍃 {GRN}{B}{name}{R}"
    return f"🤖 {B}{name}{R}"


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        print("  statusline: parse error")
        return

    model    = (data.get('model') or {}).get('display_name', '?')
    cwd      = (data.get('workspace') or {}).get('current_dir') \
               or data.get('cwd') or os.getcwd()

    cost_obj = data.get('cost') or {}
    cost     = float(cost_obj.get('total_cost_usd')      or 0)
    dur_ms   = int(  cost_obj.get('total_duration_ms')    or 0)
    lines_add = int( cost_obj.get('total_lines_added')    or 0)
    lines_rem = int( cost_obj.get('total_lines_removed')  or 0)

    ctx_obj  = data.get('context_window') or {}
    pct      = int(float(ctx_obj.get('used_percentage')   or 0))

    agent_name = (data.get('agent') or {}).get('name')

    # ── Build parts ──────────────────────────────────────────────────────────
    parts = [model_short(model)]

    # Working directory — prefer host project name injected by aide
    folder = os.environ.get('AIDE_PROJECT_NAME') \
             or os.path.basename(cwd.rstrip('/')) or cwd
    parts.append(f"📁 {B}{folder}{R}")

    # Git branch + stats
    git = get_git_info(cwd)
    if git:
        branch_str = f"🌿 {GRN}{git['branch']}{R}"
        flags = []
        if git['staged']:
            flags.append(f"{GRN}✚{git['staged']}{R}")
        if git['modified']:
            flags.append(f"{YLW}~{git['modified']}{R}")
        if git['untracked']:
            flags.append(f"{DIM}?{git['untracked']}{R}")
        if flags:
            branch_str += f" {' '.join(flags)}"
        # Git diff lines
        gl_add = git.get('lines_added', 0)
        gl_rem = git.get('lines_removed', 0)
        if gl_add or gl_rem:
            branch_str += f"  {GRN}+{gl_add}{R}/{RED}-{gl_rem}{R}"
        parts.append(branch_str)

    # Agent
    if agent_name:
        parts.append(f"{MAG}{agent_name}{R}")

    # Context bar
    pct_clr = RED if pct >= 90 else YLW if pct >= 70 else GRN
    parts.append(f"{progress_bar(pct)} {pct_clr}{pct}%{R}")

    # Cost
    parts.append(f"💰 {YLW}${cost:.3f}{R}")

    # Duration
    if dur_ms:
        parts.append(f"⏱️  {BLU}{fmt_duration(dur_ms)}{R}")

    # Lines changed
    if lines_add or lines_rem:
        parts.append(f"📝 {GRN}+{lines_add}{R}/{RED}-{lines_rem}{R}")

    print("  " + SEP.join(parts))


if __name__ == '__main__':
    main()

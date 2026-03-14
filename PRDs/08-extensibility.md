# PRD-08: Extensibility

## Overview

aide extends Claude Code's native extensibility mechanisms — slash commands, skills, and agents — by bind-mounting additional directories into the container at startup. A shared library pattern (`skills-repo/`, `commands-repo/`) lets teams maintain and distribute reusable extensions. The container's `.claude/commands/`, `.claude/skills/`, and `.claude/agents/` directories are populated from these repos via symlinks.

## Requirements

- **FR-08-01** Custom slash commands in `.claude/commands/` MUST be available inside the container.
- **FR-08-02** Skills in `.claude/skills/` MUST be available inside the container.
- **FR-08-03** Agent definitions in `.claude/agents/` MUST be available inside the container.
- **FR-08-04** Bind mounts MUST be read-only (`:ro`) to prevent Claude from modifying shared extensions.
- **FR-08-05** The `skills-repo/` and `commands-repo/` directories MUST be symlinked into `.claude/` so additions to the repo are immediately reflected.

## Design

### Architecture

```
AIDE_ROOT/
├── .claude/
│   ├── commands/        → bind-mounted into container as /home/aide/.claude/commands/:ro
│   ├── skills/          → bind-mounted into container as /home/aide/.claude/skills/:ro
│   ├── agents/          → bind-mounted into container as /home/aide/.claude/agents/:ro
│   ├── settings.json    → user Claude Code settings (merged at startup)
│   ├── mcp.json         → user MCP server config (merged at startup)
│   └── .claude.json     → Claude Code session state (persisted via inotifywait)
├── skills-repo/         → shared skill library (symlinked from .claude/skills/)
└── commands-repo/       → shared command library (symlinked from .claude/commands/)
```

### Bind Mounts

`bin/aide` mounts the `.claude/` directory from `AIDE_ROOT`:

```bash
-v "$AIDE_ROOT/.claude:/home/aide/.claude"
```

This single mount makes all subdirectories (`commands/`, `skills/`, `agents/`) available inside the container at their standard Claude Code locations.

The bind-mount is NOT read-only at the top level because `entrypoint.sh` needs to write `settings.json`, `mcp.json`, and `.claude.json` into `/home/aide/.claude/`. Individual subdirectories (`commands/`, `skills/`, `agents/`) should be read-only by convention, but this is enforced by using symlinks to the repo directories (the repos themselves are not mounted separately).

### Slash Commands

Claude Code loads slash commands from `~/.claude/commands/<name>.md`. The command name is the filename without extension. Example:

```
.claude/commands/deploy.md  →  /deploy
.claude/commands/review.md  →  /review
```

**Command file format:**

```markdown
# /command-name

Brief description of what the command does.

## Instructions

Detailed instructions for Claude. Can include:
- Step-by-step tasks
- Variables like $ARGUMENTS (replaced with text after the slash command)
- File paths to read
- Shell commands to run
```

### Skills

Skills are reusable instruction sets that Claude can reference. They live in `.claude/skills/<skill-name>/SKILL.md`. Claude Code makes skills available as context when invoked with the skill's name.

**Skill directory structure:**

```
.claude/skills/
└── my-skill/
    ├── SKILL.md       ← main skill instructions (required)
    └── examples/      ← optional supporting files
```

**SKILL.md format:**

```markdown
# Skill: my-skill

## Purpose
What this skill teaches Claude to do.

## Instructions
Detailed instructions, patterns, and examples.

## When to Use
Describe the trigger conditions for this skill.
```

### Agent Definitions

Agent definitions live in `.claude/agents/<name>.md`. Each file defines a specialized subagent with its own instructions and tool access.

**Agent file format:**

```markdown
---
name: agent-name
description: Brief description for agent selection
tools: Read, Write, Bash, Grep
---

# Agent Instructions

Detailed instructions for this agent's behavior and specialization.
```

The `tools` frontmatter field restricts which tools the agent can use (optional).

### Shared Repos

The `skills-repo/` and `commands-repo/` directories hold the shared library. They are symlinked into `.claude/` so any addition to the repo is immediately visible without running any sync command:

```bash
# Example setup
ln -s ../../skills-repo .claude/skills/shared
ln -s ../../commands-repo .claude/commands/shared
```

The symlinks must be relative paths that resolve entirely within `AIDE_ROOT`. Docker does NOT follow symlinks at bind-mount time — a symlink pointing outside the mounted directory tree will appear as a broken link inside the container. Relative symlinks like `../../skills-repo` work as long as `skills-repo/` is inside `AIDE_ROOT`.

### Example: aide-config Skill

An example skill that helps bootstrap new projects with aide:

```
.claude/skills/aide-config/
└── SKILL.md
```

Content guides Claude through generating `aide.yaml` for a new project, detecting the Docker socket, kubeconfig, and extra domain requirements.

### Example Command Template

```markdown
# /analyze

Analyze the current codebase and produce a summary report.

## Instructions

1. Read the project root to understand the structure
2. Identify the main language and framework
3. List key components and their responsibilities
4. Note any obvious issues or improvement areas
5. Output a concise Markdown report

Focus on: $ARGUMENTS
```

### Implementation Hints

**Bind mount order:** The `.claude/` directory must exist before `docker run` or Docker will create it as `root:root`, which the `aide` user cannot write to. `bin/aide` pre-creates it:

```bash
mkdir -p "$AIDE_ROOT/.claude"
```

**Symlink resolution:** Docker's bind mount resolves symlinks on the host and mounts the target. Symlinks within the mounted directory pointing to paths outside the mount root will be broken inside the container. Keep all symlinks within the `.claude/` tree or use relative symlinks that resolve within `AIDE_ROOT`.

**Read-only gotcha:** The `.claude/` mount cannot be fully read-only because `entrypoint.sh` writes config files into it. If you want to protect specific subdirectories from Claude, use a separate read-only mount for those directories.

### Dependencies

**Depends on:** `bin/aide` (bind-mount setup); Claude Code (extension loading mechanism)

**Required by:** Custom project workflows, shared team tooling

## Acceptance Criteria

- Slash commands in `.claude/commands/` are available inside the container as `/command-name`
- Skills in `.claude/skills/<name>/SKILL.md` are loadable
- Agent definitions in `.claude/agents/<name>.md` are available as subagents
- Changes to files in `skills-repo/` are reflected inside the container without restart (symlinks work)
- Claude Code cannot write to `commands/`, `skills/`, `agents/` (enforced by repo permissions or symlink convention)

## Open Questions / Future Work

- Versioning shared skills/commands (git submodules or package manager)
- Per-project skill overrides (project-local `.claude/skills/` that shadow shared ones)

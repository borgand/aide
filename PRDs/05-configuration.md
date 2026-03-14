# PRD-05: Configuration

## Overview

aide uses a layered configuration system. `aide.yaml` is the committed project-level config; `aide.local.yaml` holds per-engineer overrides and is gitignored. Environment variables provide runtime overrides. `firewall-domains.local.txt` is a gitignored file for adding extra firewall domains without modifying `aide.yaml`.

## Requirements

- **FR-05-01** `aide.yaml` MUST be auto-loaded from `$PWD` on each `aide` invocation.
- **FR-05-02** `aide.local.yaml` MUST be auto-loaded from `$PWD`; its scalar values MUST override `aide.yaml`; its list values MUST be appended.
- **FR-05-03** `--config <path>` MUST load an explicit config file instead of auto-discovering `aide.yaml`; `aide.local.yaml` MUST NOT be loaded when `--config` is used.
- **FR-05-04** `AIDE_EXTRA_DOMAINS` env var MUST be appended to the firewall allowlist.
- **FR-05-05** `firewall-domains.local.txt` MUST be read from `AIDE_ROOT` and its domains appended to the firewall allowlist.
- **FR-05-06** `aide.local.yaml` and `firewall-domains.local.txt` MUST be listed in `.gitignore` for any project using aide.
- **FR-05-07** aide MUST warn (not error) if `aide.local.yaml` exists but is not in `.gitignore`.

## Design

### File Locations

| File | Location | Committed? | Purpose |
|------|----------|-----------|---------|
| `aide.yaml` | `$PWD` or `--config` path | Yes | Project-level config |
| `aide.local.yaml` | `$PWD` | No (gitignore) | Per-engineer overrides |
| `firewall-domains.local.txt` | `$AIDE_ROOT` (repo dir, **not** project `$PWD`) | No (gitignore) | Extra firewall domains |

### aide.yaml Schema

```yaml
# Docker socket passthrough
# Values: "rancher" (preset) or absolute path to socket file
docker: rancher

# Kubeconfig path (~ expanded)
# Enables kubectl/helm/kustomize inside the container
kube: ~/.kube/config

# Override host IP for socat proxy binding
# Useful when auto-detection fails or returns wrong IP
host_ip: 192.168.64.1

# Extra domains to add to the firewall allowlist (appended to defaults)
extra_domains:
  - registry.example.com
  - cdn.example.com

# LAN hosts to proxy through the VM (default port 443)
lan_hosts:
  - harvester.local
  - myhost.local:8080
```

All fields are optional.

### aide.local.yaml Schema

Identical schema to `aide.yaml`. Scalar fields override; list fields append:

```yaml
# Example: engineer-specific overrides
docker: /custom/path/docker.sock
extra_domains:
  - internal-ci.local
```

### Configuration Layering

Precedence order (highest → lowest):

```
1. CLI flag (--docker, --kube, --host-ip, --lan-host)
2. aide.local.yaml (only when using auto-discovery)
3. aide.yaml (or --config file)
4. AIDE_EXTRA_DOMAINS env var
5. Built-in defaults
```

For scalars (`docker`, `kube`, `host_ip`): higher source wins.
For lists (`extra_domains`, `lan_hosts`): all sources are concatenated.

### Environment Variables

| Variable | Type | Source | Purpose |
|----------|------|--------|---------|
| `ANTHROPIC_API_KEY` | secret | host env | Claude API key (passed through as-is) |
| `AIDE_EXTRA_DOMAINS` | space-separated FQDNs | host env | Additional firewall domains |
| `AIDE_CA_CERT_FILE` | file path | host env | CA cert to inject during `aide build` |

`AIDE_EXTRA_DOMAINS` is merged from three sources in `bin/aide`:
1. `CONF_EXTRA_DOMAINS` from `aide.yaml`
2. `_local_extra_domains` from `aide.local.yaml`
3. Contents of `firewall-domains.local.txt`

All three are concatenated into a single space-separated string and exported as `AIDE_EXTRA_DOMAINS`.

### firewall-domains.local.txt

One FQDN per line. Lines beginning with `#` are treated as comments. Example:

```
# Internal package registry
artifactory.mycompany.example.com
# VPN-accessible CI server
ci.mycompany.example.com
```

`bin/aide` reads this file with:

```bash
file_domains=$(grep -v '^\s*#' "$AIDE_ROOT/firewall-domains.local.txt" | tr '\n' ' ' | xargs || true)
export AIDE_EXTRA_DOMAINS="${AIDE_EXTRA_DOMAINS:+$AIDE_EXTRA_DOMAINS }$file_domains"
```

### Recommended .gitignore Entries

Projects using aide should add these to `.gitignore`:

```
aide.local.yaml
firewall-domains.local.txt
.claude/
```

The `.claude/` directory holds Claude's state (settings, MCP config, session data) and should not be committed.

### Config Parsing Implementation

The pure-Bash parser (`parse_aide_config`) handles a strict subset of YAML:
- Scalar keys: `key: value`
- List keys: `key:` followed by lines matching `  - item`
- `~` in values is expanded to `$HOME` for `kube:` field only
- Other YAML features (anchors, multi-line values, quoted strings with colons) are NOT supported

If a project needs more complex config, use CLI flags or environment variables.

### Dependencies

**Depends on:** `bin/aide` for parsing and merging; `init-firewall.sh` for consuming `AIDE_EXTRA_DOMAINS`

**Required by:** `bin/aide` (reads the files); `init-firewall.sh` (reads `AIDE_EXTRA_DOMAINS` env var)

## Acceptance Criteria

- `aide` auto-loads `aide.yaml` from the current directory without any flags
- Values in `aide.local.yaml` override scalars from `aide.yaml`
- Lists in both files are concatenated
- `--config other.yaml` loads only that file (not `aide.local.yaml`)
- Domains in `firewall-domains.local.txt` are reachable from inside the container after restart
- Warning is printed if `aide.local.yaml` exists but is not in `.gitignore`
- `AIDE_EXTRA_DOMAINS=foo.example.com aide` adds that domain to the allowlist

## Open Questions / Future Work

- JSON Schema for `aide.yaml` to enable editor validation
- `aide config check` subcommand to validate configuration

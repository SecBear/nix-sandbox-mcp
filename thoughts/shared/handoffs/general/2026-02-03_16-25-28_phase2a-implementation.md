---
date: 2026-02-03T22:25:28+0000
researcher: claude
git_commit: 6a73090bfc4789b5f957c694328e8cd6d5fe8f0c
branch: main
repository: nix-sandbox-mcp
topic: "Phase 2a: run Tool and Project Context Implementation"
tags: [implementation, nix, mcp, sandboxing, phase2a]
status: in_progress
last_updated: 2026-02-03
last_updated_by: claude
type: implementation_strategy
---

# Handoff: Phase 2a Implementation - run Tool and Project Context

## Task(s)

Implementing Phase 2a from the plan at `thoughts/shared/plans/2026-02-02-phase2a-run-tool-and-project-context.md`.

| Phase | Status | Notes |
|-------|--------|-------|
| 2a.1: New `run` Tool Interface | **Completed** | Already implemented in Phase 1 migration |
| 2a.2: Project Mounting | **In Progress** | Rust config done, Nix changes pending |
| 2a.3: User-Specified Flake References | Pending | |
| 2a.4: Project Flake Integration | Pending | |
| 2a.5: Dynamic Tool Description | Pending | Basic version exists, needs project info |
| 2a.6: Timeout Enforcement | Pending | Works but needs better error message |
| Update config.example.toml and tests | Pending | |

## Critical References

- **Plan document**: `thoughts/shared/plans/2026-02-02-phase2a-run-tool-and-project-context.md`
- **Key insight**: Environment auto-detection was explicitly rejected in favor of required `environment` parameter (Claude selects based on task reasoning)

## Recent changes

Changes made this session to `daemon/src/config.rs`:
- Added `ProjectConfig` struct with fields: `path`, `mode`, `mount_point`, `use_flake`, `inherit_env`
- Added `MountMode` enum (`Readonly`, `Readwrite`)
- Added `InheritEnv` struct for environment variable passthrough
- Changed `Config` to derive `Deserialize` with `environments` as a nested field
- Updated `Config::from_env()` and `Config::from_json()` to parse full config structure
- Added test `parse_metadata_with_project` for project config parsing

Changes to `daemon/src/mcp.rs`:
- Fixed `test_config()` to include `project: None`

## Learnings

1. **Sandboxing requires Linux**: The project uses `jail.nix` (bubblewrap) which only works on Linux. On macOS, only the daemon binary builds - no sandbox wrappers. Tests in `test-local.sh` must run on Linux.

2. **Config structure changed**: The `NIX_SANDBOX_METADATA` JSON now needs to be a full `Config` object with `environments` as a nested key, not a flat map. The Nix side (`fromToml.nix`) will need to generate this new structure.

3. **flake.nix behavior**:
   - On Linux: `nix build .#default` builds the full MCP server with sandboxed environments
   - On macOS: `nix build .#default` only builds the daemon binary
   - The `mkServer` function in `flake.nix:66-77` wraps the daemon with `NIX_SANDBOX_METADATA`

## Artifacts

- `daemon/src/config.rs` - Updated with ProjectConfig, MountMode, InheritEnv types
- `daemon/src/mcp.rs:188-203` - Updated test helper

## Action Items & Next Steps

1. **Complete 2a.2 - Project Mounting (Nix side)**:
   - Update `nix/backends/jail.nix` to add project mounting parameters to `mkJailedEnv`:
     - `projectPath`, `projectMount`, `projectReadonly` parameters
     - Add `c.readonly` or `c.rw-bind` combinators based on mode
   - Update `nix/lib/fromToml.nix` to:
     - Parse `[project]` section from TOML
     - Pass project config to jail backend
     - Generate new metadata JSON structure with `environments` nested key

2. **Implement 2a.3 - User-Specified Flake References**:
   - In `fromToml.nix`, handle `flake = "github:..."` in environment config
   - Parse `flakeref#attr` format
   - Support custom `interpreter` config

3. **Implement 2a.4 - Project Flake Integration**:
   - When `use_flake = true`, auto-create "project" environment from project's devShell
   - Handle `inherit_env.vars` for environment variable passthrough

4. **Implement 2a.5 - Dynamic Tool Description**:
   - Update `mcp.rs` `get_info()` to include project mount info when configured

5. **Implement 2a.6 - Better Timeout Error**:
   - Change `jail.rs:59` error from "Execution timed out" to include duration

6. **Update config.example.toml** with `[project]` section examples

7. **Run full integration tests on Linux** using `./test-local.sh`

## Other Notes

- The plan explicitly states: "Flake references come from config only, never from LLM tool parameters" - this is a security boundary
- All daemon unit tests pass: `cargo test` shows 5 passing tests
- The existing `test-local.sh` already tests the `run` tool interface (Phase 2a.1)
- Key jail.nix combinators to use: `c.readonly`, `c.rw-bind`, `c.set-env`

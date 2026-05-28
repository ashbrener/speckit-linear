# Changelog

All notable changes to **speckit-linear** are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial spec-kit scaffolding via `specify init --here --integration claude`.
- Kickoff brief (`BRIEF.md`) capturing the architectural decisions reached
  during the BLOK9 planning session on 2026-05-27.
- Pre-clarify validation of the official Linear MCP capability surface
  (`validation/linear-mcp-capability-check.md`).
- First-pass feature specification for the bridge itself
  (`specs/001-spec-kit-linear-bridge/spec.md`) — clarification-clean, locked
  data-model mapping `Project=repo / Issue=spec / sub-issue=Phase /
  checklist=tasks`.
- Background research informing `/speckit-plan`:
  - `validation/linear-mcp-tool-signatures.md` — concrete MCP tool names +
    GraphQL fallback shapes.
  - `validation/linear-github-integrations-survey.md` — patterns from
    Linear's official GitHub integration and adjacent community tooling.

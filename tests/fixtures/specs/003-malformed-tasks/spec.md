# Feature Specification: Malformed Tasks Fixture

**Feature Branch**: `003-malformed-tasks`

**Created**: 2026-05-28

**Status**: Draft

## Overview

`tasks.md` contains a task line outside any `## Phase N:` heading.
Used by the parser tests to verify
`parser::malformed_task_lines` flags it (FR-024 + SC-007).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Warning surface for malformed task entries (Priority: P1)

Operator left a task line above the first `## Phase` heading.

**Acceptance Scenarios**:

1. **Given** `tasks.md` has a `- [ ] T003-001 …` line above any
   `## Phase` header, **When** the parser is invoked, **Then** the
   malformed line is reported as a warning (not a hard error).

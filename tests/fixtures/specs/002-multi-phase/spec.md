# Feature Specification: Multi-Phase Tasks Fixture

**Feature Branch**: `002-multi-phase`

**Created**: 2026-05-28

**Status**: Draft

## Overview

A spec that has progressed through `/speckit-plan` and `/speckit-tasks`.
Used by the parser tests to verify (a) `lifecycle_phase` returns
`tasking` once `tasks.md` exists with no implementation evidence, and
(b) `task_phases` correctly enumerates three `## Phase N:` headers
with inter-phase ordering.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Multi-phase implementation plan (Priority: P1)

Operator has decomposed the spec into three task phases with explicit
inter-phase dependencies declared in `tasks.md`.

**Acceptance Scenarios**:

1. **Given** `spec.md`, `plan.md`, and `tasks.md` exist (no
   `red-team*.md`, no `analyze*.md`, no checked tasks), **When** the
   parser is invoked, **Then** the inferred lifecycle phase is
   `tasking` and exactly three task phases are reported.

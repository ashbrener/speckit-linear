# Feature Specification: Minimal Spec Fixture

**Feature Branch**: `001-minimal`

**Created**: 2026-05-28

**Status**: Draft

## Overview

Smallest valid spec — `spec.md` only, no `plan.md` / `tasks.md` /
clarifications. Used by `parser::lifecycle_phase` to verify the
`specifying` end of the inference ladder (FR-012).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Bare specification (Priority: P1)

Operator writes a fresh spec and has not yet ratified any
clarifications or planned the work.

**Acceptance Scenarios**:

1. **Given** only `spec.md` exists, **When** the parser is invoked,
   **Then** the inferred lifecycle phase is `specifying`.

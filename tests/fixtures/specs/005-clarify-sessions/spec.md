# Feature Specification: Clarify Sessions Fixture

**Feature Branch**: `005-clarify-sessions`

**Created**: 2026-05-01

**Status**: Draft

## Overview

A spec that has progressed past `/speckit-specify` into
`/speckit-clarify` but has not yet been planned. Used by parser tests
to verify (a) `lifecycle_phase` returns `clarifying`, and (b)
`clarify_sessions` enumerates three `### Session YYYY-MM-DD` blocks
each with two Q/A bullets (FR-008 + FR-015).

## Clarifications

### Session 2026-05-01

- Q: Should the bridge mirror clarify sessions as Linear comments? → A: Yes — one comment per ratified session, idempotent.
- Q: Are operator edits to those comments preserved on resync? → A: No — reconcile rewrites them to match `spec.md`.

### Session 2026-05-15

- Q: How is each session keyed for idempotency? → A: Deterministic UUIDv4 derived from `(spec_id, session_date)`.
- Q: Are sessions posted in chronological order? → A: Yes — Linear's native `createdAt` ordering matches filesystem order.

### Session 2026-05-28

- Q: Does the bridge introduce a separate "ratified" lifecycle phase? → A: No — canonical spec-kit treats accepted clarifications as part of `spec.md` immediately.
- Q: What happens when a session bullet is deleted from `spec.md`? → A: The mirrored comment is left in place (Linear comments are append-only from the bridge's perspective).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Clarify session mirroring (Priority: P1)

Operator has run three rounds of `/speckit-clarify` and wants each
ratified session reflected as a Linear comment.

**Acceptance Scenarios**:

1. **Given** `spec.md` contains three `### Session YYYY-MM-DD`
   blocks, **When** the parser is invoked, **Then** three sessions
   are reported each with two Q/A bullets.

# Feature Specification: Already-Merged Spec Fixture

**Feature Branch**: `004-already-merged`

**Created**: 2026-05-20

**Status**: Draft

## Overview

A fully-traversed spec — `spec.md`, `plan.md`, `tasks.md` (every task
ticked), and an `analyze-2026-05-28.md` artifact. Used by parser
tests to verify `lifecycle_phase` reaches `analyzing` from artifacts
alone (and `merged` when the caller supplies a PR-merged hint per
FR-013/FR-014).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Retroactive sync of a finished spec (Priority: P1)

Operator adopts the bridge against a repo that already contains a
spec which has progressed through analyze and merge.

**Acceptance Scenarios**:

1. **Given** all artifacts up to `analyze-*.md` exist and every task
   is ticked, **When** the parser infers phase without a PR hint,
   **Then** the result is `analyzing`.
2. **Given** the caller passes the PR-merged hint, **When** the
   parser infers phase, **Then** the result is `merged`.

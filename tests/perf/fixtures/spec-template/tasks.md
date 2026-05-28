# Tasks: Perf Fixture Spec __NNN__

**Branch**: `__NNN__-perf-fixture`

## Phase 1: Setup

Bootstrap scaffolding for the perf fixture.

- [ ] T__NNN__-001 Create skeleton directories
- [ ] T__NNN__-002 [P] Configure tooling
- [ ] T__NNN__-003 [P] Drop placeholder README
- [ ] T__NNN__-004 Wire CI smoke job
- [ ] T__NNN__-005 [P] Pin dependency manifest
- [ ] T__NNN__-006 Verify lint baseline

## Phase 2: Foundational

Phase 2 depends on Phase 1.

- [ ] T__NNN__-007 Implement core module A
- [ ] T__NNN__-008 [P] Implement core module B (depends on T__NNN__-001)
- [ ] T__NNN__-009 Implement core module C
- [ ] T__NNN__-010 [P] Wire shared error type
- [ ] T__NNN__-011 Add structured logger
- [ ] T__NNN__-012 [P] Add config loader
- [ ] T__NNN__-013 Wire config validation
- [ ] T__NNN__-014 [P] Cover module A with unit tests

## Phase 3: User Story 1 (P1)

Phase 3 depends on Phase 2.

- [ ] T__NNN__-015 Implement command entry point
- [ ] T__NNN__-016 [P] Wire dispatch table
- [ ] T__NNN__-017 Add operator-facing usage
- [ ] T__NNN__-018 [P] Add exit-code contract
- [ ] T__NNN__-019 Cover command path with integration test
- [ ] T__NNN__-020 [P] Add dry-run mode toggle
- [ ] T__NNN__-021 Add summary emitter
- [ ] T__NNN__-022 [P] Document operator UX in README

## Phase 4: Polish

Phase 4 depends on Phase 3.

- [ ] T__NNN__-023 Add CHANGELOG entry
- [ ] T__NNN__-024 [P] Run final shellcheck pass
- [ ] T__NNN__-025 Run final markdownlint pass
- [ ] T__NNN__-026 [P] Tag release candidate
- [ ] T__NNN__-027 Backfill missing doc cross-links
- [ ] T__NNN__-028 [P] Confirm idempotent re-run
- [ ] T__NNN__-029 Add perf regression note
- [ ] T__NNN__-030 [P] Capture handoff notes

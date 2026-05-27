# Specification Quality Checklist: spec-kit ↔ Linear Bridge

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-05-27
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- All [NEEDS CLARIFICATION] markers resolved in conversation on
  2026-05-27:
  - **Q1 (FR-005 task-mirror granularity)** → resolved by adopting
    the locked-in data-model mapping: Project=repo, Issue=spec,
    sub-issue=task-phase, checklist=tasks.
  - **Q2 (FR-008 annotation surface)** → resolved by the same mapping
    (Issue comments natively supported by the official Linear MCP;
    no GraphQL fallback needed for this case).
  - **Q3 (FR-015 ratification marker)** → resolved by checking the
    canonical spec-kit `/speckit-clarify` flow: it has no ratification
    concept, so the bridge drops the "Ratified" phase entirely and
    mirrors each `### Session YYYY-MM-DD` block in `spec.md` as a
    comment on the spec Issue.
- BRIEF.md's remaining open questions (seed-workspace scope,
  phase-detection algorithm, task-dependency parsing format,
  dogfood ordering) are intentionally deferred to `/speckit-clarify`.
- Clarify round 1 complete (2026-05-27): five questions asked and
  answered, all integrated. Coverage delivered for the Domain &
  Data Model, Integration & External Dependencies, Terminology &
  Consistency, and Setup & Configuration taxonomy categories. Spec
  is ready for `/speckit-plan`.

## Validation Iteration Log

- **Iteration 1 (2026-05-27)**: First-draft spec. Three NEEDS
  CLARIFICATION markers present (FR-005, FR-008, FR-015). All other
  checklist items passing.
- **Iteration 2 (2026-05-27)**: Data-model locked in
  (Project=repo / Issue=spec / sub-issue=task-phase / checklist=tasks).
  FR-005 and FR-008 markers resolved.
- **Iteration 3 (2026-05-27)**: FR-015 resolved by dropping the
  "Ratified" phase after confirming canonical `/speckit-clarify`
  has no ratification step. Checklist clean.
- **Iteration 4 (2026-05-27)**: Q1 and Q2 integrated (Project
  binding at install time; spec Issue identity via
  `speckit-spec:NNN` workspace label). Added FR-025/FR-026
  capturing the write-authority rule (only the worktree on a
  spec's feature branch may write to Linear), with edge cases,
  acceptance scenario in User Story 3, and SC-009. Checklist
  remains clean (zero NEEDS CLARIFICATION).
- **Iteration 5 (2026-05-27)**: Q3 integrated. Renamed task-grouping
  terminology from BRIEF's "wave / W0 / W1" to canonical spec-kit
  "task phase / Phase 1 / Phase 2" throughout spec.md. The
  lifecycle-phase concept is unchanged (Specifying / Clarifying /
  Planning / etc. still labeled `phase:*`); only the task-grouping
  concept was renamed. Checklist remains clean.
- **Iteration 6 (2026-05-27)**: Q4 (Team config) and Q5 (D+E
  merge-detection architecture) integrated. Per-repo config now
  holds both `team_id` and `project_id`. New FR-027..FR-030 add
  the GitHub Action webhook layer (Layer E) alongside the existing
  reconciliation layer (Layer D); both layers independently
  idempotent. Three edge cases, two success criteria (SC-010,
  SC-011), and two Assumptions appended. Spec.md now contains all
  five clarify-round answers and remains clean (zero NEEDS
  CLARIFICATION).
- **Iteration 7 (2026-05-27)**: Post-clarify amendments integrated.
  Added FR-018b (install dependency verification, single load-bearing
  rule with concrete list deferred to `/speckit-plan`); FR-031
  (auto-register `after_*` hooks at install + on-demand command
  escape hatches); FR-032 (UUID-based Linear workflow state lookup
  with `workflow_state_uuids` map in `config.yml`). Light edits to
  FR-002, FR-021, FR-028 to thread the UUID-map convention through
  related contracts. Checklist remains clean (zero NEEDS
  CLARIFICATION). Spec is ready for `/speckit-plan`.
- **Iteration 8 (2026-05-28)**: Added FR-033 (local git hooks —
  `post-checkout`, `post-commit`, `post-merge` — auto-installed at
  `specify extension add linear` time, invoking the same reconciler
  as spec-kit's `after_*` hooks). Closes the "I switched worktree
  without running a spec-kit command" gap. Crons, daemons, and
  filesystem watchers explicitly out of scope per operator decision.
  Q&amp;A bullet appended to the Clarifications session. Checklist
  remains clean.

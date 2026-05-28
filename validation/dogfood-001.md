# Dogfood report: spec-kit-linear -> OSH-INFRA (T077)

**Run**: _filled by scripts/dogfood.sh on each invocation_
**Operator**: _filled by script via Linear viewer query_
**Workspace**: OSH-INFRA
**Team UUID**: 6ab43461-6d22-4f02-bb1e-0be9859c7997
**Repo**: ashbrener/spec-kit-linear
**Branch**: _filled by script_
**Bridge commit**: _filled by script_
**Flags**: _filled by script (dry-run / skip-install / skip-seed)_

## Overview

This report captures the first end-to-end dogfood of the bridge:
installing it into its own repo, seeding the OSH-INFRA workspace
with the 9 lifecycle workflow states + labels, and reconciling
spec 001 to the resulting Linear Project. Findings are appended to
each section by `scripts/dogfood.sh` on each invocation.

This file is **regenerated** every time `scripts/dogfood.sh` runs —
the template below is what the file looks like on disk before the
first run. Operator-authored notes under "Rough edges & follow-ups"
will be preserved between runs only if you manually copy them out
before re-running; the script does NOT merge old content.

## Pre-flight checks

<!-- Filled by script: bash version, curl, jq, git, gh status, .env LINEAR_API_KEY presence. Per FR-018b every dependency the dogfood touches MUST be verified before any mutation fires; this section is the verification's audit trail. -->

## Step 1 — Install ceremony

<!-- Filled by script: src/install.sh stdout/stderr + timing + outcome.

Command (default):
  bash src/install.sh --dev --auto-create --team <UUID> --non-interactive --with-action

Acceptance criteria mirrored from spec.md User Story 4 / Acceptance Scenario 1:
  - .specify/extensions.yml gains the bridge's six after_* hooks (optional: false per FR-031).
  - .specify/extensions/linear/linear-config.yml is written with the team + project UUIDs (FR-032).
  - .git/hooks/post-{checkout,commit,merge} are installed (FR-033).
  - .github/workflows/spec-kit-linear-sync.yml is dropped from templates/github-action.yml (FR-027, FR-029).
  - .mcp.json contains the Linear MCP entry (FR-018b dependency report). -->

## Step 2 — Workspace seed

<!-- Filled by script: src/seed.sh stdout/stderr + timing + outcome + captured workflow_state UUIDs.

Command (default):
  bash src/seed.sh --team <UUID>

Acceptance criteria mirrored from spec.md User Story 4 / Acceptance Scenario 2 + FR-021:
  - The 9 spec-kit lifecycle workflow states exist on the team (Specifying, Clarifying, Planning, Tasking, Red-team, Implementing, Analyzing, Ready-to-merge, Merged).
  - The 3 parent label groups exist (phase, speckit-spec, task-phase) plus the 9 phase:* children.
  - workflow_state_uuids map is written back to linear-config.yml.
  - Re-running the seed against an already-seeded workspace is a no-op (FR-021 idempotency). -->

## Step 3 — Reconcile spec 001 -> Linear

<!-- Filled by script: src/reconcile.sh stdout/stderr + timing + outcome.

Command (default):
  bash src/reconcile.sh --spec 001

Acceptance criteria mirrored from spec.md User Story 5 (this spec IS the bridge — running spec 001 against a fresh workspace is the retroactive-sync test by definition):
  - A Project exists under the OSH team named "spec-kit-linear".
  - One Issue exists for spec 001 with label speckit-spec:001 and the lifecycle phase that matches the filesystem state (probably "Implementing" — plan.md + tasks.md present, not yet merged).
  - Sub-issues exist for each task phase (Phase 1 ... Phase 8 per tasks.md).
  - Each sub-issue's description contains a tasks.md-mirroring checklist headed by the one-way-mirror banner (FR-006).
  - Clarify sessions in spec.md are mirrored as Issue comments (FR-015).
  - Re-running the reconcile is a no-op (Principle II — zero churn). -->

## Step 4 — Linear verification

<!-- Filled by script: GraphQL queries confirm
  - Project "spec-kit-linear" exists on team <UUID>
  - Issue with label speckit-spec:001 exists with the expected identifier (OSH-1 if first), title, workflow state, labels
  Each row of the verification table is PASS/FAIL with the underlying datum (URL, identifier, state name + type). -->

## Summary

<!-- Filled by script: overall pass/fail glyph, total wall-clock time, per-step exit codes + durations, the operator-facing Linear URL for the spec Issue, and an aggregated Warnings list (if any warnings were surfaced by the dogfood driver itself — distinct from sub-script stderr which is captured in the per-step transcripts). -->

## Rough edges & follow-ups

<!-- Operator-authored after run: what worked, what surprised, what needs polishing in v0.1.x.

Suggested prompts the operator should answer post-run:
  - Did the install ceremony's --auto-create placeholder Project UUID (00000000-0000-0000-0000-000000000000) actually cause a downstream failure, or did the bridge gracefully patch it on first reconcile?
  - Were the workflow_state UUIDs captured by the seed correctly written back to linear-config.yml? Inspect the file.
  - Did spec 001's reconcile correctly infer phase "Implementing" from filesystem state (plan.md + tasks.md exist, not yet merged)?
  - How does the Linear UI render the Phase 1 ... Phase 8 sub-issue tree? Any rendering rough edges?
  - Cold reconcile wall-clock vs plan.md's 30s budget — within target?
  - Any FR-018b dependency rows that surfaced WARN rather than PASS — what's the remediation cost?

Anything captured here is the agenda for the v0.1.x polish pass.
Per T077: this section is the operator's running notebook for the
dogfood; the rest of the report is regenerated mechanically. -->

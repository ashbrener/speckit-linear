# Dogfood report: spec-kit-linear -> OSH-INFRA (T077)

**Run**: 2026-05-28T08:14:40Z
**Operator**: ash@starlogik.com <ash@starlogik.com>
**Workspace**: OSH-INFRA
**Team UUID**: 6ab43461-6d22-4f02-bb1e-0be9859c7997
**Repo**: ashbrener/spec-kit-linear
**Branch**: 001-spec-kit-linear-bridge
**Bridge commit**: 429ec7d
**Flags**: dry-run=0 skip-install=1 skip-seed=0

## Overview

This report captures the first end-to-end dogfood of the bridge:
installing it into its own repo, seeding the OSH-INFRA workspace
with the 9 lifecycle workflow states + labels, and reconciling
spec 001 to the resulting Linear Project. Findings are appended to
each section by `scripts/dogfood.sh` on each invocation.

## Pre-flight checks

| Check | Status | Detail |
|---|---|---|
| bash 4+ | PASS | 5.3.9(1)-release |
| curl | PASS | /usr/bin/curl |
| jq | PASS | /usr/bin/jq |
| git | PASS | /usr/bin/git |
| gh | PASS | /opt/homebrew/bin/gh |
| .env file | PASS | /Users/ashbrener/Code/AI/speckit-linear/.env |
| LINEAR_API_KEY | PASS | length=48 |

Pre-flight green. Proceeding.

## Step 1 — Install ceremony

_Skipped via --skip-install._

## Step 2 — Workspace seed

Command: `bash src/seed.sh --team 6ab43461-6d22-4f02-bb1e-0be9859c7997`

```text
spec-kit-linear: seed team UUID: 6ab43461-6d22-4f02-bb1e-0be9859c7997
spec-kit-linear: seed created workflow state 'Specifying' → d9e14f34-c445-4028-a772-c31d6579430a
spec-kit-linear: seed created workflow state 'Clarifying' → dd879129-cd15-4156-bfd7-e7c8f47095be
spec-kit-linear: seed created workflow state 'Planning' → 8f02e8d9-1b60-460f-b346-3d14552c18e3
spec-kit-linear: seed created workflow state 'Tasking' → e5ea275e-1f4d-4f53-b4fb-b80fd8500589
spec-kit-linear: seed created workflow state 'Red-team' → 278076df-3d30-49c1-bc50-2f3229020f45
spec-kit-linear: seed created workflow state 'Implementing' → 9c417bfc-f2ed-42cb-a931-2d3260f45ee5
spec-kit-linear: seed created workflow state 'Analyzing' → eb42ff4f-04f8-49c0-88c4-578cc2705a49
spec-kit-linear: seed created workflow state 'Ready-to-merge' → 1e1de68f-084b-41e4-a7f6-e2bf44aba0f3
spec-kit-linear: seed created workflow state 'Merged' → 1af17d82-7b5c-4331-a90e-48c87293184d
spec-kit-linear: seed default state 'todo' → 86fb7cc1-d122-456a-aa58-afb24ce1d5a0
spec-kit-linear: seed default state 'in_progress' → 3fcfc383-2316-402b-bc66-a2502cffe875
spec-kit-linear: seed default state 'done' → 0cb3a3b4-0a07-437c-9a36-467cf876a4d6
spec-kit-linear: seed created label 'phase:specifying' → a0482c69-d80c-4caa-954f-18c7fa8cab5d
spec-kit-linear: seed created label 'phase:clarifying' → de473ec7-dc84-4141-8a1b-cae470334344
spec-kit-linear: seed created label 'phase:planning' → 3195ada9-b877-4af5-aa54-551b36286a02
spec-kit-linear: seed created label 'phase:tasking' → c41bda62-ec4a-4542-83db-2b7b01457580
spec-kit-linear: seed created label 'phase:red_team' → 72c70d60-eb2d-47d1-a622-6a4806a0d17f
spec-kit-linear: seed created label 'phase:implementing' → 1c240d02-9bee-4291-8bb6-1bc5c450ba72
spec-kit-linear: seed created label 'phase:analyzing' → 37c2be38-f724-4842-93ff-c399cc0a0b8b
spec-kit-linear: seed created label 'phase:ready_to_merge' → e2ca8745-0ca8-4bdd-a2fd-19f00d244173
spec-kit-linear: seed created label 'phase:merged' → 54eed3d8-e6ea-4b08-95d1-67138db6332d
spec-kit-linear: seed created label 'task-phase:1' → adce0cea-8ed6-4222-90cb-00495d2c0bbe
spec-kit-linear: seed created label 'task-phase:2' → 3494fb88-5d5c-4229-bbb4-3998b2c73961
spec-kit-linear: seed created label 'task-phase:3' → 3ea03549-6070-4fb9-8190-5fa4d669b10d
spec-kit-linear: seed created label 'task-phase:4' → 5a5b2042-c150-44cf-bac1-a3576de24e51
spec-kit-linear: seed created label 'task-phase:5' → f5c8e6c5-453b-4d77-9898-a1cc5366800d
spec-kit-linear: seed created label 'task-phase:6' → ba363ec8-c39c-4ec6-a5c7-f41d6a913c04
spec-kit-linear: seed created label 'task-phase:7' → 68913323-19da-48bc-b75e-82e91964f155
spec-kit-linear: seed created label 'task-phase:8' → bc48a945-940f-4a92-b796-07dc68e31d77
spec-kit-linear: seed created label 'task-phase:9' → cce3677a-3cd1-4c78-a8b5-ac61f5e5d60a
spec-kit-linear: seed wrote .specify/extensions/linear/linear-config.yml
===== speckit.linear summary =====
speckit.linear seed
Created: 0   Updated: 0   Archived: 0
Skipped: 0   Warned: 0     Errors: 0
==================================
```

**Outcome**: PASS (exit 0) — duration 27s

## Step 3 — Reconcile spec 001 -> Linear

Command: `bash src/reconcile.sh --spec 001`

```text
spec-kit-linear: config loaded from .specify/extensions/linear/linear-config.yml
spec-kit-linear: spec 001: lifecycle=implementing branch=001-spec-kit-linear-bridge
spec-kit-linear: spec 001: reconcile complete
===== speckit.linear summary =====
speckit.linear reconcile — spec 001
Created: 2   Updated: 0   Archived: 0
Skipped: 0   Warned: 0     Errors: 0
==================================
```

**Outcome**: PASS (exit 0) — duration 20s

## Step 4 — Linear verification

| Check | Status | Detail |
|---|---|---|
| Project exists | FAIL | transport failure |


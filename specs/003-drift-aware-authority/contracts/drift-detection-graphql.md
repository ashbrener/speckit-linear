# Contract: Drift-Detection Linear Read Surface (GraphQL)

**Feature**: `003-drift-aware-authority` | **Phase**: 1 | **Companions**: [plan.md](../plan.md) · [research.md](../research.md) · [contracts/recency-comparison.md](./recency-comparison.md)

Defines the Linear read surface drift detection needs. **Headline: spec 003 adds NO new GraphQL operation.** The two fields drift requires — the spec Issue's `updatedAt` and its lifecycle state — are already fetched by the v0.1.0 reconcile path. This contract documents that the existing surface is sufficient, names the exact fields, and confirms no new auth or query is introduced (Principle VI unchanged).

## 1. No new operations

| Requirement | Existing query | Status |
|---|---|---|
| spec Issue `updatedAt` (recency, FR-052b) | `src/reconcile.sh:1401` and `:1431` already select `nodes { id updatedAt }` on the issue-lookup queries | **already available** |
| spec Issue lifecycle state (phase ordering, FR-052a) | workflow `state` + `phase:*` label, already read during reconcile to compute idempotent updates | **already available** |

Spec 003 only *reads additional fields off the already-fetched issue object* (or reuses fields already fetched). No new `query`/`mutation`, no new round trip (plan Performance Goals — zero additional network calls).

## 2. Fields consumed

The spec Issue object, as already retrieved through the official Linear MCP / `graphql::query` path, MUST expose:

```graphql
# Conceptual shape — these fields are already part of the reconcile issue fetch.
issue {
  id
  updatedAt          # ISO-8601 — recency comparator (recency-comparison.md §3)
  state {
    id
    name
    type             # workflow-state category
  }
  labels {
    nodes { name }   # to read the phase:* label → lifecycle ordinal
  }
}
```

| Field | Used for | Maps to data-model entity |
|---|---|---|
| `updatedAt` | recency drift signal | `LinearRecordedState.updated_at_epoch` |
| `state` / `labels[phase:*]` | phase-ordering drift signal | `LinearRecordedState.phase_ordinal` / `phase_token` |

## 3. Phase derivation from Linear

The Linear-recorded lifecycle phase ordinal (data-model §2 ladder) is derived from the already-read state + label:

- A `phase:<token>` label present → that token's ordinal (0–5).
- No `phase:*` label AND workflow state in a merged/done category → `merged` (ordinal 6, FR-013).
- Map workflow-state category to the closest phase token when a `phase:*` label is absent but the state is a started category (defensive; the label is the primary source).

This derivation reuses the same state/label reading the reconcile already performs for idempotent updates — no new field selection beyond what is listed in §2.

## 4. Auth surface (unchanged — Principle VI)

| Path | Auth | Change in spec 003? |
|---|---|---|
| interactive reconcile drift read | official Linear MCP / OAuth (Principle VI Rule 1) | none |
| recency disk key | local `git log` — no auth | none |
| Layer E (webhook Action) | exempt from drift (PR head ref implies authority) | none |

Spec 003 introduces NO new API-key surface and NO new MCP capability requirement. The `updatedAt` field is standard on the Linear `Issue` type and available through both the official MCP and direct GraphQL.

## 5. Failure handling (Principle VIII)

| Condition | Behavior |
|---|---|
| `updatedAt` missing/unparseable from the issue response | recency signal `unavailable`; fall back to phase-ordering alone (do not fabricate drift) |
| Linear lifecycle state unreadable | surface the existing reconcile read-error warning (FR-024 path); skip the phase signal, use recency alone |
| spec Issue does not yet exist in Linear (first reconcile, US2) | no Linear-side state to be ahead of → `fired = false`; the spec is created from disk normally (SC-015) |

In every failure mode the bridge degrades to the available signal and surfaces the gap rather than blocking or guessing (Principle VIII).

# Implementation Plan: Perf Fixture Spec __NNN__

**Feature**: `__NNN__-perf-fixture`
**Phase**: 1 (design)

## Technical Context

Synthetic plan. Used by the perf harness only; the reconciler reads
this file to confirm the spec is past `/speckit-plan` and into
`tasking`. No real implementation lives behind this file.

## Constitution Check

Not applicable — fixture only.

## Project Structure

Out of scope for the fixture — see real specs for canonical layout.

## Performance Goals

- Reconcile parse + mutation-plan time for this spec should be a
  small constant (target ≪ 1s per spec at dry-run, no transport).

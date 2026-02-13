# Parent Trace Metadata Lifecycle

**Date:** 2026-02-13
**Status:** Brainstorm

## What We're Building

A trace lifecycle policy where the parent trace is created with stable, high-value metadata immediately, instead of appearing as an empty vessel while child spans execute.

At parent trace creation time, we should always set:
- trace name
- input payload (sanitized)
- conversation identifier (`conversation_id` when available)

Child spans then run normally, and parent output/status are populated later when execution completes (success or error). This keeps early trace visibility useful while preserving accurate final outcome details.

## Why This Approach

### Recommended Approach (Chosen)
**Eager parent metadata + deferred output finalization**

This matches your goals: no artificial timebox, immediate observability value, and eventual completion once children/agent loop finish.

**Pros**
- Prevents first-seen parent traces from being unnamed/empty
- Guarantees correlation attributes (`conversation_id`) are present from the start
- Keeps output semantics correct (only finalize when outcome is known)
- Avoids strict timing SLO complexity

**Cons**
- Parent can still be “in progress” for a period
- Requires clear rules for which fields are immutable vs updatable

### Alternative A
**Keep parent minimal until end, improve flush/retry only**

Lower change risk but does not satisfy immediate visibility requirements.

### Alternative B
**Two-phase parent object with explicit “skeleton -> finalized” state machine**

Very explicit semantics, but heavier design and likely unnecessary now (YAGNI).

## Key Decisions

- **Immediate parent enrichment:** On parent creation, set trace name, input, and `conversation_id` if available.
- **Deferred final fields:** Output and terminal status are written only when the parent operation ends.
- **No hard completion timeout:** Completion is eventual; correctness is preferred over arbitrary time windows.
- **Failure parity:** Max-iterations and exceptions must still preserve enriched parent metadata and finalize with error output/status.
- **Field ownership rules:** Define which fields are write-once (identity/correlation) vs write-late (result/status).

## Open Questions

- What is the canonical source for `conversation_id` when multiple candidates exist in context?
- If parent input is large, do we cap/truncate for telemetry consistency?
- On retries/re-entrancy, should parent trace be reused or forked?
- Do we need explicit telemetry events for “parent initialized” and “parent finalized” for debugging race conditions?

## Next Steps

→ `/prompts:workflows-plan` to define implementation steps, lifecycle invariants, and test coverage for success/failure/max-iterations paths.

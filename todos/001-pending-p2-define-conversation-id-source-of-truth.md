---
status: pending
priority: p2
issue_id: "001"
tags: [code-review, architecture, observability, quality]
dependencies: []
---

# Define canonical conversation_id source for parent traces

## Problem Statement

The brainstorm proposes writing `conversation_id` at parent trace creation time, but does not define a deterministic source-of-truth when multiple candidates exist.

Without a canonical precedence rule, traces can be tagged inconsistently across code paths, reducing debuggability and causing unreliable filtering/grouping.

## Findings

- `docs/brainstorms/2026-02-13-parent-trace-metadata-lifecycle-brainstorm.md:13` requires `conversation_id` "when available".
- `docs/brainstorms/2026-02-13-parent-trace-metadata-lifecycle-brainstorm.md:54` leaves canonical source selection as an open question.
- The same document defines immediate enrichment as a key decision, so unresolved sourcing introduces implementation ambiguity.

## Proposed Solutions

### Option 1: Explicit precedence contract in brainstorm/plan

**Approach:** Define ordered precedence (for example: explicit call arg > request context > module metadata > absent) and document it before implementation.

**Pros:**
- Deterministic behavior across modules
- Easier test design and incident triage

**Cons:**
- Requires alignment across call sites
- May surface existing inconsistencies

**Effort:** Small

**Risk:** Low

---

### Option 2: Require explicit conversation_id at root entrypoint

**Approach:** Treat `conversation_id` as required for root traces and fail/flag when missing.

**Pros:**
- Strong data quality guarantee
- Simple interpretation for operators

**Cons:**
- Potentially breaking for current callers
- Higher adoption friction

**Effort:** Medium

**Risk:** Medium

---

### Option 3: Best-effort source with provenance attribute

**Approach:** Keep best-effort sourcing, but emit `conversation_id.source` to indicate where it came from.

**Pros:**
- Backward-compatible
- Better observability of data quality

**Cons:**
- Still allows inconsistent IDs
- Adds analysis complexity

**Effort:** Small

**Risk:** Medium

## Recommended Action


## Technical Details

**Affected files:**
- `docs/brainstorms/2026-02-13-parent-trace-metadata-lifecycle-brainstorm.md`
- Likely follow-up in `docs/plans/*` and observability instrumentation files

**Related components:**
- `DSPy::Context`
- `DSPy::Module#instrument_forward_call`
- Langfuse trace attributes mapping

**Database changes (if any):**
- No

## Resources

- Brainstorm target: `docs/brainstorms/2026-02-13-parent-trace-metadata-lifecycle-brainstorm.md`

## Acceptance Criteria

- [ ] Canonical `conversation_id` precedence is documented in planning artifact
- [ ] Conflict behavior (multiple candidates) is explicitly defined
- [ ] Missing value behavior is explicitly defined
- [ ] Tests are planned for each precedence branch

## Work Log

### 2026-02-13 - Review finding captured

**By:** Codex

**Actions:**
- Reviewed brainstorm requirements and key decisions
- Identified ambiguity between mandatory early enrichment and undefined ID source
- Captured options with effort/risk tradeoffs

**Learnings:**
- Deterministic correlation IDs are critical for reliable trace analysis

## Notes

- Keep protected artifacts policy in mind; do not propose deleting pipeline docs.

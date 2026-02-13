---
title: "fix: Parent trace metadata lifecycle reliability"
type: "fix"
date: "2026-02-13"
---

# fix: Parent trace metadata lifecycle reliability

## Problem

Parent traces can appear incomplete and there are unresolved decisions around:
- deterministic `conversation_id` source
- failure/interruption finalization behavior
- how we verify the change worked

## Plan

1. **Lock deterministic `conversation_id` precedence**
- Define one ordered source-of-truth policy.
- Document missing-value behavior.

2. **Enforce parent lifecycle contract**
- On parent creation, always set:
  - trace name
  - sanitized input
  - `conversation_id` when resolvable
- On completion/error, set terminal status + output/error payload.

3. **Cover failure paths explicitly**
- Ensure max-iterations and exception paths finalize parent trace fields consistently.

4. **Add minimal verification checks**
- Confirm improved parent metadata completeness.
- Confirm reduced stale in-progress parent traces.

## Acceptance Criteria

- [ ] `conversation_id` precedence is explicitly documented and deterministic.
- [ ] Parent trace has name/input/(resolved) `conversation_id` at initialization.
- [ ] Parent trace finalizes status/output for success and error paths.
- [ ] Max-iterations path includes error finalization parity.
- [ ] Tests cover success, exception, and max-iterations lifecycle behavior.

## Scope

**In scope:**
- Root trace lifecycle behavior in module/context instrumentation
- ReAct failure-path parity for terminal trace fields
- Relevant observability docs updates

**Out of scope:**
- New reconciler/background repair jobs
- Large observability platform changes

## References

- Brainstorm: `docs/brainstorms/2026-02-13-parent-trace-metadata-lifecycle-brainstorm.md`
- Review findings:
  - `todos/001-pending-p2-define-conversation-id-source-of-truth.md`
  - `todos/002-pending-p2-define-parent-finalization-reliability.md`
  - `todos/003-pending-p3-add-observability-success-metrics-for-trace-policy.md`
- Key code touchpoints:
  - `lib/dspy/module.rb:261`
  - `lib/dspy/module.rb:378`
  - `lib/dspy/context.rb:50`
  - `lib/dspy/re_act.rb:533`

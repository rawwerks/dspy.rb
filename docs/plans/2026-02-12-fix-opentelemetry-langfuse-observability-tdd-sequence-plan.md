---
title: "fix: Resolve OpenTelemetry and Langfuse observability issues with one-commit TDD sequencing"
type: fix
date: 2026-02-12
issues:
  - "#200"
  - "#216"
  - "#222"
  - "#223"
  - "#224"
  - "#205"
---

# fix: Resolve OpenTelemetry and Langfuse observability issues with one-commit TDD sequencing

## Overview

This plan delivers six related fixes as a coordinated sequence while preserving strict isolation:

1. `#200` Telemetry environment variables and tuning guidance are not documented.
2. `#216` Gemini 3 Flash missing from structured-output supported model allowlist.
3. `#222` OpenTelemetry span attribute type failures for ReAct event payloads containing complex arrays/hashes.
4. `#223` ReAct tool-call spans missing Langfuse `input/output` previews.
5. `#224` Ambiguous `DSPy::Predict.forward` span names lacking signature identity.
6. `#205` `DSPy::Context.with_span` creating isolated root traces in worker threads instead of nested spans.

Execution constraint: **one commit per issue**, each built via TDD (failing tests first, implementation second, full suite verification before commit).

## Problem Statement

Current observability behavior creates debugging friction and telemetry reliability risks:

- Telemetry tuning and disablement env vars are implemented but undocumented for users (`#200`).
- Gemini 3 structured outputs are silently skipped because `gemini-3-flash-preview` is missing from the allowlist.
- Event spans can emit OTEL-invalid attribute value types (e.g., `Array<Hash>`), producing runtime errors and dropped attributes.
- `react.tool_call` spans expose `tool.input` metadata but do not populate Langfuse preview `input/output` fields consistently.
- ReAct internals emit many identical `DSPy::Predict.forward` spans, making trace timelines hard to interpret.
- Cross-thread context propagation can break parent/child nesting when using standard `OpenTelemetry::Context.with_current` patterns.

## Research Consolidation

### Repository Conventions (Local)

- TDD is mandatory (`CLAUDE.md:7`, `CLAUDE.md:159`).
- Integration + unit test separation is required (`CLAUDE.md:170`, `CLAUDE.md:171`).
- Observability architecture and expected Langfuse behavior are documented in `docs/src/production/observability.md:21` and `docs/src/production/observability.md:146`.
- Existing implementation points:
  - Async telemetry tuning env vars and behavior: `lib/dspy/o11y/async_span_processor.rb` and `lib/dspy/o11y/langfuse.rb`
  - Gemini structured-output allowlist: `lib/dspy/gemini/lm/schema_converter.rb`
  - Event span flattening: `lib/dspy.rb:132`
  - Event flatten leaf assignment (unsanitized): `lib/dspy.rb:162`
  - ReAct tool-call instrumentation: `lib/dspy/re_act.rb:619`
  - Module forward instrumentation baseline: `lib/dspy/module.rb:261`
  - Context sanitization primitives: `lib/dspy/context.rb:249`
  - OTEL span start boundary: `lib/dspy/o11y/observability.rb:53`

### Institutional Learnings

- `docs/solutions/` is not present in this repository, so no frontmatter-indexed solution corpus is available.
- Closest institutional guidance source is `adr/LEARNINGS.md`, which reinforces:
  - Centralize coercion/normalization logic to avoid drift across call sites (`adr/LEARNINGS.md:159`).
  - Preserve deterministic behavior in mixed runtime/test environments.

### External Docs / Best Practices (2026-verified)

- OpenTelemetry Ruby context APIs support explicit attach/detach and `OpenTelemetry::Context.with_current` for propagated parent context.
- OpenTelemetry specification restricts attributes to primitives or homogeneous primitive arrays; complex objects should be encoded (typically JSON string).
- Gemini model docs confirm `gemini-3-flash-preview` support path for structured-output usage via schema-enabled generation config.

## Scope

### In Scope

- Fixes for issues `#200`, `#216`, `#222`, `#223`, `#224`, `#205`.
- Tests for behavior guarantees and regression prevention.
- Minimal docs updates where telemetry behavior contract changes are user-visible.
- One commit per issue, linked in commit message.

### Out of Scope

- Broad redesign of full observability architecture.
- Additional telemetry feature expansion not required by these issues.
- New adapters/providers unrelated to OpenTelemetry/Langfuse behavior.

## Stakeholders

- DSPy.rb maintainers debugging agent traces.
- Developers operating ReAct/agent loops in production.
- Observability consumers (Langfuse, OTEL backends) expecting valid, nested, and interpretable spans.

## Technical Approach

### Architecture Decisions

1. **Single sanitization contract for event span attributes**:
   - Ensure all event-path attributes entering `Observability.start_span` are OTEL-safe.
   - Complex values (hash/struct/mixed arrays/array of hashes) are serialized to bounded JSON strings.

2. **Tool-call preview parity**:
   - `react.tool_call` spans must set `langfuse.observation.input` and `langfuse.observation.output` alongside existing metadata.

3. **Predict span disambiguation with backward compatibility**:
   - Preserve `dspy.module` while enriching with signature identity attributes and operation naming hints.

4. **Context propagation compatibility for thread pools**:
   - Make `DSPy::Context.with_span` compatible with OpenTelemetry context restoration patterns, so worker spans nest under parent traces when context is propagated.

5. **Observability configuration documentation parity**:
   - Document implemented telemetry env vars, defaults, tradeoffs, and scenario presets in production docs.

## SpecFlow Analysis

### User Flow Overview

1. Developer runs ReAct flow with tools and inspects Langfuse trace.
2. Developer checks each `react.tool_call` span for input/output previews.
3. Developer inspects predictor spans to identify thought vs observation processors.
4. Application executes threaded work (e.g., `Concurrent::Promise`) inside a parent span and expects nested children.

### Flow Permutations Matrix

| Flow | Context | Expected Result | Current Risk |
|---|---|---|---|
| ReAct tool call | Single thread | Tool span shows input/output preview | Preview null |
| ReAct iteration event | Structured observation arrays | Span emitted without OTEL errors | Invalid Array<Hash> attr |
| Predict internals | Multi-predictor agent | Distinguishable spans by signature | Ambiguous identical names |
| Parent/child with thread pool | `with_current(context)` used | Worker span nested in same trace | Isolated root trace |

### Missing Elements & Gaps to Close

- Explicit tests for homogeneous primitive arrays vs complex arrays in event attrs.
- Explicit assertion that tool output preview is populated after tool execution.
- Clear fallback behavior for anonymous/unknown signature classes in operation names.
- Explicit thread context bridge test proving nested spans in worker thread.

### Critical Questions (Resolved Defaults)

1. Should complex event attributes preserve structure?  
Assumption: preserve via JSON string encoding, not attribute dropping.
2. Should operation names change for all modules or only `DSPy::Predict`?  
Assumption: only `DSPy::Predict` gets signature-aware operation naming.
3. Should cross-thread fix rely solely on custom thread-local stacks?  
Assumption: no; align with OpenTelemetry context propagation semantics.

## Implementation Phases (One Commit per Issue)

### Phase 1: `#200` Telemetry Environment Variable Documentation

#### TDD Steps

1. Add failing documentation coverage spec (or extend existing docs spec) that asserts observability docs include telemetry env var names.
2. Update `docs/src/production/observability.md` with a dedicated configuration section:
   - `DSPY_DISABLE_OBSERVABILITY`
   - `DSPY_TELEMETRY_QUEUE_SIZE`
   - `DSPY_TELEMETRY_EXPORT_INTERVAL`
   - `DSPY_TELEMETRY_BATCH_SIZE`
   - `DSPY_TELEMETRY_SHUTDOWN_TIMEOUT`
3. Add scenario-based recommendations (CLI, web app, background jobs, development).
4. Run docs tests/build checks plus full test suite.
5. Commit with `docs: document telemetry env vars and tuning guidance (fix #200)`.

#### Candidate Files

- `docs/src/production/observability.md`
- `spec/documentation/getting_started_examples_spec.rb` (or relevant docs spec)

### Phase 2: `#216` Gemini 3 Structured Output Allowlist

#### TDD Steps

1. Add failing unit/integration test asserting Gemini 3 flash preview model is recognized by `supports_structured_outputs?`.
2. Add failing assertion that schema-enabled requests include `response_json_schema` for Gemini 3.
3. Update allowlist in `lib/dspy/gemini/lm/schema_converter.rb`.
4. Run targeted Gemini tests and full suite.
5. Commit with `fix: add gemini 3 flash preview to structured output models (fix #216)`.

#### Candidate Files

- `lib/dspy/gemini/lm/schema_converter.rb`
- `spec/unit/dspy/lm/adapters/gemini/schema_converter_spec.rb`
- `spec/integration/gemini_structured_outputs_spec.rb` (if needed)

### Phase 3: `#222` Event Attribute Type Safety

#### TDD Steps

1. Add failing unit specs for event flatten/sanitize behavior.
2. Cover inputs:
   - `Array<Hash>`
   - nested hash with arrays
   - mixed arrays
   - values responding to `to_h`
3. Implement sanitizer integration in event span path (`lib/dspy.rb` and/or defensive path in `lib/dspy/o11y/observability.rb`).
4. Run targeted and full test suites.
5. Commit with `fix: sanitize event span attributes for otel compatibility (fix #222)`.

#### Candidate Files

- `lib/dspy.rb`
- `lib/dspy/o11y/observability.rb`
- `spec/unit/dspy/event_span_attributes_spec.rb` (new)

### Phase 4: `#223` ReAct Tool Span Input/Output

#### TDD Steps

1. Add failing integration/unit tests verifying `react.tool_call` sets:
   - `langfuse.observation.input`
   - `langfuse.observation.output`
2. Validate existing `tool.input`, `tool.name`, and iteration attrs remain intact.
3. Implement in `ReAct#execute_tool_with_instrumentation` by serializing input and capturing output.
4. Re-run observability integration tests.
5. Commit with `fix: populate react tool span input output previews (fix #223)`.

#### Candidate Files

- `lib/dspy/re_act.rb`
- `spec/integration/react_observability_spec.rb`
- `spec/unit/dspy/re_act_tool_span_spec.rb` (optional new focused spec)

### Phase 5: `#224` Predict Span Signature Identity

#### TDD Steps

1. Add failing tests for `DSPy::Predict` spans asserting signature attributes and operation naming.
2. Include fallback expectations when signature name is unavailable.
3. Implement conditional enrichment in module instrumentation path.
4. Verify no regression for non-Predict modules.
5. Commit with `fix: disambiguate predict spans with signature identity (fix #224)`.

#### Candidate Files

- `lib/dspy/module.rb`
- `spec/unit/dspy/module_instrumentation_spec.rb` (new)
- `spec/integration/react_observability_spec.rb` (extend)

### Phase 6: `#205` Thread-Propagated Nested Spans

#### TDD Steps

1. Add failing concurrency spec reproducing worker-thread orphan traces with `OpenTelemetry::Context.with_current`.
2. Implement context bridge so parent span context is honored in worker threads.
3. When local DSPy span stack is empty in worker thread, recover parent from restored OpenTelemetry context before creating child span.
4. Verify nested trace/span ids and parent relationships in assertions.
5. Extend integration coverage in `spec/integration/dspy/span_nesting_spec.rb` for thread-pool propagation.
6. Run full suite and stress targeted thread test repeatedly.
7. Commit with `fix: preserve span nesting across thread context propagation (fix #205)`.

#### Candidate Files

- `lib/dspy/context.rb`
- `spec/unit/dspy/context_thread_propagation_spec.rb` (new)

## Acceptance Criteria

### Functional

- [x] `#216`: Gemini 3 flash preview models are treated as structured-output capable.
- [x] `#200`: Observability docs include telemetry env vars, defaults, and scenario tuning guidance.
- [ ] `#222`: No OTEL invalid attribute type errors for ReAct event payloads containing arrays/hashes.
- [ ] `#223`: `react.tool_call` spans include Langfuse preview input/output values.
- [ ] `#224`: `DSPy::Predict` spans are distinguishable by signature identity without inspecting payloads.
- [ ] `#205`: Worker-thread spans nest under parent trace when context is propagated via OpenTelemetry APIs.

### Non-Functional

- [ ] Existing telemetry attributes remain backward-compatible unless explicitly improved.
- [ ] No measurable regressions in hot-path instrumentation overhead.
- [ ] Test suite remains deterministic.

### Quality Gates

- [ ] New failing tests written before each implementation change.
- [ ] `bundle exec rspec` passes after each issue-level commit.
- [ ] Documentation updated if behavior contract changed.

## Commit Plan

1. Commit 1: `docs: document telemetry env vars and tuning guidance (fix #200)`
2. Commit 2: `fix: add gemini 3 flash preview to structured output models (fix #216)`
3. Commit 3: `fix: sanitize event span attributes for otel compatibility (fix #222)`
4. Commit 4: `fix: populate react tool span input output previews (fix #223)`
5. Commit 5: `fix: disambiguate predict spans with signature identity (fix #224)`
6. Commit 6: `fix: preserve span nesting across thread context propagation (fix #205)`

## Risks & Mitigation

- **Risk**: Over-sanitization loses useful structure.  
Mitigation: Serialize complex values to JSON instead of dropping.

- **Risk**: Span operation naming change breaks downstream dashboards.  
Mitigation: Add new attrs and scoped naming changes only for `DSPy::Predict`.

- **Risk**: Thread propagation fix introduces context leaks.  
Mitigation: explicit attach/detach tests and ensure cleanup in `ensure` blocks.

- **Risk**: Integration tests may rely on specific serialization assumptions.  
Mitigation: update assertions to verify stable semantic contract, not incidental formatting.

## MVP Pseudocode

### `spec/unit/dspy/event_span_attributes_spec.rb`

```ruby
# frozen_string_literal: true

RSpec.describe 'DSPy event span attribute sanitization' do
  it 'coerces array of hashes to otel-safe value' do
    # failing assertion first, then implementation
  end
end
```

### `spec/unit/dspy/context_thread_propagation_spec.rb`

```ruby
# frozen_string_literal: true

RSpec.describe DSPy::Context do
  it 'nests worker spans under parent when OpenTelemetry context is restored' do
    # reproduce #205 with thread pool
  end
end
```

## Success Metrics

- All six issues closed with one commit each.
- No OTEL attribute type runtime errors in ReAct telemetry flows.
- Langfuse traces show meaningful tool input/output previews.
- Predict spans become identifiable by role/signature at glance.
- Threaded traces show expected hierarchy in observability backends.

## References

### Related Issues

- #222: https://github.com/vicentereig/dspy.rb/issues/222
- #223: https://github.com/vicentereig/dspy.rb/issues/223
- #224: https://github.com/vicentereig/dspy.rb/issues/224
- #205: https://github.com/vicentereig/dspy.rb/issues/205
- #216: https://github.com/vicentereig/dspy.rb/issues/216
- #200: https://github.com/vicentereig/dspy.rb/issues/200

### Internal References

- `lib/dspy.rb:132`
- `lib/dspy/gemini/lm/schema_converter.rb:1`
- `lib/dspy/o11y/async_span_processor.rb:1`
- `lib/dspy.rb:155`
- `lib/dspy/re_act.rb:619`
- `lib/dspy/re_act.rb:685`
- `lib/dspy/module.rb:261`
- `lib/dspy/context.rb:50`
- `lib/dspy/context.rb:249`
- `lib/dspy/o11y/observability.rb:53`
- `spec/integration/react_observability_spec.rb:80`
- `docs/src/production/observability.md:146`
- `CLAUDE.md:7`
- `CLAUDE.md:159`

### External References

- OpenTelemetry Ruby docs: https://opentelemetry.io/docs/languages/ruby/
- OpenTelemetry spec (attributes): https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/common/README.md
- OpenTelemetry trace API: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md
- Gemini API models: https://ai.google.dev/gemini-api/docs/models

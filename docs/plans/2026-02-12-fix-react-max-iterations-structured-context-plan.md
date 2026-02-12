---
title: "fix: ReAct MaxIterationsError structured context for partial synthesis"
type: fix
date: 2026-02-12
issue: 225
---

# fix: ReAct MaxIterationsError structured context for partial synthesis

## ✨ Overview
`DSPy::ReAct::MaxIterationsError` currently exposes only a message string when the loop exhausts iterations. This plan adds structured exception context so callers can synthesize best-effort answers from gathered evidence without parsing error text.

## 🐛 Problem Statement / Motivation
Issue #225 reports that ReAct exhaustion drops critical state needed for graceful degradation:
- execution `history`
- `tools_used`
- `last_observation`
- iteration counters
- optional `partial_final_answer`

Current behavior raises a plain error string in `lib/dspy/re_act.rb:466`, which blocks robust fallback behavior in production flows.

## ✅ Proposed Solution
Keep backward compatibility by preserving `DSPy::ReAct::MaxIterationsError` as the raised exception type, but enrich it with typed readers:
- `iterations` (Integer)
- `max_iterations` (Integer)
- `tools_used` (Array<String>)
- `history` (Array of ReAct history entries, serialized for caller safety)
- `last_observation` (untyped payload)
- `partial_final_answer` (optional)

Implementation direction:
1. Replace one-line exception class with an initializer + attr_readers.
2. Centralize payload creation in the max-iteration path.
3. Raise with payload in exhaustion paths while preserving message compatibility.
4. Add integration tests that assert both legacy raise semantics and new accessors.
5. Update docs with a rescue/fallback example.

## 🧠 Technical Considerations
- **Compatibility**: existing `rescue DSPy::ReAct::MaxIterationsError` callers must keep working unchanged.
- **Data shape stability**: expose caller-safe data (prefer serialized history entries vs mutable internals).
- **Observability alignment**: keep existing `react.max_iterations` event behavior in `lib/dspy/re_act.rb:709`.
- **Type safety**: maintain Sorbet signatures and avoid broad `T.untyped` expansion beyond required context fields.

## 🔍 SpecFlow Analysis
### User Flow Overview
1. Caller invokes `ReAct#forward`.
2. ReAct loop reaches `max_iterations` without final answer.
3. ReAct raises `MaxIterationsError` containing structured payload.
4. Caller rescues and synthesizes partial answer from error attributes.

### Edge Cases to Cover
- No tools invoked (`tools_used = []`).
- Empty history (iteration stops before actionable step).
- `last_observation` is `nil`.
- `partial_final_answer` unavailable (`nil`) vs available.
- Existing message-regex assertions continue to pass.

### Gaps Closed by This Plan
- Eliminates dependence on message parsing for recovery logic.
- Defines explicit data contract for exhaustion handling.

## 🧪 TDD Implementation Plan (single issue commit)
- [x] `spec/integration/dspy/re_act_spec.rb`: add failing examples for structured `MaxIterationsError` attributes.
- [x] `lib/dspy/re_act.rb`: implement enriched exception class and payload propagation.
- [x] `spec/integration/dspy/re_act_spec.rb`: ensure existing max-iteration message behavior remains green.
- [x] `docs/src/core-concepts/predictors.md`: add rescue example for partial synthesis from structured exception context.
- [x] Run targeted specs first, then full relevant suite.

### Suggested test additions
#### `spec/integration/dspy/re_act_spec.rb`
```ruby
it "exposes structured context on MaxIterationsError" do
  expect { agent.forward(query: "Find the answer") }.to raise_error(DSPy::ReAct::MaxIterationsError) { |error|
    expect(error.iterations).to eq(1)
    expect(error.max_iterations).to eq(1)
    expect(error.tools_used).to eq(["useless_tool"])
    expect(error.history).to be_an(Array)
  }
end
```

## ✅ Acceptance Criteria
- [x] ReAct still raises `DSPy::ReAct::MaxIterationsError` on exhaustion.
- [x] Error exposes readable attributes: `iterations`, `max_iterations`, `tools_used`, `history`, `last_observation`, `partial_final_answer`.
- [x] Existing message-based expectation remains valid.
- [x] New tests verify structured context in exhausted runs.
- [x] Documentation includes a practical rescue/fallback snippet.

## 📏 Success Metrics
- Exhaustion recovery logic can be implemented without regex/message parsing.
- New integration tests pass consistently under CI.
- No regressions in existing ReAct max-iteration behavior.

## ⚠️ Dependencies & Risks
- **Risk**: exposing mutable internal objects.
  - **Mitigation**: return serialized history snapshots.
- **Risk**: incomplete payload on alternate exhaustion path(s).
  - **Mitigation**: audit all `MaxIterationsError` raise sites in `lib/dspy/re_act.rb`.
- **Risk**: docs drift from API.
  - **Mitigation**: update predictor docs in same issue commit.

## 📚 References & Research
### Internal References
- Issue: #225
- Similar observability/error-context work: #224
- ReAct error class definition: `lib/dspy/re_act.rb:50`
- ReAct loop state tracking: `lib/dspy/re_act.rb:330`
- Max-iteration event and hook: `lib/dspy/re_act.rb:709`
- Current plain raise path: `lib/dspy/re_act.rb:466`
- Existing max-iteration integration test: `spec/integration/dspy/re_act_spec.rb:767`
- ReAct docs section: `docs/src/core-concepts/predictors.md:143`
- TDD requirement: `CLAUDE.md:7`

### Institutional Learnings
- `docs/solutions/` directory not present in this repository.
- Fallback institutional guidance used from `adr/LEARNINGS.md`:
  - centralize behavior shared across multiple paths
  - preserve API stability during behavior improvements

## 🚀 Ready-to-Execute Scope
This issue is scoped for one focused implementation commit using TDD:
1. write failing integration tests
2. implement structured exception payload
3. update docs
4. run tests
5. ship

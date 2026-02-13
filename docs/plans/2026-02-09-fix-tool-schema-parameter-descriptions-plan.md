---
title: "fix: Tool schema loses parameter descriptions and uses generic struct names"
type: fix
date: 2026-02-09
issue: "#220"
---

# fix: Tool schema loses parameter descriptions and uses generic struct names

## Overview

`Tools::Base#call_schema_object` and `Tools::Toolset#schema_for_method` unconditionally overwrite parameter descriptions with `"Parameter #{param_name}"` via `.merge()`. This clobbers meaningful descriptions produced by the type system (e.g., Hash mappings, union types, struct descriptions). Additionally, `generate_struct_schema_internal` always uses the Ruby class path as the struct description (`"ClassName struct"`), with no mechanism to set a custom struct-level description.

These bugs degrade schema quality for LLMs doing tool selection and parameter filling — especially with complex struct parameters.

## Problem Statement

**Bug 1: Parameter descriptions overwritten** (`lib/dspy/tools/base.rb:57,70` and `lib/dspy/tools/toolset.rb:75`)

```ruby
schema = DSPy::TypeSystem::SorbetJsonSchema.type_to_json_schema(param_type)
properties[param_name] = schema.merge({ description: "Parameter #{param_name}" })
```

`.merge()` unconditionally replaces any `:description` already in the schema. Types that produce descriptions:
- `T::Hash[K, V]` → `"A mapping where keys are Ks and values are Vs"` (sorbet_json_schema.rb:151)
- `T.any(A, B)` unions → `"Union of multiple types"` (sorbet_json_schema.rb:202,243)
- `T.class_of(X)` → `"Class name (T.class_of type)"` (sorbet_json_schema.rb:257)
- `T::Struct` → `"ClassName struct"` (sorbet_json_schema.rb:338)

All of these get replaced with `"Parameter <name>"`.

**Bug 2: Generic struct description** (`lib/dspy/schema/sorbet_json_schema.rb:338`)

```ruby
description: "#{struct_name} struct",  # e.g. "AccumulatorPushTool::Item struct"
```

The fully-qualified Ruby class name is not useful to an LLM. There is no mechanism to set a class-level description on a `T::Struct`.

## Proposed Solution

### Bug 1 fix: Preserve existing descriptions with `||=`

Replace `.merge({ description: ... })` with `||=` so type-system descriptions are preserved, and the default `"Parameter <name>"` is only used as a fallback:

```ruby
# Before (base.rb:57,70 and toolset.rb:75)
properties[param_name] = schema.merge({ description: "Parameter #{param_name}" })

# After
schema[:description] ||= "Parameter #{param_name}"
properties[param_name] = schema
```

Apply in three locations:
- `lib/dspy/tools/base.rb:57` (positional args)
- `lib/dspy/tools/base.rb:70` (keyword args)
- `lib/dspy/tools/toolset.rb:75` (keyword args)

### Bug 2 fix: Add `struct_description` DSL to `StructDescriptions`

Add a class-level `struct_description` setter/getter to `DSPy::Ext::StructDescriptions::ClassMethods`:

```ruby
# lib/dspy/ext/struct_descriptions.rb
module ClassMethods
  def struct_description(text = nil)
    if text
      @struct_description = text
    else
      @struct_description
    end
  end
  # ... existing field_descriptions, const, prop methods
end
```

Then update `generate_struct_schema_internal` to use it:

```ruby
# lib/dspy/schema/sorbet_json_schema.rb:334-340
desc = if struct_class.respond_to?(:struct_description) && struct_class.struct_description
         struct_class.struct_description
       else
         "#{struct_name} struct"
       end

schema = {
  type: "object",
  properties: properties,
  required: required,
  description: desc,
  additionalProperties: false
}
```

## Technical Considerations

### The `" (optional)"` suffix interaction

For optional kwargs, after `||=` preserves a type-system description, `+= " (optional)"` appends to it:
- `"A mapping where keys are Strings and values are strings (optional)"` — acceptable, communicates useful info
- `"MyStruct struct (optional)"` — acceptable

No special handling needed; the suffix is useful regardless of description origin.

### Scope: minimal fix, no deduplication

`Base#call_schema_object` and `Toolset#schema_for_method` are near-duplicates. This PR applies the `||=` fix to both without extracting shared logic. Deduplication is a separate follow-up (see ADR-018 which proposes unifying signatures and tools).

### `Toolset#schema_for_method` omits positional args

Unlike `Base#call_schema_object`, `Toolset#schema_for_method` only processes `kwarg_types` — it skips `arg_types`. This is pre-existing behavior unrelated to #220. Out of scope for this PR.

### Schema file locations

The canonical `SorbetJsonSchema` implementation is at `lib/dspy/schema/sorbet_json_schema.rb` (the `dspy-schema` gem). The `lib/dspy/type_system/sorbet_json_schema.rb` file is a 4-line shim that `require`s it.

## Acceptance Criteria

### Bug 1: Preserve type-system descriptions
- [ ] `T::Hash` parameter keeps `"A mapping where keys are..."` description
- [ ] `T.any()` union parameter keeps `"Union of multiple types"` description
- [ ] `T.class_of()` parameter keeps `"Class name (T.class_of type)"` description
- [ ] `T::Struct` parameter (when used directly, not inside array) keeps struct description
- [ ] Primitive parameters (`String`, `Integer`) still get `"Parameter <name>"` fallback
- [ ] Optional parameters still get `" (optional)"` suffix regardless of description source
- [ ] Fix applies to `Base#call_schema_object` (positional + keyword args)
- [ ] Fix applies to `Toolset#schema_for_method` (keyword args)

### Bug 2: Custom struct descriptions
- [ ] `struct_description "text"` sets a class-level description on a `T::Struct`
- [ ] `struct_description` (no args) returns the stored description or `nil`
- [ ] `generate_struct_schema_internal` uses custom description when set
- [ ] Falls back to `"#{struct_name} struct"` when `struct_description` is not set (backward compat)
- [ ] Works with `DSPy::Ext::StructDescriptions` already prepended to `T::Struct`

### Testing
- [ ] Unit tests for `Base#call_schema_object` description preservation (new file: `spec/unit/dspy/tools/base_schema_spec.rb`)
- [ ] Unit tests for `Toolset#schema_for_method` description preservation (extend `spec/unit/dspy/tools/toolset_spec.rb`)
- [ ] Unit tests for `struct_description` DSL (extend `spec/unit/dspy/ext/struct_descriptions_spec.rb`)
- [ ] Unit test for `generate_struct_schema_internal` using custom struct description
- [ ] Backward-compat test: tools without descriptions produce same output as before
- [ ] End-to-end test: struct field description survives through `tool.schema` JSON output

### Documentation
- [ ] Update `docs/src/core-concepts/toolsets.md` to document `struct_description` DSL
- [ ] Update `docs/src/advanced/custom-toolsets.md` if it covers schema generation

## Success Metrics

- All existing tests pass (`bundle exec rspec`)
- New tests cover all acceptance criteria
- ReAct agent receives richer tool schemas when tools use typed parameters

## Dependencies & Risks

- **Low risk**: The `||=` change is additive — it only preserves what was already there. Primitives without descriptions still get the default.
- **Dependency**: `struct_description` is added to `StructDescriptions` which is already prepended globally to `T::Struct`. No new monkey-patching.
- **No breaking changes**: Existing tools that don't use `struct_description` or typed parameters produce identical output.

## Implementation Sequence (TDD)

### Phase 1: Bug 1 — Preserve parameter descriptions

1. **Write failing tests** in `spec/unit/dspy/tools/base_schema_spec.rb`:
   - Tool with `T::Hash` param → assert description preserved
   - Tool with `T::Struct` param → assert struct description preserved
   - Tool with primitive param → assert `"Parameter <name>"` default
   - Tool with optional param → assert `" (optional)"` suffix
2. **Fix `lib/dspy/tools/base.rb:57`** — positional args: `schema[:description] ||= "Parameter #{param_name}"`
3. **Fix `lib/dspy/tools/base.rb:70`** — keyword args: same
4. **Write failing tests** in `spec/unit/dspy/tools/toolset_spec.rb`
5. **Fix `lib/dspy/tools/toolset.rb:75`** — same pattern
6. **Run full suite**: `bundle exec rspec`

### Phase 2: Bug 2 — struct_description DSL

1. **Write failing tests** in `spec/unit/dspy/ext/struct_descriptions_spec.rb`:
   - `struct_description "text"` sets and retrieves
   - `struct_description` returns `nil` when not set
   - Struct without description still works (backward compat)
2. **Add `struct_description` to `lib/dspy/ext/struct_descriptions.rb`** in `ClassMethods`
3. **Write failing test** for `generate_struct_schema_internal` using custom description
4. **Update `lib/dspy/schema/sorbet_json_schema.rb:338`** to check `struct_description`
5. **Run full suite**: `bundle exec rspec`

### Phase 3: End-to-end & docs

1. **Write integration test**: define tool with struct having `struct_description` + field descriptions, call `tool.schema`, parse JSON, assert descriptions flow through
2. **Update documentation**: `docs/src/core-concepts/toolsets.md` and `docs/src/advanced/custom-toolsets.md`
3. **Final verification**: `bundle exec rspec` + docs build

## Files Changed

| File | Change |
|------|--------|
| `lib/dspy/tools/base.rb` | `||=` instead of `.merge` at lines 57, 70 |
| `lib/dspy/tools/toolset.rb` | `||=` instead of `.merge` at line 75 |
| `lib/dspy/ext/struct_descriptions.rb` | Add `struct_description` class method |
| `lib/dspy/schema/sorbet_json_schema.rb` | Use `struct_description` at line 338 |
| `spec/unit/dspy/tools/base_schema_spec.rb` | **New** — tests for `call_schema_object` descriptions |
| `spec/unit/dspy/tools/toolset_spec.rb` | Extend with `schema_for_method` description tests |
| `spec/unit/dspy/ext/struct_descriptions_spec.rb` | Extend with `struct_description` tests |
| `docs/src/core-concepts/toolsets.md` | Document `struct_description` DSL |
| `docs/src/advanced/custom-toolsets.md` | Document description preservation behavior |

## References

- GitHub Issue: #220
- `lib/dspy/tools/base.rb:57,70` — `.merge` overwrites descriptions
- `lib/dspy/tools/toolset.rb:75` — duplicated `.merge` overwrite
- `lib/dspy/schema/sorbet_json_schema.rb:338` — generic struct description
- `lib/dspy/ext/struct_descriptions.rb` — existing field description mixin
- ADR-018: Unified Tool Model (proposed, not yet implemented)
- ADR-005: Multi-Method Tool System

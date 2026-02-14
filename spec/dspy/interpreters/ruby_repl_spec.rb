# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)

# Pre-load gems RSpec uses lazily — the sandbox will pollute Object#require
# with a restrictive whitelist, breaking any later lazy require.
require 'pp'
require 'ripper'
require 'stringio'

require 'dspy/code_interpreter'
require 'dspy/repl_types'
require 'dspy/interpreters/ruby_repl'
require 'dspy/interpreters/mock_repl'

module SandboxCleanup
  # The sandbox eval's `def require(name)` on a TOPLEVEL_BINDING dup,
  # which defines a private instance method on Object, shadowing Kernel#require.
  def cleanup_sandbox_require!
    Object.send(:remove_method, :require) if Object.private_instance_methods(false).include?(:require)
  end
end

RSpec.describe DSPy::Interpreters::RubyREPL do
  include SandboxCleanup

  subject(:repl) { described_class.new(**init_opts) }
  let(:init_opts) { { tools: tools, output_fields: output_fields } }
  let(:tools) { {} }
  let(:output_fields) { %w[answer] }

  after do
    repl.shutdown
    cleanup_sandbox_require!
  end

  # Helper: execute + immediately restore Kernel#require so matchers work.
  def run(code, on: repl, **kw)
    result = on.execute(code, **kw)
    cleanup_sandbox_require!
    result
  end

  # ---------- 1. Basic eval --------------------------------------------------

  describe '#execute — basic eval' do
    it 'returns captured stdout from puts' do
      expect(run('puts 1 + 1')).to eq('2')
    end

    it 'falls back to inspect of eval result when no stdout' do
      expect(run('1 + 1')).to eq('2')
    end

    it 'prefers stdout over eval result' do
      expect(run("puts 'hello'; 99")).to eq('hello')
    end

    it 'returns placeholder when code produces no visible output' do
      expect(run('nil')).to include('no output')
    end
  end

  # ---------- 2. State persistence -------------------------------------------

  describe '#execute — state persistence' do
    it 'persists local variables across calls' do
      run('x = 42')
      expect(run('puts x')).to eq('42')
    end

    it 'persists method definitions across calls' do
      run('def double(n); n * 2; end')
      expect(run('puts double(21)')).to eq('42')
    end

    it 'persists data structures across calls' do
      run('acc = []')
      run('acc << 1; acc << 2')
      expect(run('puts acc.sum')).to eq('3')
    end
  end

  # ---------- 3. Variable injection ------------------------------------------

  describe '#execute — variable injection' do
    it 'injects a single variable' do
      expect(run('puts x', variables: { x: 42 })).to eq('42')
    end

    it 'injects multiple variables' do
      expect(run('puts a + b', variables: { a: 10, b: 32 })).to eq('42')
    end

    it 'injects complex objects' do
      data = { 'scores' => [90, 85, 92] }
      expect(run('puts data["scores"].sum', variables: { data: data })).to eq('267')
    end

    it 'accepts string keys (converted to symbols)' do
      expect(run('puts val', variables: { 'val' => 'hello' })).to eq('hello')
    end

    it 'injected variables persist for later calls' do
      run('nil', variables: { secret: 'abc' })
      expect(run('puts secret')).to eq('abc')
    end
  end

  # ---------- 4. SUBMIT returns FinalOutput ----------------------------------

  describe '#execute — SUBMIT' do
    it 'returns a FinalOutput wrapping the keyword arguments' do
      result = run('SUBMIT(answer: "42")')
      expect(result).to be_a(DSPy::FinalOutput)
      expect(result.output).to eq({ answer: '42' })
    end

    it 'handles multiple output fields' do
      multi = described_class.new(output_fields: %w[answer confidence])
      r = run('SUBMIT(answer: "yes", confidence: 0.95)', on: multi)
      expect(r).to be_a(DSPy::FinalOutput)
      expect(r.output[:answer]).to eq('yes')
      expect(r.output[:confidence]).to eq(0.95)
      multi.shutdown
      cleanup_sandbox_require!
    end

    it 'passes through non-string payload values' do
      result = run('SUBMIT(answer: [1, 2, 3])')
      expect(result.output[:answer]).to eq([1, 2, 3])
    end
  end

  # ---------- 5. SUBMIT with missing fields ----------------------------------

  describe '#execute — SUBMIT validation' do
    it 'raises CodeInterpreterError when required fields are missing' do
      expect {
        run('SUBMIT(wrong: "oops")')
      }.to raise_error(DSPy::CodeInterpreterError, /missing required fields/i)
    end

    it 'names the missing fields in the error message' do
      multi = described_class.new(output_fields: %w[name age])
      expect {
        run('SUBMIT(name: "Alice")', on: multi)
      }.to raise_error(DSPy::CodeInterpreterError, /age/)
      multi.shutdown
      cleanup_sandbox_require!
    end
  end

  # ---------- 6. Tool injection and calling ----------------------------------

  describe '#execute — tool injection' do
    let(:search_tool) { ->(query) { "results for: #{query}" } }
    let(:tools) { { 'search' => search_tool } }

    it 'makes a tool callable by name in the sandbox' do
      expect(run('puts search("ruby")')).to eq('results for: ruby')
    end

    it 'supports tools with keyword arguments' do
      calc = ->(a:, b:) { a + b }
      r = described_class.new(tools: { 'add' => calc }, output_fields: [])
      expect(run('puts add(a: 10, b: 32)', on: r)).to eq('42')
      r.shutdown
      cleanup_sandbox_require!
    end

    it 'supports tools that return complex objects' do
      data_tool = ->() { { 'items' => [1, 2, 3] } }
      r = described_class.new(tools: { 'fetch' => data_tool }, output_fields: [])
      expect(run('puts fetch()["items"].length', on: r)).to eq('3')
      r.shutdown
      cleanup_sandbox_require!
    end

    it 'exposes tools hash via #tools reader' do
      expect(repl.tools).to eq({ 'search' => search_tool })
    end
  end

  # ---------- 7. Code fence stripping ----------------------------------------

  describe '#execute — code fence stripping' do
    it 'strips ```ruby ... ``` fences' do
      code = "```ruby\nputs 42\n```"
      expect(run(code)).to eq('42')
    end

    it 'strips bare ``` fences' do
      code = "```\nputs 42\n```"
      expect(run(code)).to eq('42')
    end

    it 'strips fences with surrounding whitespace' do
      code = "  ```ruby\nputs 42\n```  "
      expect(run(code)).to eq('42')
    end

    it 'leaves non-fenced code alone' do
      expect(run('puts 42')).to eq('42')
    end

    it 'handles ```python fence (strips any language tag)' do
      code = "```python\nputs 42\n```"
      expect(run(code)).to eq('42')
    end
  end

  # ---------- 8. RuntimeError => CodeInterpreterError ------------------------

  describe '#execute — runtime error handling' do
    it 'wraps RuntimeError in CodeInterpreterError' do
      expect { run('raise "boom"') }
        .to raise_error(DSPy::CodeInterpreterError, /RuntimeError.*boom/)
    end

    it 'wraps NameError in CodeInterpreterError' do
      expect { run('totally_undefined_var_xyz') }
        .to raise_error(DSPy::CodeInterpreterError, /NameError/)
    end

    it 'wraps ZeroDivisionError in CodeInterpreterError' do
      expect { run('1 / 0') }
        .to raise_error(DSPy::CodeInterpreterError, /ZeroDivisionError/)
    end

    it 'wraps TypeError in CodeInterpreterError' do
      expect { run('"a" + 1') }
        .to raise_error(DSPy::CodeInterpreterError, /TypeError/)
    end

    it 'includes the class name and message' do
      expect { run('raise ArgumentError, "bad arg"') }
        .to raise_error(DSPy::CodeInterpreterError, /ArgumentError: bad arg/)
    end
  end

  # ---------- 9. SyntaxError => CodeInterpreterError -------------------------

  describe '#execute — syntax error handling' do
    it 'wraps SyntaxError in CodeInterpreterError' do
      expect { run('def foo(') }
        .to raise_error(DSPy::CodeInterpreterError, /SyntaxError/)
    end

    it 'wraps unterminated string SyntaxError' do
      expect { run('"hello') }
        .to raise_error(DSPy::CodeInterpreterError, /SyntaxError/)
    end
  end

  # ---------- 10. Stdout not leaked ------------------------------------------

  describe '#execute — stdout isolation' do
    it 'does not leak sandbox output to real $stdout' do
      real_stdout = $stdout
      spy = StringIO.new
      $stdout = spy
      begin
        run('puts "should not leak"')
      ensure
        $stdout = real_stdout
      end
      expect(spy.string).to eq('')
    end

    it 'captures multiline stdout correctly' do
      result = run("puts 'a'\nputs 'b'\nputs 'c'")
      expect(result).to eq("a\nb\nc")
    end

    it 'restores $stdout even after an error' do
      original = $stdout
      begin
        repl.execute('raise "boom"')
      rescue DSPy::CodeInterpreterError
        # expected
      ensure
        cleanup_sandbox_require!
      end
      expect($stdout).to equal(original)
    end
  end

  # ---------- shutdown -------------------------------------------------------

  describe '#shutdown' do
    it 'resets state so next call starts fresh' do
      run('x = 99')
      repl.shutdown
      cleanup_sandbox_require!
      expect { run('puts x') }.to raise_error(DSPy::CodeInterpreterError, /NameError/)
    end

    it 'can be called multiple times safely' do
      repl.shutdown
      repl.shutdown
      cleanup_sandbox_require!
    end
  end

  # ---------- protocol -------------------------------------------------------

  describe 'CodeInterpreter protocol' do
    it 'includes CodeInterpreter' do
      expect(repl).to be_a(DSPy::CodeInterpreter)
    end

    %i[tools start execute shutdown].each do |method|
      it "responds to ##{method}" do
        expect(repl).to respond_to(method)
      end
    end
  end
end

# ============================================================================
# 11. REPLVariable
# ============================================================================

RSpec.describe DSPy::REPLVariable do
  describe '.from_value' do
    it 'captures name as string' do
      v = described_class.from_value(:count, 42)
      expect(v.name).to eq('count')
    end

    it 'captures type_name from class' do
      expect(described_class.from_value(:x, 42).type_name).to eq('Integer')
      expect(described_class.from_value(:s, 'hi').type_name).to eq('String')
      expect(described_class.from_value(:a, [1]).type_name).to eq('Array')
      expect(described_class.from_value(:h, {}).type_name).to eq('Hash')
    end

    it 'uses field_info description when provided' do
      info = double(description: 'The answer')
      v = described_class.from_value(:x, 42, field_info: info)
      expect(v.desc).to eq('The answer')
    end

    it 'defaults desc to empty string' do
      expect(described_class.from_value(:x, 1).desc).to eq('')
    end

    it 'computes total_length from serialized value' do
      v = described_class.from_value(:s, 'hello')
      expect(v.total_length).to eq(5)
    end

    it 'JSON-pretty-prints Hash values for preview' do
      v = described_class.from_value(:h, { 'a' => 1 })
      expect(v.preview).to include('"a"')
      expect(v.preview).to include('1')
    end

    it 'JSON-pretty-prints Array values for preview' do
      v = described_class.from_value(:a, [1, 2, 3])
      expect(v.preview).to include('1')
    end

    it 'truncates long values and shows omission message' do
      long = 'x' * 2000
      v = described_class.from_value(:big, long, preview_chars: 100)
      expect(v.preview).to include('chars omitted')
      expect(v.preview.length).to be < 2000
    end

    it 'does not truncate values within limit' do
      v = described_class.from_value(:s, 'short')
      expect(v.preview).to eq('short')
      expect(v.preview).not_to include('omitted')
    end
  end

  describe '#format' do
    it 'includes the variable name in backticks' do
      v = described_class.from_value(:count, 42)
      expect(v.format).to include('`count`')
    end

    it 'includes type name' do
      v = described_class.from_value(:x, 42)
      expect(v.format).to include('Integer')
    end

    it 'includes description when present' do
      info = double(description: 'important value')
      v = described_class.from_value(:x, 1, field_info: info)
      expect(v.format).to include('important value')
    end

    it 'omits description line when desc is empty' do
      v = described_class.from_value(:x, 1)
      expect(v.format).not_to include('Description:')
    end

    it 'includes total length' do
      v = described_class.from_value(:s, 'hello')
      expect(v.format).to include('5 characters')
    end

    it 'formats length with comma separators for large values' do
      v = DSPy::REPLVariable.new(name: 'big', type_name: 'String', total_length: 12345)
      expect(v.format).to include('12,345')
    end

    it 'includes preview in a code block' do
      v = described_class.from_value(:x, 'hello')
      expect(v.format).to include("```\nhello\n```")
    end
  end
end

# ============================================================================
# 12. REPLHistory
# ============================================================================

RSpec.describe DSPy::REPLHistory do
  describe '#append' do
    it 'returns a new REPLHistory (immutable)' do
      h = described_class.new
      h2 = h.append(code: 'x = 1', output: '1')
      expect(h2).to be_a(described_class)
      expect(h2).not_to equal(h)
    end

    it 'does not mutate the original' do
      h = described_class.new
      h.append(code: 'x', output: '1')
      expect(h.entries).to be_empty
    end

    it 'accumulates entries in order' do
      h = described_class.new
        .append(code: 'a', output: '1')
        .append(code: 'b', output: '2')
        .append(code: 'c', output: '3')
      expect(h.size).to eq(3)
      expect(h.entries.map(&:code)).to eq(%w[a b c])
    end
  end

  describe '#format' do
    it 'returns friendly message when empty' do
      expect(described_class.new.format).to include('not interacted')
    end

    it 'numbers steps starting from 1' do
      h = described_class.new
        .append(code: 'x = 1', output: '1')
        .append(code: 'puts x', output: '1')
      formatted = h.format
      expect(formatted).to include('Step 1')
      expect(formatted).to include('Step 2')
    end

    it 'includes reasoning when provided' do
      h = described_class.new.append(reasoning: 'try it', code: 'x', output: '1')
      expect(h.format).to include('try it')
    end

    it 'wraps code in ruby fences' do
      h = described_class.new.append(code: 'x = 1', output: '1')
      expect(h.format).to include("```ruby\nx = 1\n```")
    end

    it 'shows output length' do
      h = described_class.new.append(code: 'x', output: 'hello')
      expect(h.format).to include('5 chars')
    end
  end

  describe '#to_s' do
    it 'is an alias for #format' do
      h = described_class.new.append(code: '1', output: '1')
      expect(h.to_s).to eq(h.format)
    end
  end

  describe '#empty? / #size' do
    it 'is empty when new' do
      h = described_class.new
      expect(h).to be_empty
      expect(h.size).to eq(0)
    end

    it 'is not empty after append' do
      h = described_class.new.append(code: '1', output: '1')
      expect(h).not_to be_empty
      expect(h.size).to eq(1)
    end
  end

  describe 'frozen entries' do
    it 'prevents mutation of entries array' do
      h = described_class.new.append(code: '1', output: '1')
      expect { h.entries.push('bad') }.to raise_error(FrozenError)
    end
  end
end

# ============================================================================
# 13. MockREPL
# ============================================================================

RSpec.describe DSPy::Interpreters::MockREPL do
  it 'includes CodeInterpreter' do
    expect(described_class.new).to be_a(DSPy::CodeInterpreter)
  end

  it 'returns scripted responses in order' do
    mock = described_class.new(responses: %w[first second third])
    expect(mock.execute('a')).to eq('first')
    expect(mock.execute('b')).to eq('second')
    expect(mock.execute('c')).to eq('third')
  end

  it 'records all executed code' do
    mock = described_class.new(responses: %w[ok ok])
    mock.execute('code_a')
    mock.execute('code_b')
    expect(mock.executed_code).to eq(%w[code_a code_b])
  end

  it 'tracks call_count' do
    mock = described_class.new(responses: %w[a b])
    expect(mock.call_count).to eq(0)
    mock.execute('x')
    expect(mock.call_count).to eq(1)
    mock.execute('y')
    expect(mock.call_count).to eq(2)
  end

  it 'raises CodeInterpreterError when responses are exhausted' do
    mock = described_class.new(responses: [])
    expect { mock.execute('x') }.to raise_error(DSPy::CodeInterpreterError, /no response/)
  end

  it 'can return FinalOutput as a scripted response' do
    final = DSPy::FinalOutput.new({ answer: '42' })
    mock = described_class.new(responses: [final])
    result = mock.execute('SUBMIT(answer: "42")')
    expect(result).to be_a(DSPy::FinalOutput)
    expect(result.output).to eq({ answer: '42' })
  end

  it 'ignores variables parameter (just records code)' do
    mock = described_class.new(responses: ['ok'])
    mock.execute('x', variables: { x: 1 })
    expect(mock.executed_code).to eq(['x'])
  end
end
